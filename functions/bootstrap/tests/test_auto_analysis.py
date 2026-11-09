"""Auto-analysis (§ auto analysis): face/body on every own photo, one web dive."""

import asyncio

import appearance
import auto_analysis
import body_report
import deep_dive
import deep_dive_images
import face_match
import face_report
import media_embed
import skill_memory
import token_ledger


def _run(coro):
    # A dedicated loop per call — never touches the process-wide current loop
    # that other test modules' `asyncio.get_event_loop()` helpers rely on.
    return asyncio.new_event_loop().run_until_complete(coro)


# --- fake Firestore (nested tuple-keyed store) ------------------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return _Snap(self._key[-1], self._store.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._store.docs.get(self._key, {})) if merge else {}
        cur.update(payload)
        self._store.docs[self._key] = cur

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))

    def add(self, payload):
        self._store.counter = getattr(self._store, "counter", 0) + 1
        doc_id = f"auto{self._store.counter}"
        self._store.docs[self._key + (doc_id,)] = dict(payload)
        return (None, _Snap(doc_id, self._store.docs[self._key + (doc_id,)]))

    def stream(self):
        depth = len(self._key)
        return [
            _Snap(k[-1], v)
            for k, v in self._store.docs.items()
            if len(k) == depth + 1 and k[:depth] == self._key and v is not None
        ]


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


_FACE = {
    "usable": True,
    "overall_score": 6.9,
    "verdict": "Above average",
    "verdict_note": "Strong eyes.",
    "features": [{"name": "eyes", "score": 8.0, "note": "Well spaced."}],
    "strengths": ["Expressive eyes"],
    "improvements": ["Even skin"],
    "recommendations": [],
}

_BODY = {
    "usable": True,
    "overall_score": 6.4,
    "verdict": "Solid base",
    "features": [{"name": "posture", "score": 6.0, "note": "Forward head."}],
    "strengths": ["Shoulder width"],
    "improvements": ["Calves"],
    "recommendations": [],
}

_DIGEST = {
    "summary": "Runs a bakery in Porto.",
    "confidence": "medium",
    "facts": [],
    "links": [],
}


def _stub_engines(monkeypatch, face=_FACE, body=_BODY):
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _sp: (b"imgbytes", "image/jpeg")
    )

    async def _face_run(_b, _m, *, uid=None, source_path=None):
        return {**face, "source_photos": [source_path] if source_path else []}

    async def _body_run(_b, _m, *, uid=None, source_path=None):
        return {**body, "source_photos": [source_path] if source_path else []}

    monkeypatch.setattr(face_report, "run", _face_run)
    monkeypatch.setattr(body_report, "run", _body_run)


# --- analyse_photo keeps the appearance pointer current (§ appearance) -----


def test_analyse_photo_stamps_the_appearance_pointer(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        appearance.physical_attributes, "current", lambda _db, _uid: None
    )

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    ptr = appearance.current(db, "u1")
    assert ptr and ptr["report_id"]
    rep = appearance.get_report(db, "u1", "current")
    assert rep["face"]["overall_score"] == 6.9
    assert rep["body"]["overall_score"] == 6.4


def test_analyse_photo_appearance_pointer_does_not_regress_earlier_axis(
    monkeypatch,
):
    db = FakeDb()
    monkeypatch.setattr(
        appearance.physical_attributes, "current", lambda _db, _uid: None
    )

    # First run: face-only usable shot.
    _stub_engines(monkeypatch, face=_FACE, body={"usable": False})
    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))
    rep1 = appearance.get_report(db, "u1", "current")
    assert rep1["face"]["overall_score"] == 6.9
    assert rep1["body"] == appearance.NEEDS_BODY

    # Second run: body-only usable shot must not wipe the earlier face read.
    _stub_engines(monkeypatch, face={"usable": False}, body=_BODY)
    _run(auto_analysis.analyse_photo(db, "u1", "b.jpg"))
    rep2 = appearance.get_report(db, "u1", "current")
    assert rep2["face"]["overall_score"] == 6.9  # reused, not regressed
    assert rep2["body"]["overall_score"] == 6.4


def test_analyse_photo_appearance_pointer_skipped_for_unusable_report(
    monkeypatch,
):
    db = FakeDb()
    _stub_engines(monkeypatch, face={"usable": False}, body={"usable": False})

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))

    assert appearance.current(db, "u1") is None or not (
        appearance.current(db, "u1") or {}
    ).get("report_id")


def test_analyse_photo_appearance_pointer_update_never_raises(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        appearance, "record_background_result",
        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")),
    )

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))  # no raise

    # the primary merge still went through even though the pointer update blew up
    assert ("users", "u1", "wiki_pages", "face-analysis") in db.docs


