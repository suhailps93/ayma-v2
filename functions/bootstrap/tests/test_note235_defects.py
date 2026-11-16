"""NOTE 235 defects — four fixes in one chunk.

* Defect 1 — the public-profile header hydrates name/location from the graph
  seed nodes (the structured-writer swap no longer writes ``profile/main``), so a
  chat location edit shows in the header.
* Defect 3a — a re-send of the SAME photo (the client re-uploads to a fresh
  Storage path each time) reuses the existing image node: the node id is derived
  from the image CONTENT, not the upload path, so no duplicate image/fact node.
* Defect 3b — an image node renders directly WITH its fact bullet, not at the
  end of its section by its deeper level.
* Defect 3c — an identical re-send reuses the ``user_media`` record (content
  hash), so no duplicate ``user_media`` doc, no re-moderation.
* Defect 4 — ``POST /profiles/mini`` reads the real ``CONFIG`` (a typo read an
  undefined ``_CONFIG`` and threw on every call, blanking every name → the
  Messages list showed "Someone"/"Conversation").
"""

import asyncio
import dataclasses

import config
from config import CONFIG


# --- Firestore fake (tuple-path; get/set/where/limit/stream) ----------------


class _Snap:
    def __init__(self, doc_id, data, reference=None):
        self.id = doc_id
        self._data = data
        self.reference = reference

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key), reference=self)

    def set(self, payload, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(payload)
        self.store.docs[self.key] = cur

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._filter = None
        self._limit = None

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.n += 1
            doc_id = f"auto{self.store.n}"
        return _DocRef(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        self._filter = (field, value)
        return self

    def limit(self, n):
        self._limit = n
        return self

    def stream(self):
        d = len(self.key)
        n = 0
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                if self._filter and v.get(self._filter[0]) != self._filter[1]:
                    continue
                if self._limit is not None and n >= self._limit:
                    break
                n += 1
                yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})
        self.n = 0

    def collection(self, name):
        return _CollRef(self, (name,))


def _reads_on(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=True)
    )


def _seed_answer(docs, uid, node_id, answer):
    """Seed one answered seed-node overlay entry (as ``set_answer`` writes it)."""
    key = ("users", uid, "graph", "main")
    doc = docs.setdefault(key, {"nodes": {}})
    doc["nodes"][node_id] = {
        "answer": answer, "state": "answered", "provenance": "stated",
    }


# --- Defect 1 — header hydrates from the graph ------------------------------


def test_public_profile_header_hydrates_location_from_graph(monkeypatch):
    import public_profile as pp

    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}" if sp else None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: 0.5)
    _reads_on(monkeypatch)

    docs = {
        # profile/main is STALE (the structured-writer swap stopped writing it)
        ("users", "her", "profile", "main"): {
            "name": "Dana", "location": "Seattle, WA", "birthdate": "1994-01-01",
        },
    }
    # the graph seed node carries the fresh chat edit
    _seed_answer(docs, "her", "primary_location", "Portland, OR")
    db = FakeDb(docs)

    v = pp.build(db, "me", "her")
    assert v["location"] == "Portland, OR", "header reads the graph, not stale profile/main"
    assert v["name"] == "Dana"


def test_public_profile_header_unchanged_with_flag_off(monkeypatch):
    import public_profile as pp

    monkeypatch.setattr(pp, "_photo_url", lambda sp: None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: 0.5)
    # flag OFF (default) → no graph hydration, old behaviour

    docs = {
        ("users", "her", "profile", "main"): {"name": "Dana", "location": "Seattle, WA"},
    }
    _seed_answer(docs, "her", "primary_location", "Portland, OR")
    db = FakeDb(docs)

    v = pp.build(db, "me", "her")
    assert v["location"] == "Seattle, WA"


# --- Defect 3a — re-send of the same photo reuses the node ------------------


def _wire_chat_photo(monkeypatch, db, *, caption="a brown dog on grass"):
    import main
    import media_embed
    import photo_pipeline
    import public_profile

    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(
        main, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=True)
    )
    # identical bytes regardless of the upload path (the client re-uploads)
    monkeypatch.setattr(media_embed, "download_bytes", lambda path: (b"DOGBYTES", "image/jpeg"))

    async def _caption(b, mime, *, uid):
        return caption

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: f"https://storage/{p}")

    async def _noop_ingest(*a, **k):
        return None

    monkeypatch.setattr(main, "_run_ingest", _noop_ingest)


def test_same_photo_resent_adds_no_second_node(monkeypatch):
    import main
    import person_graph_store as store
    from main import Turn, ROLE_USER

    db = FakeDb()
    _wire_chat_photo(monkeypatch, db)

    # First send.
    asyncio.run(main._run_chat_followups(
        "u1", "s", [Turn(ROLE_USER, "my dog")], "uploads/u1/send1.jpg"))
    after_first = dict(store.load_overlay(db, "u1"))
    images1 = [n for n in after_first.values() if n.get("answer_type") == "image"]
    assert len(images1) == 1

    # Second send of the SAME photo to a DIFFERENT upload path.
    asyncio.run(main._run_chat_followups(
        "u1", "s", [Turn(ROLE_USER, "my dog again")], "uploads/u1/send2.jpg"))
    after_second = store.load_overlay(db, "u1")

    images2 = [n for n in after_second.values() if n.get("answer_type") == "image"]
    assert len(images2) == 1, "identical content reuses the image node — no duplicate"
    assert len(after_second) == len(after_first), "no second fact node either"


