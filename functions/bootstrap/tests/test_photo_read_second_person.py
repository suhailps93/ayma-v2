"""Founder rule Nov 17: a CONFIRMED-USER photo's read speaks in the SECOND
person ("you"), never "a man / a woman / a person". Third person stays for
photos that are not the user or not confirmed.
"""

import asyncio

import photo_pipeline
import person_graph as pg
import person_graph_store as store


def _run(coro):
    return asyncio.run(coro)


def _capture_caption(monkeypatch):
    """Patch the model so _caption doesn't hit it; capture the instruction the
    composer builds. Returns a list the test reads after calling _caption."""
    captured: list[str] = []

    async def _fake(prompt, *a, **k):
        captured.append(prompt)
        return {"text": "ok"}

    monkeypatch.setattr(photo_pipeline.gemini, "generate_json", _fake)
    return captured


def test_confirmed_user_caption_is_instructed_second_person(monkeypatch):
    cap = _capture_caption(monkeypatch)
    _run(photo_pipeline._caption(b"x", "image/jpeg", match="self", name="Sam"))
    instr = cap[0]
    assert "SECOND PERSON" in instr
    assert '"you"' in instr
    assert "the account owner (you)" in instr


def test_confirmed_user_without_a_name_is_still_second_person(monkeypatch):
    cap = _capture_caption(monkeypatch)
    _run(photo_pipeline._caption(b"x", "image/jpeg", match="self"))
    assert "SECOND PERSON" in cap[0]


def test_non_user_caption_is_not_second_person(monkeypatch):
    cap = _capture_caption(monkeypatch)
    _run(photo_pipeline._caption(b"x", "image/jpeg", match="not_self"))
    instr = cap[0]
    assert "SECOND PERSON" not in instr
    assert "NOT to be the account owner" in instr


def test_unconfirmed_caption_is_not_second_person(monkeypatch):
    cap = _capture_caption(monkeypatch)
    _run(photo_pipeline._caption(b"x", "image/jpeg", match="unknown"))
    assert "SECOND PERSON" not in cap[0]


# --- the backfill's image-node read update ---------------------------------
class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _DocRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def collection(self, name):
        return _CollRef(self._st, self._key + (name,))

    def get(self):
        return _Snap(self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def test_set_image_read_updates_only_the_read():
    db = FakeDb()
    parent = sorted(pg.seed())[0]
    nid = store.add_image_node(
        db, "u1", parent, "https://fb/p.jpg",
        "a man with a beard smiling", is_you="yes",
    )
    assert store.set_image_read(db, "u1", nid, "You're smiling, beard and all") is True
    g = store.effective(db, "u1")
    assert g[nid].image_read == "You're smiling, beard and all"
    assert g[nid].is_you == "yes"  # verdict untouched
    # a non-image / missing node is a no-op.
    assert store.set_image_read(db, "u1", "nope", "x") is False
