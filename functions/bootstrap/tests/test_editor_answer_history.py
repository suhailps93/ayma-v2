"""Editor answer-history fix — Your Story edits preserve node identity.

Scout NOTE 232 Leg 3: the editor re-serialized the whole section on save (edited
bullets got new ids + bumped levels, the old text was deleted). The settled
ANSWER HISTORY rule: an edit keeps the node's id and level and retires the
superseded text to that node's Ayma-only dated history — never rendered in Your
Story or the public profile, never scored. A delete owes no history. These tests
pin that, flag-on.
"""

import dataclasses

import config
from config import CONFIG


# --- Firestore fake (tuple-path; graph overlay) ----------------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
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
        return _Snap(self._key[-1], self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))

    def stream(self):
        depth = len(self._key)
        for key, data in list(self._st.docs.items()):
            if len(key) == depth + 1 and key[:depth] == self._key and data is not None:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _set_reads(monkeypatch, reads: bool):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )


def _interests(out):
    return [s for s in out["sections"] if s["page_type"] == "interests"][0]


# --- 1. edit preserves id + level + retires history ------------------------


def test_edit_preserves_id_level_and_retires_history(monkeypatch):
    import person_graph_store as store
    import profile_bullets

    db = FakeDb()
    _set_reads(monkeypatch, True)
    # a level-1 editor-owned node (a migrated loose fact), as Scout saw.
    store.upsert_fact_node(
        db, "u1", "emergent.story.climb", "Climbs every weekend",
        section="interests", visibility="public", level=1,
    )
    bullet = _interests(profile_bullets.get_bullets(db, "u1"))["bullets"][0]
    nid = bullet["id"]
    assert nid == "emergent.story.climb"

    # edit that bullet (same id, changed text)
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"id": nid, "text": "Climbs every day now", "visibility": "public"},
    ])

    entry = store.node_overlay_entry(db, "u1", nid)
    assert entry, "node id preserved (not re-minted)"
    assert entry["level"] == 1, "level NOT bumped"
    assert entry["answer"] == "Climbs every day now", "live text updated"
    hist = entry.get("history") or []
    assert any(h.get("answer") == "Climbs every weekend" for h in hist), "old text retired to history"
    assert all("date" in h for h in hist), "history entries are dated"

    # the editor view shows only the live text, never the retired text
    texts = [b["text"] for b in _interests(profile_bullets.get_bullets(db, "u1"))["bullets"]]
    assert texts == ["Climbs every day now"]
    assert "Climbs every weekend" not in texts


# --- 2. retired history never renders (story + public profile) -------------


def test_history_never_renders_in_story_or_public(monkeypatch):
    import person_graph_store as store
    import profile_bullets
    import public_profile
    import story

    db = FakeDb()
    _set_reads(monkeypatch, True)
    store.upsert_fact_node(
        db, "u1", "emergent.story.job", "Works as a nurse",
        section="interests", visibility="public", level=2,
    )
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"id": "emergent.story.job", "text": "Works as a doctor", "visibility": "public"},
    ])

    story_bodies = " ".join(s["body"] for s in story.get_story(db, "u1").get("sections", []))
    assert "Works as a doctor" in story_bodies
    assert "Works as a nurse" not in story_bodies  # retired text never in Your Story

    pub_blob = str(public_profile.public_bullet_sections(db, "u1"))
    assert "Works as a doctor" in pub_blob      # live public bullet renders
    assert "Works as a nurse" not in pub_blob   # retired text never public


# --- 3. unchanged / reordered bullets keep their ids -----------------------


def test_reorder_and_unchanged_keep_ids(monkeypatch):
    import profile_bullets

    db = FakeDb()
    _set_reads(monkeypatch, True)
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"text": "Alpha", "visibility": "public"},
        {"text": "Beta", "visibility": "private"},
    ])
    first = _interests(profile_bullets.get_bullets(db, "u1"))["bullets"]
    id_by_text = {b["text"]: b["id"] for b in first}

    # re-save reordered, carrying ids (as the client now does)
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"id": id_by_text["Beta"], "text": "Beta", "visibility": "private"},
        {"id": id_by_text["Alpha"], "text": "Alpha", "visibility": "public"},
    ])
    after = _interests(profile_bullets.get_bullets(db, "u1"))["bullets"]
    after_ids = {b["text"]: b["id"] for b in after}
    assert after_ids["Alpha"] == id_by_text["Alpha"]
    assert after_ids["Beta"] == id_by_text["Beta"]


# --- 4. new bullet gets a new id -------------------------------------------


def test_new_bullet_gets_new_id(monkeypatch):
    import profile_bullets

    db = FakeDb()
    _set_reads(monkeypatch, True)
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"text": "Alpha", "visibility": "public"},
    ])
    alpha_id = _interests(profile_bullets.get_bullets(db, "u1"))["bullets"][0]["id"]

    profile_bullets.save_bullets(db, "u1", "interests", [
        {"id": alpha_id, "text": "Alpha", "visibility": "public"},
        {"text": "Gamma (new)", "visibility": "public"},  # no id → new
    ])
    bullets = _interests(profile_bullets.get_bullets(db, "u1"))["bullets"]
    ids = {b["text"]: b["id"] for b in bullets}
    assert ids["Alpha"] == alpha_id
    assert ids["Gamma (new)"] != alpha_id and ids["Gamma (new)"]


# --- 5. delete still takes (no regression) + count drops -------------------


def test_delete_removes_node_and_count_drops(monkeypatch):
    import person_graph_store as store
    import profile_bullets

    db = FakeDb()
    _set_reads(monkeypatch, True)
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"text": "Keep me", "visibility": "public"},
        {"text": "Delete me", "visibility": "private"},
    ])
    n_before = len(store.load_overlay(db, "u1"))
    before = {b["text"]: b["id"] for b in _interests(profile_bullets.get_bullets(db, "u1"))["bullets"]}

    # re-save with only the kept bullet (carry its id) → the other is deleted
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"id": before["Keep me"], "text": "Keep me", "visibility": "public"},
    ])
    n_after = len(store.load_overlay(db, "u1"))
    texts = [b["text"] for b in _interests(profile_bullets.get_bullets(db, "u1"))["bullets"]]
    assert texts == ["Keep me"]
    assert n_after == n_before - 1, "graph node count drops on delete"
    # a delete owes no history — the deleted node is simply gone
    assert not store.node_overlay_entry(db, "u1", before["Delete me"])
