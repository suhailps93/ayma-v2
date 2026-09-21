"""Reverse-image search for "other pictures of me" (§ web photo search)."""

import asyncio
from types import SimpleNamespace

import deep_dive
import deep_dive_images
import media_embed
import reverse_image_search as ris
import skill_reports
from test_deep_dive import _FakeDb


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _img(url):
    return SimpleNamespace(url=url)


def _page(url, title, full=None, partial=None):
    return SimpleNamespace(
        url=url,
        page_title=title,
        full_matching_images=full or [],
        partial_matching_images=partial or [],
    )


def _detection(full=None, partial=None, similar=None, pages=None):
    return SimpleNamespace(
        full_matching_images=full or [],
        partial_matching_images=partial or [],
        visually_similar_images=similar or [],
        pages_with_matching_images=pages or [],
    )


# --- _candidates_from_detection ---------------------------------------------


def test_candidates_from_detection_attaches_the_page_a_full_match_came_from():
    detection = _detection(
        full=[_img("https://cdn.example/a.jpg")],
        pages=[
            _page(
                "https://site.example/bio", "Bio",
                full=[_img("https://cdn.example/a.jpg")],
            )
        ],
    )
    out = ris._candidates_from_detection(detection)
    assert out == [
        {
            "image_url": "https://cdn.example/a.jpg",
            "match_type": "full",
            "source_url": "https://site.example/bio",
            "source_title": "Bio",
        }
    ]


def test_candidates_from_detection_dedupes_across_categories():
    same = "https://cdn.example/a.jpg"
    detection = _detection(full=[_img(same)], partial=[_img(same)])
    out = ris._candidates_from_detection(detection)
    assert len(out) == 1
    assert out[0]["match_type"] == "full"  # full wins, first occurrence


def test_candidates_from_detection_includes_similar_images_unattributed():
    detection = _detection(similar=[_img("https://cdn.example/other.jpg")])
    out = ris._candidates_from_detection(detection)
    assert out == [
        {
            "image_url": "https://cdn.example/other.jpg",
            "match_type": "similar",
            "source_url": "",
            "source_title": "",
        }
    ]


def test_candidates_from_detection_caps_the_result_count():
    many = [_img(f"https://cdn.example/{i}.jpg") for i in range(20)]
    detection = _detection(full=many)
    out = ris._candidates_from_detection(detection)
    assert len(out) == ris._MAX_CANDIDATES_PER_SCAN


def test_candidates_from_detection_empty_for_none():
    assert ris._candidates_from_detection(None) == []


# --- scan ----------------------------------------------------------------


def _stub_photo(monkeypatch, path="uploads/u1/a.jpg", *, refs=True, face_match=True):
    """Stub the primary-photo lookup and photo download, plus (by default) a
    usable reference embedding and a passing face-match gate — the "happy
    path" every pre-existing scan test assumes. Pass ``refs=False`` to
    simulate no usable reference photo yet, or ``face_match=False`` to
    simulate a Web Detection hit that isn't confidently this user's face."""
    monkeypatch.setattr(
        skill_reports, "primary_profile_photo_path", lambda _db, _uid: path
    )
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _p: (b"bytes", "image/jpeg")
    )
    monkeypatch.setattr(
        deep_dive_images,
        "reference_embeddings_for",
        lambda _db, _uid: ([[1.0, 0.0]] if refs else []),
    )

    async def _fn(*_a, **_k):
        return face_match

    monkeypatch.setattr(ris, "_face_matches_user", _fn)


def test_scan_stages_new_candidates_as_pending(monkeypatch):
    db = _FakeDb()
    _stub_photo(monkeypatch)
    detection = _detection(full=[_img("https://cdn.example/a.jpg")])
    monkeypatch.setattr(ris, "_web_detect", lambda _b: detection)

    created = _run(ris.scan(db, "u1"))
    assert len(created) == 1
    cid = created[0]["candidate_id"]
    stored = db.data[("users", "u1", "web_photo_candidates", cid)]
    assert stored["status"] == ris.STATUS_PENDING
    assert stored["image_url"] == "https://cdn.example/a.jpg"
    assert stored["match_type"] == "full"


