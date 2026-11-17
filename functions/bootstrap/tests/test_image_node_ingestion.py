"""2l — live image-node creation on every ingest path.

Chat already homed its photos; this pins the shared helper plus the three
newly-wired paths: profile grid (``photo_pipeline._enrich``), appearance report
(``appearance_engine._home_appearance_photos``) and web
(``deep_dive._home_web_images``). Each path must create an ``answer_type ==
"image"`` node carrying the structured ``is_you`` verdict and the SOURCE
provenance, keyed so a re-ingest of the same asset upserts instead of
duplicating.
"""

import asyncio
import dataclasses

import config
from config import CONFIG

import appearance_engine
import deep_dive
import person_graph as pg
import person_graph_store as store
import photo_pipeline


# --- a Firestore fake that supports get() + nested set(merge) ---------------
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

    @property
    def id(self):
        return self._key[-1]

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

    def document(self, name=None):
        if name is None:
            self._st.auto += 1
            name = f"auto{self._st.auto}"
        return _DocRef(self._st, self._key + (name,))


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.auto = 0

    def collection(self, name):
        return _CollRef(self, (name,))


def _run(coro):
    return asyncio.run(coro)


def _image_nodes(db, uid):
    return {
        nid: n
        for nid, n in store.load_overlay(db, uid).items()
        if isinstance(n, dict) and n.get("answer_type") == "image"
    }


# --- id helpers -------------------------------------------------------------
def test_content_id_is_stable_and_differs_from_url_id():
    a = store.image_node_id_for_bytes(b"ABC")
    assert a == store.image_node_id_for_bytes(b"ABC")  # same bytes → same id
    assert a != store.image_node_id_for_bytes(b"XYZ")
    assert a.startswith("emergent.image.")
    url_id = store.image_node_id_for_url("https://x/y.jpg")
    assert url_id == store.image_node_id_for_url(" https://x/y.jpg ")  # trimmed
    assert url_id.startswith("emergent.image.")


# --- shared helper: home_image ---------------------------------------------
def test_home_image_creates_node_with_verdict_and_provenance():
    db = FakeDb()
    nid = store.image_node_id_for_bytes(b"photo-bytes")
    res = store.home_image(
        db, "u1",
        image_url="https://fb/u1/a.jpg", image_read="a selfie by the lake",
        node_id=nid, is_you="yes",
        source_kind="profile_grid", source_ref="media42",
    )
    assert res is not None  # fresh home returns (fact_id, image_id)
    node = store.load_overlay(db, "u1")[nid]
    assert node["answer_type"] == "image"
    assert node["is_you"] == "yes"
    assert node["source_kind"] == "profile_grid"
    assert node["source_ref"] == "media42"


def test_home_image_is_idempotent_on_the_same_node_id():
    db = FakeDb()
    nid = store.image_node_id_for_bytes(b"same-bytes")
    first = store.home_image(
        db, "u1", image_url="https://fb/a.jpg", image_read="read one",
        node_id=nid, source_kind="chat", source_ref="s1",
    )
    second = store.home_image(
        db, "u1", image_url="https://fb/a.jpg", image_read="read two",
        node_id=nid, source_kind="profile_grid", source_ref="m2",
    )
    assert first is not None and second is None  # no duplicate fact minted
    assert len(_image_nodes(db, "u1")) == 1


# --- appearance report path -------------------------------------------------
def test_appearance_home_marks_source_and_dedupes_across_axes(monkeypatch):
    import public_profile

    monkeypatch.setattr(public_profile, "_photo_url", lambda p: f"https://fb/{p}")
    db = FakeDb()
    face_bytes = b"face-photo"
    # Same photo appears on BOTH axes → homed once.
    face_picks = [(face_bytes, "image/jpeg", "uploads/u1/face.jpg")]
    body_picks = [
        (face_bytes, "image/jpeg", "uploads/u1/face.jpg"),
        (b"body-photo", "image/jpeg", "uploads/u1/body.jpg"),
    ]
    appearance_engine._home_appearance_photos(
        db, "u1", "report-current",
        face_picks, "strong jawline", body_picks, "athletic build",
    )
    nodes = _image_nodes(db, "u1")
    assert len(nodes) == 2  # face photo deduped across the two axes
    for n in nodes.values():
        assert n["source_kind"] == "appearance_report"
        assert n["source_ref"] == "report-current"
        assert n["is_you"] == "yes"


def test_appearance_read_prefers_verdict_note():
    assert appearance_engine._appearance_read(
        {"verdict_note": "note!", "verdict": "v"}, "face") == "note!"
    assert appearance_engine._appearance_read({"verdict": "v"}, "body") == "v"
    assert appearance_engine._appearance_read({}, "face") == "Face appearance analysis"


# --- web path ---------------------------------------------------------------
def test_web_home_sets_web_source_and_is_you_from_verified():
    db = FakeDb()
    web_images = [
        {"url": "https://site/a.jpg", "source_page": "https://site/about",
         "verified": True, "platform": "LinkedIn"},
        {"url": "https://site/b.jpg", "source_page": "", "verified": False},
        {"url": "", "verified": True},  # dropped: no url
    ]
    deep_dive._home_web_images(db, "subj", "Jane Doe", web_images)
    nodes = _image_nodes(db, "subj")
    assert len(nodes) == 2
    by_url = {n["answer"]: n for n in nodes.values()}
    assert by_url["https://site/a.jpg"]["is_you"] == "yes"
    assert by_url["https://site/a.jpg"]["source_kind"] == "web"
    assert by_url["https://site/a.jpg"]["source_ref"] == "https://site/about"
    assert by_url["https://site/b.jpg"]["is_you"] == "unknown"
    # URL-keyed + idempotent: a re-run homes onto the same nodes.
    deep_dive._home_web_images(db, "subj", "Jane Doe", web_images)
    assert len(_image_nodes(db, "subj")) == 2


# --- profile-grid path (through the real _enrich) ---------------------------
def test_grid_enrich_homes_an_image_node_with_profile_grid_source(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=True)
    )

    async def _caption(b, m, **kw):
        return "a hiking selfie"

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)

    import photo_notes
    import public_profile

    monkeypatch.setattr(photo_notes, "set_context", lambda *a, **k: None)
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: f"https://fb/{p}")

    db = FakeDb()
    _run(photo_pipeline._enrich(
        db, "u1", "media9", b"grid-bytes", "image/jpeg", "profile",
        "uploads/u1/grid.jpg",
        face_verdict="self", attributes={"shot_type": "solo"},
        wiki_uids=None, wiki_visibility=None, accompanying_text="",
    ))

    nodes = _image_nodes(db, "u1")
    assert len(nodes) == 1
    (node,) = nodes.values()
    assert node["source_kind"] == "profile_grid"
    assert node["source_ref"] == "media9"
    assert node["is_you"] == "yes"  # face_verdict "self" → yes
    assert node["answer"] == "https://fb/uploads/u1/grid.jpg"


def test_grid_enrich_skips_graph_home_when_flag_off(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=False)
    )

    async def _caption(b, m, **kw):
        return "a hiking selfie"

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)
    import photo_notes
    import public_profile

    monkeypatch.setattr(photo_notes, "set_context", lambda *a, **k: None)
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: f"https://fb/{p}")

    db = FakeDb()
    _run(photo_pipeline._enrich(
        db, "u1", "media9", b"grid-bytes", "image/jpeg", "profile",
        "uploads/u1/grid.jpg",
        face_verdict="self", attributes={"shot_type": "solo"},
        wiki_uids=None, wiki_visibility=None, accompanying_text="",
    ))
    assert _image_nodes(db, "u1") == {}