# --- gallery-note enrichment ("used to update their read") -----------------


def test_analyse_photo_appends_a_gallery_note_per_axis(monkeypatch):
    import photo_notes
    import public_profile

    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        public_profile, "_photo_url", lambda p: f"https://cdn.example/{p}"
    )
    monkeypatch.setattr(
        appearance.physical_attributes, "current", lambda _db, _uid: None
    )

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    note = photo_notes.get_note(db, "u1", "https://cdn.example/uploads/u1/a.jpg")
    assert "Used to update their face read." in note["context"]
    assert "Used to update their body read." in note["context"]


def test_analyse_photo_gallery_note_append_does_not_duplicate_on_a_repeat_run(
    monkeypatch,
):
    import photo_notes
    import public_profile

    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        public_profile, "_photo_url", lambda p: f"https://cdn.example/{p}"
    )
    monkeypatch.setattr(
        appearance.physical_attributes, "current", lambda _db, _uid: None
    )

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))
    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    note = photo_notes.get_note(db, "u1", "https://cdn.example/uploads/u1/a.jpg")
    assert note["context"].count("Used to update their face read.") == 1
    assert note["context"].count("Used to update their body read.") == 1


def test_analyse_photo_gallery_note_append_preserves_the_existing_caption(
    monkeypatch,
):
    import photo_notes
    import public_profile

    db = FakeDb()
    _stub_engines(monkeypatch)
    url = "https://cdn.example/uploads/u1/a.jpg"
    monkeypatch.setattr(public_profile, "_photo_url", lambda _p: url)
    monkeypatch.setattr(
        appearance.physical_attributes, "current", lambda _db, _uid: None
    )
    photo_notes.set_context(
        db, "u1", url, context="Suhail on a hike, feeling great."
    )

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    note = photo_notes.get_note(db, "u1", url)
    assert note["context"].startswith("Suhail on a hike, feeling great.")
    assert "Used to update their face read." in note["context"]


def test_analyse_photo_gallery_note_enrichment_never_breaks_the_merge(
    monkeypatch,
):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        appearance.physical_attributes, "current", lambda _db, _uid: None
    )
    monkeypatch.setattr(
        auto_analysis, "_note_analysis_used",
        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom")),
    )

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))  # no raise

    # the primary merge still went through even though the note append blew up
    assert ("users", "u1", "wiki_pages", "face-analysis") in db.docs


# --- analyse_photo --------------------------------------------------------


def test_analyse_photo_merges_usable_reads_into_private_pages(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    face = db.docs[("users", "u1", "wiki_pages", "face-analysis")]
    body = db.docs[("users", "u1", "wiki_pages", "body-analysis")]
    assert face["visibility"] == "private"
    assert face["page_type"] == "face_analysis"
    assert "Overall: 6.9/10 (median across 1 read)" in face["ai_body"]
    assert "Latest read:" in face["ai_body"]
    assert "6.9/10" in face["ai_body"]
    assert len(face["reads"]) == 1
    assert body["visibility"] == "private"
    assert "6.4/10" in body["ai_body"]


def test_analyse_photo_skips_the_unusable_engine(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch, face={"usable": False})

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    assert ("users", "u1", "wiki_pages", "face-analysis") not in db.docs
    assert ("users", "u1", "wiki_pages", "body-analysis") in db.docs


def test_analyse_photo_accumulates_across_photos(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))
    _run(auto_analysis.analyse_photo(db, "u1", "b.jpg"))

    face = db.docs[("users", "u1", "wiki_pages", "face-analysis")]
    assert len(face["reads"]) == 2
    assert "Earlier reads from other photos" in face["ai_body"]
    # each history entry records which photo produced that specific read.
    assert [r["photo"] for r in face["reads"]] == ["a.jpg", "b.jpg"]


def test_analyse_photo_never_raises_on_engine_failure(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _sp: (b"x", "image/jpeg")
    )

    async def _boom(*_a, **_k):
        raise RuntimeError("gemini down")

    monkeypatch.setattr(face_report, "run", _boom)
    monkeypatch.setattr(body_report, "run", _boom)

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))  # no raise
    assert db.docs == {}


def test_analyse_photo_skips_quietly_on_the_credit_cap(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _sp: (b"x", "image/jpeg")
    )

    async def _capped(*_a, **_k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(face_report, "run", _capped)
    monkeypatch.setattr(body_report, "run", _capped)

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))  # no raise
    assert db.docs == {}


def test_analyse_photo_is_a_noop_without_a_path():
    db = FakeDb()
    _run(auto_analysis.analyse_photo(db, "u1", ""))
    assert db.docs == {}


