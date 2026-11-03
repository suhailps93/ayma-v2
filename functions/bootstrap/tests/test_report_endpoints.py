"""Endpoint-level tests for the generic reports API: GET /report/{type}/{id}
and POST /report/{type}/{id}/correct. The centerpiece is the
ownership-enforcement scenario end to end: a non-owner can read a report
they're allowed to view today (a deep-dive/web-search report on someone
else) and would be allowed to chat/ask about it, but their correction
attempt is rejected with 403 while the owner's own succeeds."""

import chat_history
import deep_dive
import main
import notifications_triggers
import report_hub
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="u1"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def test_report_get_requires_auth():
    assert client.get("/report/appearance/u1").status_code in (401, 403)


def test_report_correct_requires_auth():
    resp = client.post(
        "/report/appearance/u1/correct",
        json={"block_ids": ["face"], "scope": "block", "message": "fix it"},
    )
    assert resp.status_code in (401, 403)


def test_report_get_404_for_unknown_report_type(monkeypatch):
    resp = client.get("/report/not_a_type/x", headers=_auth(monkeypatch))
    assert resp.status_code == 404


def test_report_correct_404_for_unknown_report_type(monkeypatch):
    resp = client.post(
        "/report/not_a_type/x/correct",
        json={"block_ids": ["b1"], "scope": "block", "message": "fix"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 404


def test_report_get_404_when_hub_raises_keyerror(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _raise(*a, **k):
        raise KeyError("gone")

    monkeypatch.setattr(report_hub, "get_report", _raise)
    resp = client.get("/report/appearance/u1", headers=_auth(monkeypatch))
    assert resp.status_code == 404


def test_report_get_403_when_hub_raises_permissionerror(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _raise(*a, **k):
        raise PermissionError("nope")

    monkeypatch.setattr(report_hub, "get_report", _raise)
    resp = client.get("/report/story_private/other-uid", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 403


def test_report_get_returns_hub_shape(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    out = {
        "title": "Appearance",
        "sections": [],
        "meta": {"owner_uid": "u1", "viewer_can_edit": True, "created_at": None, "updated_at": None},
    }
    monkeypatch.setattr(report_hub, "get_report", lambda db, t, rid, uid: out)
    resp = client.get("/report/appearance/u1", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    assert resp.json() == out


def test_report_correct_403_when_hub_raises_permissionerror(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _raise(*a, **k):
        raise PermissionError("only the owner")

    monkeypatch.setattr(report_hub, "correct", _raise)
    resp = client.post(
        "/report/deep_dive/uid_owner/correct",
        json={"block_ids": ["fact:f1"], "scope": "block", "message": "wrong"},
        headers=_auth(monkeypatch, uid="someone-else"),
    )
    assert resp.status_code == 403


def test_report_correct_404_when_hub_raises_keyerror(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _raise(*a, **k):
        raise KeyError("gone")

    monkeypatch.setattr(report_hub, "correct", _raise)
    resp = client.post(
        "/report/appearance/u1/correct",
        json={"block_ids": ["face"], "scope": "block", "message": "fix it"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 404


def test_report_correct_422_when_hub_raises_valueerror(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _raise(*a, **k):
        raise ValueError("bad scope")

    monkeypatch.setattr(report_hub, "correct", _raise)
    resp = client.post(
        "/report/appearance/u1/correct",
        json={"block_ids": ["face"], "scope": "block", "message": "fix it"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 422


def test_report_correct_requires_at_least_one_block_id(monkeypatch):
    resp = client.post(
        "/report/appearance/u1/correct",
        json={"block_ids": [], "scope": "block", "message": "fix it"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 422  # pydantic min_length=1


def test_report_correct_rejects_bad_scope(monkeypatch):
    resp = client.post(
        "/report/appearance/u1/correct",
        json={"block_ids": ["face"], "scope": "whole_universe", "message": "fix it"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 422  # pydantic Literal


def test_report_correct_success_shape(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    out = {"ok": True, "results": [{"block_id": "face", "ok": True, "reply": "got it"}]}

    async def _correct(db, t, rid, uid, *, block_ids, scope, message):
        assert block_ids == ["face"] and scope == "block" and message == "too harsh"
        return out

    monkeypatch.setattr(report_hub, "correct", _correct)
    resp = client.post(
        "/report/appearance/u1/correct",
        json={"block_ids": ["face"], "scope": "block", "message": "too harsh"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 200
    assert resp.json() == out


def test_report_correct_persists_the_exchange_to_chat_history(monkeypatch):
    # ONE chat (§ D13): a tap-to-correct turn lands in chat history like any
    # /chat turn, with the reply mirroring the client's combinedReply
    # (distinct non-empty per-block replies joined).
    monkeypatch.setattr(main, "get_db", lambda: object())
    out = {"ok": True, "results": [
        {"block_id": "b1", "ok": True, "reply": "got it — updated"},
        {"block_id": "b2", "ok": True, "reply": "got it — updated"},
        {"block_id": "b3", "ok": True, "reply": "and flagged for review"},
    ]}

    async def _correct(db, t, rid, uid, *, block_ids, scope, message):
        return out

    monkeypatch.setattr(report_hub, "correct", _correct)
    appended = []
    monkeypatch.setattr(
        chat_history, "append",
        lambda db, uid, role, text, **kw: appended.append((role, text)),
    )
    notified = []

    async def _notify(db, uid, text):
        notified.append(text)

    monkeypatch.setattr(notifications_triggers, "notify_ayma_reply", _notify)
    resp = client.post(
        "/report/deep_dive/r1/correct",
        json={"block_ids": ["b1", "b2", "b3"], "scope": "block", "message": "Delete"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 200
    assert appended == [
        ("user", "Delete"),
        ("ayma", "got it — updated\n\nand flagged for review"),
    ]
    assert notified == ["got it — updated\n\nand flagged for review"]


def test_report_correct_history_falls_back_when_no_block_replied(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    out = {"ok": False, "results": [{"block_id": "b1", "ok": False, "reply": ""}]}

    async def _correct(db, t, rid, uid, *, block_ids, scope, message):
        return out

    monkeypatch.setattr(report_hub, "correct", _correct)
    appended = []
    monkeypatch.setattr(
        chat_history, "append",
        lambda db, uid, role, text, **kw: appended.append((role, text)),
    )
    monkeypatch.setattr(
        notifications_triggers, "notify_ayma_reply", lambda *a, **k: None
    )
    resp = client.post(
        "/report/deep_dive/r1/correct",
        json={"block_ids": ["b1"], "scope": "block", "message": "Delete"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 200
    assert appended == [("user", "Delete"), ("ayma", "Couldn't do that.")]


# --- the centerpiece: ownership enforcement end to end, through report_hub
# for real (no monkeypatching report_hub itself) on a deep-dive report ------


_DIGEST = {
    "name": "Jane Doe", "summary": "Works as a designer.", "confidence": "high",
    "facts": [{"id": "f1", "claim": "Studied at MIT", "category": "education", "confidence": "high"}],
    "links": [],
}


def test_non_owner_can_read_deep_dive_report_but_only_owner_can_correct_it(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(deep_dive, "report_owner", lambda rid, uid: "owner-uid")
    monkeypatch.setattr(
        deep_dive, "read_dive",
        lambda db, uid, rid: {"digest": dict(_DIGEST), "name": "Jane Doe"},
    )

    # A non-owner CAN read the report (existing app visibility: anyone can
    # open a deep-dive report they know the id of, same as
    # GET /deep-dive-report/{id} today) — and, per the spec, would be
    # allowed to chat/ask Ayma about it informationally (that chat wiring
    # is out of scope here; this only confirms the read isn't blocked).
    get_resp = client.get(
        "/report/deep_dive/uid_owner-uid", headers=_auth(monkeypatch, uid="someone-else"),
    )
    assert get_resp.status_code == 200
    body = get_resp.json()
    assert body["meta"]["owner_uid"] == "owner-uid"
    assert body["meta"]["viewer_can_edit"] is False
    fact_block_ids = [
        b["block_id"] for sec in body["sections"] for b in sec["blocks"]
        if b["block_id"].startswith("fact:")
    ]
    assert fact_block_ids == ["fact:f1"]

    # The SAME non-owner's mutation attempt is rejected server-side — 403,
    # not just hidden client-side.
    correct_resp = client.post(
        "/report/deep_dive/uid_owner-uid/correct",
        json={"block_ids": ["fact:f1"], "scope": "block", "message": "that's not me"},
        headers=_auth(monkeypatch, uid="someone-else"),
    )
    assert correct_resp.status_code == 403

    # The actual OWNER's correction on the exact same block succeeds.
    async def _correct_finding(db, uid, rid, *, target, feedback):
        assert uid == "owner-uid"
        return {"reply": "removed the MIT claim"}

    monkeypatch.setattr(deep_dive, "correct_finding", _correct_finding)
    owner_resp = client.post(
        "/report/deep_dive/uid_owner-uid/correct",
        json={"block_ids": ["fact:f1"], "scope": "block", "message": "that's not me"},
        headers=_auth(monkeypatch, uid="owner-uid"),
    )
    assert owner_resp.status_code == 200
    assert owner_resp.json()["ok"] is True
    assert owner_resp.json()["results"][0]["reply"] == "removed the MIT claim"


def test_non_owner_can_read_public_story_but_only_owner_can_correct_it(monkeypatch):
    import physical_attributes
    import story

    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(physical_attributes, "current", lambda db, uid: None)
    monkeypatch.setattr(
        story, "get_story",
        lambda db, uid: {
            "sections": [
                {"page_id": "identity", "title": "Identity", "body": "Product designer.", "visibility": "public"}
            ]
        },
    )

    get_resp = client.get(
        "/report/story_public/owner-uid", headers=_auth(monkeypatch, uid="someone-else"),
    )
    assert get_resp.status_code == 200
    assert get_resp.json()["meta"]["viewer_can_edit"] is False

    correct_resp = client.post(
        "/report/story_public/owner-uid/correct",
        json={"block_ids": ["page:identity:sent:0"], "scope": "block", "message": "delete"},
        headers=_auth(monkeypatch, uid="someone-else"),
    )
    assert correct_resp.status_code == 403


def test_non_owner_cannot_even_read_owner_only_report_types(monkeypatch):
    import appearance

    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        appearance, "get_report",
        lambda db, uid, rid: {"attributes": {}, "face": {}, "body": {}},
    )
    resp = client.get(
        "/report/appearance/owner-uid", headers=_auth(monkeypatch, uid="someone-else"),
    )
    assert resp.status_code == 403


# --- match: both participants can read, neither can correct — end to end,
# through report_hub for real (no monkeypatching report_hub itself). See
# report_hub.py's module docstring for why this type has no correction path
# at all: a match score is algorithmically computed, not user-authored
# content.

_MATCH_DOC = {
    "score": 0.75,
    "score_confidence": 0.7,
    "user_explanation": {
        "alice-uid": "You two share a lot of values.",
        "bob-uid": "Bob's own note.",
    },
    "dimensions": [
        {"key": "values", "label": "Values & worldview", "weight": 0.22,
         "score": 80.0, "rationale": "Aligned priorities.", "evidence": [],
         "confidence": "high", "source": "structured"},
    ],
    "shared": [], "tensions": [], "missing": [], "gate_failures": [],
}


def test_both_participants_can_read_a_match_report_a_stranger_cannot(monkeypatch):
    import matching_skill
    import deep_dive as dd

    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    monkeypatch.setattr(dd, "profile_full_name", lambda db, uid: "Bob Bee")

    for uid, expect_sentence in (
        ("alice-uid", "You two share a lot of values."),
        ("bob-uid", "Bob's own note."),
    ):
        resp = client.get(
            "/report/match/alice-uid__bob-uid", headers=_auth(monkeypatch, uid=uid),
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["meta"]["viewer_can_edit"] is False
        text = " ".join(
            b.get("text", "") for sec in body["sections"] for b in sec["blocks"]
        )
        assert expect_sentence in text

    # A stranger to the pair gets 404, not 403 — never told this pair even
    # exists (§ report_hub.resolve_owner's own docstring).
    stranger_resp = client.get(
        "/report/match/alice-uid__bob-uid", headers=_auth(monkeypatch, uid="eve-uid"),
    )
    assert stranger_resp.status_code == 404


def test_a_participant_cannot_correct_their_own_match_report(monkeypatch):
    """`viewer_can_edit` is false for a match participant (unlike every
    other report type here), so the real client never shows a quick-action;
    this pins down that even a direct POST from a genuine participant still
    can't mutate anything — it gets a real reply, not a 200 no-op that would
    look like it worked."""
    import matching_skill
    import deep_dive as dd

    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(matching_skill, "read_match", lambda db, mid: dict(_MATCH_DOC))
    monkeypatch.setattr(dd, "profile_full_name", lambda db, uid: "Bob Bee")

    resp = client.post(
        "/report/match/alice-uid__bob-uid/correct",
        json={"block_ids": ["score"], "scope": "block", "message": "this is wrong"},
        headers=_auth(monkeypatch, uid="alice-uid"),
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is False
    assert "nothing here to correct" in body["results"][0]["reply"]


# --- public_profile: the same view GET /explore/profile serves, as blocks ---
#
# The whole point of the type is redaction parity: whatever the pages
# payload shows/hides for a viewer, the block report shows/hides
# identically, because report_adapters.public_profile_blocks reads through
# the SAME public_profile._public_pages the explore endpoint serves. These
# run both endpoints against one real in-memory fake Firestore — nothing
# monkeypatched at the hub/adapter level.


def _public_profile_fake_db(monkeypatch):
    import public_profile as pp
    from test_public_profile import FakeDb

    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    # Photos/score are orthogonal to redaction and need real Storage/scoring
    # — same stand-ins test_public_profile itself uses.
    monkeypatch.setattr(pp, "_photo_url", lambda sp: None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: None)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("users", "her", "wiki_pages", "about")] = {
        "visibility": "public", "page_type": "identity",
        "user_edits": "Grew up sailing. {{private}}Bad breakup.{{/private}}",
    }
    db.docs[("users", "her", "wiki_pages", "secret")] = {
        "visibility": "private", "page_type": "family", "ai_body": "hidden thing",
    }
    db.docs[("users", "her", "wiki_pages", "pulled")] = {
        "visibility": "public", "page_type": "career", "ai_body": "pulled body",
        "user_hidden": True,
    }
    return db


def _report_texts(report_body):
    return " ".join(
        b.get("text", "")
        for sec in report_body["sections"]
        for b in sec["blocks"]
    )


def test_public_profile_report_redaction_matches_explore_profile(monkeypatch):
    _public_profile_fake_db(monkeypatch)
    headers = _auth(monkeypatch, uid="me")

    explore = client.get("/explore/profile/her", headers=headers)
    report = client.get("/report/public_profile/her", headers=headers)
    assert explore.status_code == 200 and report.status_code == 200

    explore_bodies = " ".join(p["body"] for p in explore.json()["pages"])
    report_texts = _report_texts(report.json())

    # Visible in both; every redacted thing absent from BOTH.
    assert "Grew up sailing." in explore_bodies
    assert "Grew up sailing." in report_texts
    for hidden in ("Bad breakup", "hidden thing", "pulled body", "{{"):
        assert hidden not in explore_bodies
        assert hidden not in report_texts

    meta = report.json()["meta"]
    assert meta["owner_uid"] == "her"
    assert meta["viewer_can_edit"] is False


def test_public_profile_report_blocked_pair_behaves_like_explore_profile(monkeypatch):
    """A blocked pair: /explore/profile still serves the pages (the client
    shows its own "You've blocked this person." header note), so the block
    report serves the same sections — neither endpoint invents extra
    redaction the other doesn't apply."""
    from matching_schema import block_id

    db = _public_profile_fake_db(monkeypatch)
    db.docs[("blocks", block_id("me", "her"))] = {"blocked_at": 1}
    headers = _auth(monkeypatch, uid="me")

    explore = client.get("/explore/profile/her", headers=headers)
    report = client.get("/report/public_profile/her", headers=headers)
    assert explore.status_code == 200 and report.status_code == 200
    assert explore.json()["blocked"] is True

    explore_bodies = " ".join(p["body"] for p in explore.json()["pages"])
    report_texts = _report_texts(report.json())
    assert "Grew up sailing." in explore_bodies
    assert "Grew up sailing." in report_texts
    assert "Bad breakup" not in report_texts


def test_public_profile_report_deleted_user_is_empty_like_explores_placeholder(monkeypatch):
    db = _public_profile_fake_db(monkeypatch)
    db.docs[("deleted_users", "her")] = {"deleted_at": 1}
    headers = _auth(monkeypatch, uid="me")

    explore = client.get("/explore/profile/her", headers=headers)
    report = client.get("/report/public_profile/her", headers=headers)
    assert explore.status_code == 200 and report.status_code == 200
    assert explore.json()["deleted"] is True
    assert explore.json()["pages"] == []
    assert report.json()["sections"] == []


def test_public_profile_report_404s_for_a_nameless_profile_like_explore(monkeypatch):
    db = _public_profile_fake_db(monkeypatch)
    db.docs[("users", "her", "profile", "main")] = {"name": ""}
    headers = _auth(monkeypatch, uid="me")

    assert client.get("/explore/profile/her", headers=headers).status_code == 404
    assert client.get("/report/public_profile/her", headers=headers).status_code == 404


def test_public_profile_report_correct_is_403_for_a_viewer(monkeypatch):
    _public_profile_fake_db(monkeypatch)
    resp = client.post(
        "/report/public_profile/her/correct",
        json={"block_ids": ["sec:0:sent:0"], "scope": "block", "message": "change it"},
        headers=_auth(monkeypatch, uid="me"),
    )
    assert resp.status_code == 403