def test_scan_does_not_restage_an_already_decided_candidate(monkeypatch):
    db = _FakeDb()
    _stub_photo(monkeypatch)
    detection = _detection(full=[_img("https://cdn.example/a.jpg")])
    monkeypatch.setattr(ris, "_web_detect", lambda _b: detection)

    cid = ris._candidate_id("https://cdn.example/a.jpg")
    db.seed(
        ("users", "u1", "web_photo_candidates", cid),
        {"status": ris.STATUS_REJECTED, "image_url": "https://cdn.example/a.jpg"},
    )

    created = _run(ris.scan(db, "u1"))
    assert created == []
    assert (
        db.data[("users", "u1", "web_photo_candidates", cid)]["status"]
        == ris.STATUS_REJECTED
    )


def test_scan_is_a_noop_without_a_photo(monkeypatch):
    db = _FakeDb()
    monkeypatch.setattr(
        skill_reports, "primary_profile_photo_path", lambda _db, _uid: ""
    )
    assert _run(ris.scan(db, "u1")) == []


def test_scan_never_raises_when_vision_errors(monkeypatch):
    db = _FakeDb()
    _stub_photo(monkeypatch)

    def _boom(_b):
        raise RuntimeError("vision down")

    monkeypatch.setattr(ris, "_web_detect", _boom)
    assert _run(ris.scan(db, "u1")) == []  # no raise


def test_scan_uses_explicit_storage_paths_when_given(monkeypatch):
    db = _FakeDb()
    monkeypatch.setattr(
        deep_dive_images, "reference_embeddings_for", lambda _db, _uid: [[1.0, 0.0]]
    )
    seen = []
    monkeypatch.setattr(
        media_embed,
        "download_bytes",
        lambda p: (seen.append(p), (b"x", "image/jpeg"))[1],
    )
    monkeypatch.setattr(ris, "_web_detect", lambda _b: _detection())
    _run(ris.scan(db, "u1", storage_paths=["a.jpg", "b.jpg"]))
    assert seen == ["a.jpg", "b.jpg"]


def test_scan_discards_a_candidate_that_fails_face_match(monkeypatch):
    """A Web Detection hit that isn't confidently the user's own face is
    never staged — this is the trust/safety fix: a stranger's photo must
    never reach the confirm/reject screen (founder report: a wrong-ethnicity
    match got staged with no face check at all)."""
    db = _FakeDb()
    _stub_photo(monkeypatch, face_match=False)
    detection = _detection(similar=[_img("https://cdn.example/stranger.jpg")])
    monkeypatch.setattr(ris, "_web_detect", lambda _b: detection)

    created = _run(ris.scan(db, "u1"))
    assert created == []
    cid = ris._candidate_id("https://cdn.example/stranger.jpg")
    assert ("users", "u1", "web_photo_candidates", cid) not in db.data


def test_scan_stages_a_genuine_face_match(monkeypatch):
    """The mirror case: a Web Detection hit that IS confidently the user's
    own face still gets staged, exactly as before — the gate only removes
    false positives, it doesn't block real matches."""
    db = _FakeDb()
    _stub_photo(monkeypatch, face_match=True)
    detection = _detection(similar=[_img("https://cdn.example/really-me.jpg")])
    monkeypatch.setattr(ris, "_web_detect", lambda _b: detection)

    created = _run(ris.scan(db, "u1"))
    assert len(created) == 1
    assert created[0]["image_url"] == "https://cdn.example/really-me.jpg"
    cid = ris._candidate_id("https://cdn.example/really-me.jpg")
    assert db.data[("users", "u1", "web_photo_candidates", cid)]["status"] == (
        ris.STATUS_PENDING
    )


def test_scan_skips_entirely_without_a_reference_photo(monkeypatch):
    """Early in onboarding, before any photo has been uploaded/embedded (or
    verified via the selfie flow), there's nothing safe to face-match
    against — scan must no-op rather than stage unverified candidates. It
    should bail before even calling Vision."""
    db = _FakeDb()
    _stub_photo(monkeypatch, refs=False)
    calls = {"n": 0}

    def _boom(_b):
        calls["n"] += 1
        return _detection()

    monkeypatch.setattr(ris, "_web_detect", _boom)

    created = _run(ris.scan(db, "u1"))
    assert created == []
    assert calls["n"] == 0  # never even ran Vision — nothing to verify against


# --- _face_matches_user -------------------------------------------------


def test_face_matches_user_true_when_verified_and_a_real_face(monkeypatch):
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda _u: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda _b, _m: [1.0, 0.0]
    )
    monkeypatch.setattr(
        deep_dive_images, "classify_face_match", lambda _e, _r, **_k: "self"
    )

    async def _face(*_a, **_k):
        return True

    monkeypatch.setattr(deep_dive_images, "_has_detectable_face", _face)

    ok = _run(
        ris._face_matches_user("u1", "https://x/a.jpg", refs=[[1.0, 0.0]])
    )
    assert ok is True