def test_different_photo_still_adds_a_node(monkeypatch):
    import main
    import media_embed
    import person_graph_store as store
    from main import Turn, ROLE_USER

    db = FakeDb()
    _wire_chat_photo(monkeypatch, db)
    asyncio.run(main._run_chat_followups(
        "u1", "s", [Turn(ROLE_USER, "dog")], "uploads/u1/a.jpg"))
    n1 = len(store.load_overlay(db, "u1"))

    # Different bytes → a genuinely new photo → a new node.
    monkeypatch.setattr(media_embed, "download_bytes", lambda path: (b"CATBYTES", "image/jpeg"))
    asyncio.run(main._run_chat_followups(
        "u1", "s", [Turn(ROLE_USER, "cat")], "uploads/u1/b.jpg"))
    images = [n for n in store.load_overlay(db, "u1").values()
              if n.get("answer_type") == "image"]
    assert len(images) == 2
    assert len(store.load_overlay(db, "u1")) > n1


# --- Defect 3b — the image renders with its fact ----------------------------


def test_image_bullet_renders_adjacent_to_its_fact(monkeypatch):
    import person_graph_render as render
    import person_graph_store as store

    db = FakeDb()
    # An unrelated Little-Extras fact whose id sorts AFTER the photo fact, so a
    # naive (section, level, id) order would wedge it between the fact and its
    # image — or push the image (deeper level) to the very end.
    store.add_loose_node(db, "u1", "zzz an unrelated extra")
    fact_id, image_id = store.add_photo_fact(
        db, "u1",
        image_url="https://storage/dog.jpg",
        image_read="a brown dog on grass",
        fact_text="aaa a brown dog on grass",
    )
    graph = store.effective(db, "u1")
    secs = render.story_sections(graph)["sections"]
    misc = next(s for s in secs if s["page_type"] == "misc")
    bullets = misc["bullets"]

    fact_idx = next(i for i, b in enumerate(bullets) if b["text"] == "aaa a brown dog on grass")
    img_idx = next(i for i, b in enumerate(bullets) if b.get("image_url"))
    assert img_idx == fact_idx + 1, "the photo sits immediately after its fact bullet"


# --- Defect 3c — identical re-send reuses the user_media doc -----------------


def test_identical_resend_reuses_user_media_doc(monkeypatch):
    import photo_pipeline

    async def _allow(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    async def _attrs(b, m, **_kw):
        return {"shot_type": "solo"}

    async def _no_face(*_a, **_k):
        return {"verdict": "unknown", "confidence": "low", "face_visible": True, "reason": ""}

    async def _caption(b, m, **kw):
        return "a dog"

    async def _wiki(db, uid, sid, turns, force_visibility=None):
        return None

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _allow)
    monkeypatch.setattr(photo_pipeline.photo_attrs, "extract_attributes", _attrs)
    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _no_face)
    monkeypatch.setattr(photo_pipeline, "_caption", _caption)
    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)
    # identical bytes regardless of path
    monkeypatch.setattr(
        photo_pipeline.media_embed, "download_bytes",
        lambda p: (b"SAMEBYTES", "image/jpeg"),
    )

    db = FakeDb()
    r1 = asyncio.run(photo_pipeline.process(db, "u1", "uploads/u1/a.jpg", "chat"))
    media_after_first = [k for k in db.docs if k[:3] == ("users", "u1", "user_media")]
    assert len(media_after_first) == 1

    # Same content, fresh upload path → reuse, no second user_media doc.
    r2 = asyncio.run(photo_pipeline.process(db, "u1", "uploads/u1/b.jpg", "chat"))
    assert r2["media_id"] == r1["media_id"]
    assert r2.get("deduped") is True
    media_after_second = [k for k in db.docs if k[:3] == ("users", "u1", "user_media")]
    assert len(media_after_second) == 1, "no duplicate user_media doc on an identical re-send"


# --- Defect 2 — a migrated user yields a scoreable persona ------------------
# Root cause: with reads ON, score_pair reads each user's narrative from the
# graph (person_graph_source.persona). An un-migrated user has an empty overlay
# → empty persona → score_pair raises "both users need a wiki", which _match_job
# swallows → a forced recalc never writes a fresh pair doc. The fix is migration
# coverage; this guards the invariant that migration restores a scoreable persona.


def test_migration_restores_a_scoreable_persona(monkeypatch):
    import person_graph_migrate as mig
    import person_graph_source as src

    db = FakeDb({
        ("users", "u1", "profile", "main"): {
            "name": "Sofia", "location": "San Jose", "gender": "Woman",
        },
        ("users", "u1", "questionnaire", "gender_identity"): {
            "node_id": "gender_identity", "value": "Woman", "source": "stated",
        },
    })
    # Un-migrated: empty overlay → empty persona → score_pair would raise.
    assert src.persona(db, "u1") == ""
    mig.migrate_user(db, "u1", write=True)
    assert src.persona(db, "u1").strip() != "", (
        "a migrated user has a non-empty persona, so matching can score the pair"
    )


# --- Defect 4 — /profiles/mini returns names (no NameError) ------------------


def test_profiles_mini_returns_name_with_reads_on(monkeypatch):
    import main

    db = FakeDb({
        ("users", "other1", "profile", "main"): {"name": "Sofia Marino"},
    })
    monkeypatch.setattr(main, "get_db", lambda: db)
    _reads_on(monkeypatch)  # the gate that used to read an undefined _CONFIG

    req = main._MiniProfilesRequest(uids=["other1"])
    out = asyncio.run(main.profiles_mini(req, uid="me"))
    assert out["profiles"]["other1"]["name"] == "Sofia Marino", (
        "the mini-profile name resolves (no NameError blanking it)"
    )