# --- gating: group / face-match / usable-flags ------------------------------


def test_analyse_photo_skips_a_group_shot_entirely(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda _db, _uid: ["users/u1/photo.jpg"],
    )

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={"shot_type": "group"},
    ))

    assert db.docs == {}


def test_analyse_photo_skips_when_the_face_does_not_match(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda _db, _uid: ["users/u1/photo.jpg"],
    )
    async def _classify(*_a, **_k):
        return {"verdict": "not_self"}
    monkeypatch.setattr(face_match, "classify_photo", _classify)

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={
            "shot_type": "full_body",
            "usable_for_face": True,
            "usable_for_body": True,
        },
    ))

    assert db.docs == {}


def test_analyse_photo_skips_on_a_borderline_unverifiable_match(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda _db, _uid: ["users/u1/photo.jpg"],
    )
    async def _classify(*_a, **_k):
        return {"verdict": "unknown"}
    monkeypatch.setattr(face_match, "classify_photo", _classify)

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={
            "shot_type": "face",
            "usable_for_face": True,
            "usable_for_body": True,
        },
    ))

    assert db.docs == {}


def test_analyse_photo_runs_only_the_usable_axis_on_a_confirmed_match(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda _db, _uid: ["users/u1/photo.jpg"],
    )
    async def _classify(*_a, **_k):
        return {"verdict": "self"}
    monkeypatch.setattr(face_match, "classify_photo", _classify)

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={
            "shot_type": "face",
            "usable_for_face": True,
            "usable_for_body": False,
        },
    ))

    assert ("users", "u1", "wiki_pages", "face-analysis") in db.docs
    assert ("users", "u1", "wiki_pages", "body-analysis") not in db.docs


def test_analyse_photo_runs_both_axes_on_a_confirmed_match(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda _db, _uid: ["users/u1/photo.jpg"],
    )
    async def _classify(*_a, **_k):
        return {"verdict": "self"}
    monkeypatch.setattr(face_match, "classify_photo", _classify)

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={
            "shot_type": "full_body",
            "usable_for_face": True,
            "usable_for_body": True,
        },
    ))

    assert ("users", "u1", "wiki_pages", "face-analysis") in db.docs
    assert ("users", "u1", "wiki_pages", "body-analysis") in db.docs


def test_analyse_photo_skips_entirely_when_neither_axis_is_usable(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda _db, _uid: ["users/u1/photo.jpg"],
    )
    async def _classify(*_a, **_k):
        return {"verdict": "self"}
    monkeypatch.setattr(face_match, "classify_photo", _classify)

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={
            "shot_type": "other",
            "usable_for_face": False,
            "usable_for_body": False,
        },
    ))

    assert db.docs == {}


def test_analyse_photo_runs_unconditionally_with_no_reference_at_all(monkeypatch):
    # Brand-new/unverified account with zero photos yet -> nothing to compare
    # against -> fall back to the pre-gating behavior rather than get stuck.
    db = FakeDb()
    _stub_engines(monkeypatch)
    monkeypatch.setattr(
        face_match, "get_reference_photos", lambda _db, _uid: []
    )

    _run(auto_analysis.analyse_photo(
        db, "u1", "a.jpg",
        attributes={
            "shot_type": "face",
            "usable_for_face": True,
            "usable_for_body": False,
        },
    ))

    assert ("users", "u1", "wiki_pages", "face-analysis") in db.docs
    assert ("users", "u1", "wiki_pages", "body-analysis") in db.docs


# --- analyse_web -------------------------------------------------------------