def test_face_matches_user_false_when_not_the_same_person(monkeypatch):
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda _u: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda _b, _m: [0.0, 1.0]
    )
    monkeypatch.setattr(
        deep_dive_images, "classify_face_match", lambda _e, _r, **_k: "not_self"
    )

    ok = _run(
        ris._face_matches_user("u1", "https://x/a.jpg", refs=[[1.0, 0.0]])
    )
    assert ok is False


def test_face_matches_user_false_when_uncertain(monkeypatch):
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda _u: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda _b, _m: [0.7, 0.7]
    )
    monkeypatch.setattr(
        deep_dive_images, "classify_face_match", lambda _e, _r, **_k: "unknown"
    )

    ok = _run(
        ris._face_matches_user("u1", "https://x/a.jpg", refs=[[1.0, 0.0]])
    )
    assert ok is False


def test_face_matches_user_false_on_fetch_failure(monkeypatch):
    def _boom(_u):
        raise RuntimeError("404 not found")

    monkeypatch.setattr(deep_dive_images, "_fetch_image", _boom)

    ok = _run(
        ris._face_matches_user("u1", "https://x/a.jpg", refs=[[1.0, 0.0]])
    )
    assert ok is False


def test_face_matches_user_false_on_embed_failure(monkeypatch):
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda _u: (b"img", "image/jpeg")
    )

    def _boom(_b, _m):
        raise RuntimeError("embedding service down")

    monkeypatch.setattr(media_embed, "embed_image_bytes", _boom)

    ok = _run(
        ris._face_matches_user("u1", "https://x/a.jpg", refs=[[1.0, 0.0]])
    )
    assert ok is False


def test_face_matches_user_false_when_similarity_high_but_no_real_face(
    monkeypatch,
):
    # Same-person cosine similarity clears, but the detectable-face gate
    # says the image doesn't actually show a real photographed face (e.g. a
    # coincidentally-similar flat-color avatar) — must still be discarded.
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda _u: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda _b, _m: [1.0, 0.0]
    )
    monkeypatch.setattr(
        deep_dive_images, "classify_face_match", lambda _e, _r, **_k: "self"
    )

    async def _face(*_a, **_k):
        return False

    monkeypatch.setattr(deep_dive_images, "_has_detectable_face", _face)

    ok = _run(
        ris._face_matches_user("u1", "https://x/a.jpg", refs=[[1.0, 0.0]])
    )
    assert ok is False


def test_scan_missing_vision_dependency_logs_and_returns_quietly(monkeypatch):
    db = _FakeDb()
    _stub_photo(monkeypatch)

    def _boom(_b):
        raise ModuleNotFoundError("no google.cloud.vision")

    monkeypatch.setattr(ris, "_web_detect", _boom)
    assert _run(ris.scan(db, "u1")) == []


# --- auto_scan (one-time onboarding trigger) --------------------------------


def test_auto_scan_runs_once_and_sets_the_flag(monkeypatch):
    db = _FakeDb()
    _stub_photo(monkeypatch)
    monkeypatch.setattr(ris, "_web_detect", lambda _b: _detection())

    _run(ris.auto_scan(db, "u1"))
    assert db.data[("users", "u1")]["web_photo_scan_done"] is True

    calls = {"n": 0}

    async def _scan(*_a, **_k):
        calls["n"] += 1
        return []

    monkeypatch.setattr(ris, "scan", _scan)
    _run(ris.auto_scan(db, "u1"))
    assert calls["n"] == 0  # already done — no-op


def test_auto_scan_leaves_the_flag_unset_without_a_photo(monkeypatch):
    db = _FakeDb()
    monkeypatch.setattr(
        skill_reports, "primary_profile_photo_path", lambda _db, _uid: ""
    )
    _run(ris.auto_scan(db, "u1"))
    assert "web_photo_scan_done" not in db.data.get(("users", "u1"), {})


def test_auto_scan_never_raises_on_failure(monkeypatch):
    db = _FakeDb()
    _stub_photo(monkeypatch)

    async def _boom(*_a, **_k):
        raise RuntimeError("boom")

    monkeypatch.setattr(ris, "scan", _boom)
    _run(ris.auto_scan(db, "u1"))  # no raise
    assert db.data[("users", "u1")]["web_photo_scan_done"] is True


