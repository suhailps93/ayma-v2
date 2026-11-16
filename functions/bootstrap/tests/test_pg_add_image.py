"""Image nodes — pg_add_image (NOTE 225 Leg 3 Fix 2 / NOTE 231).

A photo shared in chat must land as an IMAGE node in the graph, homed WITH its
fact (founder decision Nov 16: each photo sits with its fact — under that fact's
section, not a Photos section), carrying the Storage link + Ayma's read, linked
two-way to the fact, and it must render with the fact in Your Story. NOTE 231:
the photo turn created no node of any kind — so the wiring is deterministic, not
a model tool choice.
"""

import asyncio
import dataclasses

import config
from config import CONFIG
import person_graph as pg


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


def _overlay(db, uid="u1"):
    import person_graph_store as store

    return store.load_overlay(db, uid)


# --- 1. store orchestrator: image homed under its fact ---------------------


def test_add_photo_fact_homes_image_under_fact():
    import person_graph_store as store

    db = FakeDb()
    fact_id, image_id = store.add_photo_fact(
        db, "u1",
        image_url="https://storage/dog.jpg",
        image_read="(shared a photo of themselves) a brown dog on grass",
        fact_text="a brown dog on grass",
    )
    ov = _overlay(db)
    fact, image = ov[fact_id], ov[image_id]

    # fact is a loose narrative node in Little Extras
    assert fact["answer"] == "a brown dog on grass"
    assert fact["section"] == "misc"

    # image node sits WITH its fact: homed under it, same section
    assert image["answer_type"] == "image"
    assert image["parent"] == fact_id
    assert image["section"] == "misc"
    assert image["answer"] == "https://storage/dog.jpg"       # Storage link
    assert "a brown dog on grass" in image["image_read"]       # Ayma's read
    assert image["visibility"] == "private"                    # common-sense default

    # two-way typed links (a reference, never a copy)
    assert any(l["target"] == fact_id for l in image.get("links", []))
    assert any(l["target"] == image_id for l in fact.get("links", []))


def test_add_photo_fact_idempotent_on_node_id():
    import person_graph_store as store

    db = FakeDb()
    out1 = store.add_photo_fact(
        db, "u1", image_url="https://storage/x.jpg", image_read="r", fact_text="f",
        image_node_id="emergent.image.deadbeef",
    )
    assert out1 is not None
    out2 = store.add_photo_fact(
        db, "u1", image_url="https://storage/x.jpg", image_read="r", fact_text="f",
        image_node_id="emergent.image.deadbeef",
    )
    assert out2 is None  # already homed — no duplicate
    images = [n for n in _overlay(db).values() if n.get("answer_type") == "image"]
    assert len(images) == 1


# --- 2. render: the image renders WITH its fact ----------------------------


def test_image_renders_with_fact_in_story():
    import person_graph_render as render
    import person_graph_store as store

    db = FakeDb()
    store.add_photo_fact(
        db, "u1", image_url="https://storage/dog.jpg",
        image_read="(shared a photo) a brown dog on grass",
        fact_text="a brown dog on grass",
    )
    graph = store.effective(db, "u1")
    misc = [s for s in render.story_sections(graph)["sections"]
            if s["page_type"] == "misc"][0]
    texts = [b["text"] for b in misc["bullets"]]
    assert "a brown dog on grass" in texts, "the fact renders"
    img_bullets = [b for b in misc["bullets"] if b.get("image_url")]
    assert img_bullets, "the image item renders under its fact's section"
    assert img_bullets[0]["image_url"] == "https://storage/dog.jpg"
    assert "brown dog" in img_bullets[0]["text"]  # the read renders as the text


def test_ayma_only_image_never_renders_in_story():
    import person_graph_render as render
    import person_graph_store as store

    db = FakeDb()
    store.add_photo_fact(
        db, "u1", image_url="https://storage/secret.jpg",
        image_read="a sensitive photo", fact_text="a sensitive photo",
        visibility="ayma_only",
    )
    graph = store.effective(db, "u1")
    all_bullets = [
        b for s in render.story_sections(graph)["sections"] for b in s["bullets"]
    ]
    assert not any(b.get("image_url") for b in all_bullets)


def test_public_profile_gates_image_on_visibility():
    """Public profile shows the image's content only when the image node is
    public (visibility gate). public_sections emits text bullets; the read is
    the public-facing content there."""
    import person_graph_render as render
    import person_graph_store as store

    # private image → its read is NOT in the public profile
    db = FakeDb()
    store.add_photo_fact(
        db, "u1", image_url="https://storage/priv.jpg",
        image_read="a private selfie", fact_text="a private selfie",
        visibility="private",
    )
    priv_texts = [
        b for s in render.public_sections(store.effective(db, "u1"))
        for b in s["bullets"]
    ]
    assert not any("private selfie" in t for t in priv_texts)

    # public image → its read IS in the public profile
    db2 = FakeDb()
    store.add_photo_fact(
        db2, "u2", image_url="https://storage/pub.jpg",
        image_read="at the summit", fact_text="hiking", visibility="public",
    )
    pub_texts = [
        b for s in render.public_sections(store.effective(db2, "u2"))
        for b in s["bullets"]
    ]
    assert any("at the summit" in t for t in pub_texts)


# --- 3. deterministic wiring: a chat photo turn creates the node -----------


def test_chat_photo_turn_creates_image_node(monkeypatch):
    """NOTE 231: the photo turn must create the node even if the model calls no
    tool. _run_chat_followups fires it deterministically."""
    import main
    import media_embed
    import photo_pipeline
    import public_profile

    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(
        main, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=True)
    )
    monkeypatch.setattr(media_embed, "download_bytes", lambda path: (b"img", "image/jpeg"))

    async def _fake_caption(b, mime, *, uid):
        return "a brown dog on grass"

    monkeypatch.setattr(photo_pipeline, "_caption", _fake_caption)
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: "https://storage/dog.jpg")

    async def _noop_ingest(*a, **k):
        return None

    monkeypatch.setattr(main, "_run_ingest", _noop_ingest)

    from main import Turn, ROLE_USER

    asyncio.run(
        main._run_chat_followups(
            "u1", "sess1", [Turn(ROLE_USER, "look at my dog")], "uploads/u1/dog.jpg"
        )
    )

    images = [n for n in _overlay(db).values() if n.get("answer_type") == "image"]
    assert len(images) == 1, "the photo turn created an image node"
    assert images[0]["answer"] == "https://storage/dog.jpg"
    assert images[0].get("parent"), "the image is homed under a fact node"