def test_analyse_web_runs_once_sets_the_flag_and_is_a_noop_after(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {
        "first_name": "Ana", "last_name": "Reis",
    }
    monkeypatch.setattr(auto_analysis.firestore, "SERVER_TIMESTAMP", "TS")

    calls = []

    async def _dive(name, *, uid=None, context="", is_self=False, db=None, target_uid="", force=False):
        calls.append((name, uid, is_self))
        return dict(_DIGEST)

    monkeypatch.setattr(deep_dive, "run", _dive)

    _run(auto_analysis.analyse_web(db, "u1"))

    assert calls == [("Ana Reis", "u1", True)]
    assert db.docs[("users", "u1")]["auto_dive_done"] is True
    assert db.docs[("users", "u1")]["auto_dive_at"] == "TS"
    assert ("users", "u1", "wiki_pages", "web-findings") in db.docs

    calls.clear()
    _run(auto_analysis.analyse_web(db, "u1"))
    assert calls == []


def test_analyse_web_leaves_the_flag_unset_when_there_is_no_name(monkeypatch):
    db = FakeDb()  # no profile doc -> no name

    called = []

    async def _dive(*_a, **_k):
        called.append(1)
        return {}

    monkeypatch.setattr(deep_dive, "run", _dive)

    _run(auto_analysis.analyse_web(db, "u1"))

    assert called == []
    assert ("users", "u1") not in db.docs


def test_analyse_web_never_raises_when_the_dive_fails(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"name": "Sam Okafor"}

    async def _boom(*_a, **_k):
        raise RuntimeError("research upstream 500")

    monkeypatch.setattr(deep_dive, "run", _boom)

    _run(auto_analysis.analyse_web(db, "u1"))  # no raise
    assert ("users", "u1") not in db.docs  # flag not set -> retries later


# --- bug L3 / J1: the automatic "web search about me" report completion
# fires a "your report is ready" notification that deep-links straight to the
# rendered report (`/deep-dive/{id}`), instead of writing the report doc
# silently (no notification at all) and leaving the only self-dive entry to
# fall back to the Ayma chat tab. The test fires the real trigger
# (`analyse_web`) and asserts the notification + its report deep-link, not just
# the stored doc.


def test_analyse_web_fires_a_ready_notification_deep_linking_to_the_report(
    monkeypatch,
):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {
        "first_name": "Ana", "last_name": "Reis",
    }
    monkeypatch.setattr(auto_analysis.firestore, "SERVER_TIMESTAMP", "TS")

    async def _dive(name, *, uid=None, context="", is_self=False, db=None,
                    target_uid="", force=False):
        return dict(_DIGEST)  # confidence "medium" + a summary -> a real report

    monkeypatch.setattr(deep_dive, "run", _dive)

    sent = []

    async def _spy(db_, uid, preview, deep_link="chat"):
        sent.append((uid, preview, deep_link))

    monkeypatch.setattr(auto_analysis.notifications_triggers,
                        "notify_skill_done", _spy)

    _run(auto_analysis.analyse_web(db, "u1"))

    expected_id = deep_dive.dive_report_id(name="Ana Reis")  # name_ana-reis
    assert sent == [
        ("u1", "Your web search on yourself is ready.", f"deep_dive/{expected_id}"),
    ]
    # The deep-link resolves to the report route, never the chat fallback.
    assert sent[0][2].startswith("deep_dive/") and sent[0][2] != "deep_dive/"
    assert db.docs[("users", "u1")]["auto_dive_done"] is True


def test_analyse_web_stays_silent_when_the_dive_found_nothing(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"name": "Nemo Nobody"}
    monkeypatch.setattr(auto_analysis.firestore, "SERVER_TIMESTAMP", "TS")

    async def _dive(*_a, **_k):
        return {"summary": "", "confidence": "not_found", "facts": [], "links": []}

    monkeypatch.setattr(deep_dive, "run", _dive)

    sent = []

    async def _spy(*_a, **_k):
        sent.append(_a)

    monkeypatch.setattr(auto_analysis.notifications_triggers,
                        "notify_skill_done", _spy)

    _run(auto_analysis.analyse_web(db, "u1"))

    assert sent == []  # nothing found -> no "ready" notification worth firing
    assert db.docs[("users", "u1")]["auto_dive_done"] is True  # still one-shot


def test_analyse_web_stays_silent_when_the_name_has_no_usable_slug(monkeypatch):
    # SWEEP91-J1R [S2]: a display name that slugs to nothing (e.g. an all
    # non-latin name) has no `dive_report_id` — and the dive doc was never
    # stored under one either (`store_dive` no-ops on an empty key). Emitting a
    # notification then produces the dangling `deep_dive/` link the client
    # can't match, so it silently drops onto the chat tab ("routes to chat"
    # instead of the report). Stay silent rather than point at a report that
    # doesn't exist.
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"name": "中文名字"}
    monkeypatch.setattr(auto_analysis.firestore, "SERVER_TIMESTAMP", "TS")

    # Sanity: this name really does slug to nothing (so the link would dangle).
    assert deep_dive.dive_report_id(name="中文名字") == ""

    async def _dive(name, *, uid=None, context="", is_self=False, db=None,
                    target_uid="", force=False):
        return dict(_DIGEST)  # confidence "medium" + a summary -> would notify

    monkeypatch.setattr(deep_dive, "run", _dive)

    sent = []

    async def _spy(db_, uid, preview, deep_link="chat"):
        sent.append((uid, preview, deep_link))

    monkeypatch.setattr(auto_analysis.notifications_triggers,
                        "notify_skill_done", _spy)

    _run(auto_analysis.analyse_web(db, "u1"))

    assert sent == []  # no dangling `deep_dive/` link emitted
    assert db.docs[("users", "u1")]["auto_dive_done"] is True  # still one-shot