# --- confirm / reject --------------------------------------------------------


def _seed_report(db, uid, name):
    key = deep_dive.dive_report_id(name=name)
    db.seed(
        ("users", uid, "deep_dives", key),
        {
            "digest": {"name": name, "facts": [], "summary": ""},
            "target_uid": "",
            "name": name,
        },
    )
    return key


def _seed_candidate(db, uid, cid, **extra):
    db.seed(
        ("users", uid, "web_photo_candidates", cid),
        {
            "candidate_id": cid,
            "image_url": "https://cdn.example/a.jpg",
            "source_url": "https://site.example",
            "source_title": "Bio",
            "status": ris.STATUS_PENDING,
            **extra,
        },
    )


def test_confirm_candidate_merges_into_the_persistent_report():
    db = _FakeDb()
    db.seed(("users", "u1", "profile", "main"), {"name": "Dana Reis"})
    key = _seed_report(db, "u1", "Dana Reis")
    _seed_candidate(db, "u1", "cand1")

    result = ris.confirm_candidate(db, "u1", "cand1")
    assert result["status"] == ris.STATUS_CONFIRMED
    assert (
        db.data[("users", "u1", "web_photo_candidates", "cand1")]["status"]
        == ris.STATUS_CONFIRMED
    )

    report = db.data[("users", "u1", "deep_dives", key)]
    confirmed = report["digest"]["confirmed_photos"]
    assert len(confirmed) == 1
    assert confirmed[0]["image_url"] == "https://cdn.example/a.jpg"
    assert confirmed[0]["source_url"] == "https://site.example"


def test_confirm_candidate_is_idempotent():
    db = _FakeDb()
    db.seed(("users", "u1", "profile", "main"), {"name": "Dana Reis"})
    key = _seed_report(db, "u1", "Dana Reis")
    _seed_candidate(db, "u1", "cand1")

    ris.confirm_candidate(db, "u1", "cand1")
    ris.confirm_candidate(db, "u1", "cand1")

    report = db.data[("users", "u1", "deep_dives", key)]
    assert len(report["digest"]["confirmed_photos"]) == 1


def test_confirm_candidate_404s_style_none_when_missing():
    db = _FakeDb()
    assert ris.confirm_candidate(db, "u1", "ghost") is None


def test_confirm_candidate_without_a_report_yet_still_updates_the_candidate():
    db = _FakeDb()
    db.seed(("users", "u1", "profile", "main"), {"name": "Dana Reis"})
    _seed_candidate(db, "u1", "cand1")  # no deep_dives report seeded

    result = ris.confirm_candidate(db, "u1", "cand1")  # no raise
    assert result["status"] == ris.STATUS_CONFIRMED
    assert not any(k[:2] == ("users", "u1") and "deep_dives" in k for k in db.data)


def test_reject_candidate_never_touches_the_report():
    db = _FakeDb()
    db.seed(("users", "u1", "profile", "main"), {"name": "Dana Reis"})
    key = _seed_report(db, "u1", "Dana Reis")
    _seed_candidate(db, "u1", "cand1")

    result = ris.reject_candidate(db, "u1", "cand1")
    assert result["status"] == ris.STATUS_REJECTED
    report = db.data[("users", "u1", "deep_dives", key)]
    assert not report["digest"].get("confirmed_photos")


def test_reject_candidate_404s_style_none_when_missing():
    db = _FakeDb()
    assert ris.reject_candidate(db, "u1", "ghost") is None


# --- list_candidates ---------------------------------------------------------


def test_list_candidates_only_returns_pending_by_default():
    db = _FakeDb()
    db.seed(
        ("users", "u1", "web_photo_candidates", "p"),
        {"status": ris.STATUS_PENDING, "image_url": "x"},
    )
    db.seed(
        ("users", "u1", "web_photo_candidates", "c"),
        {"status": ris.STATUS_CONFIRMED, "image_url": "y"},
    )
    out = ris.list_candidates(db, "u1")
    assert [c["candidate_id"] for c in out] == ["p"]


def test_list_candidates_include_decided():
    db = _FakeDb()
    db.seed(
        ("users", "u1", "web_photo_candidates", "p"),
        {"status": ris.STATUS_PENDING, "image_url": "x"},
    )
    db.seed(
        ("users", "u1", "web_photo_candidates", "c"),
        {"status": ris.STATUS_CONFIRMED, "image_url": "y"},
    )
    out = ris.list_candidates(db, "u1", include_decided=True)
    assert {c["candidate_id"] for c in out} == {"p", "c"}


def test_list_candidates_read_failure_is_swallowed():
    class _Boom:
        def collection(self, *_a):
            raise RuntimeError("firestore down")

    assert ris.list_candidates(_Boom(), "u1") == []


# --- POST /onboarding/complete, /web-search/photos/* ------------------------

from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as firebase_auth  # noqa: E402

import main  # noqa: E402

_client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    return {"Authorization": "Bearer valid"}


def test_onboarding_complete_schedules_both_jobs_when_eligible(monkeypatch):
    monkeypatch.setattr(main, "_should_auto_dive", lambda _uid: True)
    monkeypatch.setattr(main, "_should_auto_scan_photos", lambda _uid: True)
    calls = {"dive": 0, "scan": 0}

    async def _dive(*_a, **_k):
        calls["dive"] += 1

    async def _scan(*_a, **_k):
        calls["scan"] += 1

    monkeypatch.setattr(main.auto_analysis, "analyse_web", _dive)
    monkeypatch.setattr(main.reverse_image_search, "auto_scan", _scan)

    r = _client.post("/onboarding/complete", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {"triggered": True, "web_search": True, "photo_scan": True}
    assert calls == {"dive": 1, "scan": 1}


def test_onboarding_complete_is_a_noop_when_already_done(monkeypatch):
    monkeypatch.setattr(main, "_should_auto_dive", lambda _uid: False)
    monkeypatch.setattr(main, "_should_auto_scan_photos", lambda _uid: False)

    r = _client.post("/onboarding/complete", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {
        "triggered": False, "web_search": False, "photo_scan": False,
    }


def test_web_search_photo_candidates_endpoint(monkeypatch):
    monkeypatch.setattr(
        main.reverse_image_search, "list_candidates",
        lambda _db, uid: [{"candidate_id": "c1", "image_url": "https://x/a.jpg"}],
    )
    r = _client.get("/web-search/photos/candidates", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {
        "candidates": [{"candidate_id": "c1", "image_url": "https://x/a.jpg"}]
    }


def test_web_search_photo_rescan_queues_a_background_scan(monkeypatch):
    seen = {}

    async def _scan(_db, uid, *, storage_paths=None):
        seen["uid"] = uid
        seen["storage_paths"] = storage_paths

    monkeypatch.setattr(main.reverse_image_search, "scan", _scan)
    r = _client.post(
        "/web-search/photos/rescan",
        headers=_auth(monkeypatch),
        json={"storage_paths": ["a.jpg"]},
    )
    assert r.status_code == 200
    assert r.json() == {"queued": True}
    assert seen == {"uid": "me", "storage_paths": ["a.jpg"]}


def test_web_search_photo_rescan_defaults_to_the_primary_photo(monkeypatch):
    seen = {}

    async def _scan(_db, uid, *, storage_paths=None):
        seen["storage_paths"] = storage_paths

    monkeypatch.setattr(main.reverse_image_search, "scan", _scan)
    r = _client.post("/web-search/photos/rescan", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert seen["storage_paths"] is None


def test_web_search_photo_confirm_endpoint(monkeypatch):
    monkeypatch.setattr(
        main.reverse_image_search, "confirm_candidate",
        lambda _db, uid, cid: {"candidate_id": cid, "status": "confirmed"},
    )
    r = _client.post(
        "/web-search/photos/candidates/c1/confirm", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True, "candidate": {"candidate_id": "c1", "status": "confirmed"}}


def test_web_search_photo_confirm_endpoint_404s_when_missing(monkeypatch):
    monkeypatch.setattr(
        main.reverse_image_search, "confirm_candidate",
        lambda *_a, **_k: None,
    )
    r = _client.post(
        "/web-search/photos/candidates/ghost/confirm", headers=_auth(monkeypatch)
    )
    assert r.status_code == 404


def test_web_search_photo_reject_endpoint(monkeypatch):
    monkeypatch.setattr(
        main.reverse_image_search, "reject_candidate",
        lambda _db, uid, cid: {"candidate_id": cid, "status": "rejected"},
    )
    r = _client.post(
        "/web-search/photos/candidates/c1/reject", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True, "candidate": {"candidate_id": "c1", "status": "rejected"}}
