"""Shared-report references (founder 2026-11-09: reference, not content).

A staged Send-to-Ayma card for a report kind (web research / Appearance)
used to send NO usable context at all: the client staged the card and the
turn carried only a viewing uid, so Ayma answered from the prior
conversation (founder report 2026-11-09, confirmed for both kinds by his
own sends). Now the turn carries only the reference (kind + report id +
subject + the opened run's version stamp), the prompt names the shared
report and requires opening it, and the bound `open_shared_report` tool
pulls the exact record through report_hub's own access rules.
"""

from datetime import datetime, timezone

import gemini
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main
from main import app
from skills import open_shared, session_tool_declarations
from tests.fake_firestore import FakeDb

client = TestClient(app)

UID = "test-uid"
OTHER = "other-uid"

_DIVE_DIGEST = {
    "name": "Suhail Pallath Sulaiman",
    "summary": "ZZZDIVESUMMARY founder of a dating startup in California.",
    "facts": [{"claim": "ZZZDIVEFACT runs a robotics side project."}],
    "confidence": "high",
    "links": [],
    "social_handles": [],
    "web_images": [],
}

# The stored report's created_at is a Firestore timestamp; the version
# stamp the client carries (and the tool compares) is its isoformat —
# both sides derive it from the same stored value through the same
# report_hub pipeline, so equality is by construction.
_RUN1 = datetime(2026, 11, 9, 1, 0, tzinfo=timezone.utc)
_RUN1_STAMP = "2026-11-09T01:00:00+00:00"
_RUN2 = datetime(2026, 11, 9, 6, 30, tzinfo=timezone.utc)

_APPEARANCE_DOC = {
    "created_at": _RUN1,
    "attributes": {"summary": "ZZZAPPEARANCESUMMARY tailored fits."},
    "face": {
        "usable": True,
        "overall_score": 82,
        "verdict": "ZZZAPPEARANCEVERDICT strong jawline read.",
        "strengths": ["ZZZSTRENGTH even lighting"],
        "improvements": [],
        "recommendations": [],
        "quick_facts": [],
    },
    "body": {},
    "photo_count": 3,
}


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    return {"Authorization": "Bearer x"}


def _seeded(monkeypatch, seed):
    db = FakeDb(seed)
    monkeypatch.setattr(main, "get_db", lambda: db)
    return db


# --- the tool itself -------------------------------------------------------


def test_tool_returns_the_exact_deep_dive_report_by_id(monkeypatch):
    db = _seeded(monkeypatch, {
        ("users", UID, "deep_dives", "suhail-self"): {"digest": dict(_DIVE_DIGEST)},
        ("users", UID, "deep_dives", "other-report"): {
            "digest": {**_DIVE_DIGEST, "summary": "ZZZWRONGREPORT summary."}
        },
    })
    text = open_shared.fetch_shared_report_text(
        db, UID, kind="deep_dive", report_id="suhail-self", subject_uid=UID
    )
    assert "ZZZDIVESUMMARY" in text
    assert "ZZZDIVEFACT" in text
    # The exact record by id — not another report from the same collection.
    assert "ZZZWRONGREPORT" not in text


def test_tool_reads_a_cross_user_deep_dive_from_the_subjects_collection(monkeypatch):
    digest = {**_DIVE_DIGEST, "summary": "ZZZDIVEOTHER summary about Maya."}
    db = _seeded(monkeypatch, {
        ("users", OTHER, "deep_dives", "uid_other-uid"): {"digest": digest},
    })
    text = open_shared.fetch_shared_report_text(
        db, UID, kind="deep_dive", report_id="uid_other-uid", subject_uid=OTHER
    )
    assert "ZZZDIVEOTHER" in text


def test_tool_missing_report_fails_honestly(monkeypatch):
    db = _seeded(monkeypatch, {})
    text = open_shared.fetch_shared_report_text(
        db, UID, kind="deep_dive", report_id="no-such-report", subject_uid=UID
    )
    assert text.startswith("error:")
    assert "couldn't open" in text


def test_tool_returns_the_appearance_report_for_its_owner(monkeypatch):
    db = _seeded(monkeypatch, {
        ("users", UID, "appearance_reports", "current"): dict(_APPEARANCE_DOC),
    })
    text = open_shared.fetch_shared_report_text(
        db,
        UID,
        kind="appearance",
        report_id=UID,
        subject_uid=UID,
        version=_RUN1_STAMP,
    )
    assert "ZZZAPPEARANCEVERDICT" in text


def test_tool_appearance_refuses_a_rerun_since_the_share(monkeypatch):
    """The shared reference names the exact run the user opened (its
    created_at stamp); a re-run replaced the record, so the pull must
    fail honestly instead of answering about the new run."""
    doc = {**_APPEARANCE_DOC, "created_at": _RUN2}
    db = _seeded(monkeypatch, {
        ("users", UID, "appearance_reports", "current"): doc,
    })
    text = open_shared.fetch_shared_report_text(
        db,
        UID,
        kind="appearance",
        report_id=UID,
        subject_uid=UID,
        version=_RUN1_STAMP,
    )
    assert text.startswith("error:")
    assert "re-run" in text
    assert "ZZZAPPEARANCEVERDICT" not in text


def test_tool_appearance_is_owner_only(monkeypatch):
    db = _seeded(monkeypatch, {
        ("users", OTHER, "appearance_reports", "current"): dict(_APPEARANCE_DOC),
    })
    text = open_shared.fetch_shared_report_text(
        db, UID, kind="appearance", report_id=OTHER, subject_uid=OTHER
    )
    assert text.startswith("error:")
    assert "ZZZAPPEARANCEVERDICT" not in text


def test_tool_match_is_participants_only(monkeypatch):
    db = _seeded(monkeypatch, {
        ("matches", "other-uid__third-uid"): {
            "score": 0.5,
            "ai_explanation": "ZZZNOTYOURMATCH",
            "user_explanation": {},
        },
    })
    text = open_shared.fetch_shared_report_text(
        db, UID, kind="match", report_id="other-uid__third-uid",
        subject_uid=OTHER,
    )
    assert text.startswith("error:")
    assert "ZZZNOTYOURMATCH" not in text


def test_declaration_only_present_when_shared():
    names = {d["name"] for d in session_tool_declarations()}
    assert "open_shared_report" not in names
    names = {d["name"] for d in session_tool_declarations(shared=True)}
    assert "open_shared_report" in names


# --- the /chat turn --------------------------------------------------------


def _capture_chat(monkeypatch, seed, payload):
    seen = {}

    async def _capture(message, system_prompt=None, tool_declarations=None,
                       tool_fns=None, **_kw):
        seen["prompt"] = system_prompt or ""
        seen["names"] = {d["name"] for d in (tool_declarations or [])}
        seen["fns"] = tool_fns or {}
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    _seeded(monkeypatch, seed)
    resp = client.post("/chat", json=payload, headers=_auth(monkeypatch))
    assert resp.status_code == 200, resp.text
    return seen


def test_chat_turn_with_deep_dive_reference_binds_the_pull_tool(monkeypatch):
    seed = {
        ("users", UID, "deep_dives", "suhail-self"): {"digest": dict(_DIVE_DIGEST)},
    }
    seen = _capture_chat(monkeypatch, seed, {
        "message": "what do y think",
        "viewing_profile_uid": UID,
        "shared_kind": "deep_dive",
        "shared_ref_id": "suhail-self",
        "shared_subject_uid": UID,
        "shared_subject_name": "Suhail Pallath Sulaiman",
    })
    # The prompt names the shared report and requires opening it...
    assert "SHARED REPORT" in seen["prompt"]
    assert "web research report on Suhail Pallath Sulaiman" in seen["prompt"]
    assert "open_shared_report" in seen["prompt"]
    # ...but carries the REFERENCE only — never the report's contents.
    assert "ZZZDIVESUMMARY" not in seen["prompt"]
    assert "ZZZDIVEFACT" not in seen["prompt"]
    # The tool is declared and bound to this exact reference: calling it
    # (as the model does before answering) pulls the real report in.
    assert "open_shared_report" in seen["names"]
    pulled = seen["fns"]["open_shared_report"]()
    assert "ZZZDIVESUMMARY" in pulled
    assert "ZZZDIVEFACT" in pulled


def test_chat_turn_with_appearance_reference_binds_the_pull_tool(monkeypatch):
    seed = {
        ("users", UID, "appearance_reports", "current"): dict(_APPEARANCE_DOC),
    }
    seen = _capture_chat(monkeypatch, seed, {
        "message": "what do u think",
        "viewing_profile_uid": UID,
        "shared_kind": "appearance",
        "shared_ref_id": UID,
        "shared_subject_uid": UID,
        "shared_subject_name": "Your appearance report",
        "shared_ref_version": _RUN1_STAMP,
    })
    assert "SHARED REPORT" in seen["prompt"]
    assert "Appearance report" in seen["prompt"]
    assert "ZZZAPPEARANCEVERDICT" not in seen["prompt"]
    assert "open_shared_report" in seen["names"]
    pulled = seen["fns"]["open_shared_report"]()
    assert "ZZZAPPEARANCEVERDICT" in pulled


def test_chat_turn_without_a_share_gets_no_pull_tool(monkeypatch):
    seen = _capture_chat(monkeypatch, {}, {"message": "hi"})
    assert "open_shared_report" not in seen["names"]
    assert "open_shared_report" not in seen["fns"]
    assert "SHARED REPORT" not in seen["prompt"]


def test_chat_stream_turn_with_deep_dive_reference_binds_the_pull_tool(
    monkeypatch,
):
    seen = {}

    async def _events(message, system_prompt=None, tool_declarations=None,
                      tool_fns=None, **_kw):
        seen["prompt"] = system_prompt or ""
        seen["names"] = {d["name"] for d in (tool_declarations or [])}
        seen["fns"] = tool_fns or {}
        yield {"type": "reply", "text": "ok", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    _seeded(monkeypatch, {
        ("users", UID, "deep_dives", "suhail-self"): {"digest": dict(_DIVE_DIGEST)},
    })
    resp = client.post(
        "/chat/stream",
        json={
            "message": "what do y think",
            "viewing_profile_uid": UID,
            "shared_kind": "deep_dive",
            "shared_ref_id": "suhail-self",
            "shared_subject_uid": UID,
            "shared_subject_name": "Suhail Pallath Sulaiman",
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200, resp.text
    assert "SHARED REPORT" in seen["prompt"]
    assert "open_shared_report" in seen["names"]
    assert "ZZZDIVESUMMARY" in seen["fns"]["open_shared_report"]()


def test_chat_turn_persists_the_posted_card_for_history(monkeypatch):
    """End to end (founder bug 2026-11-09): the card posted with a send is
    persisted on the user turn and returned by /chat/history, so the chat
    can render the same tappable card after a restart. A profile share is
    used on purpose: it never sets the shared_* tool reference, so this
    proves the card round-trips on its own channel for every kind."""
    db = _seeded(monkeypatch, {})

    async def _capture(message, system_prompt=None, tool_declarations=None,
                       tool_fns=None, **_kw):
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        json={
            "message": "what do y think",
            "client_msg_id": "card-send-1",
            "viewing_profile_uid": OTHER,
            "shared_card_kind": "profile",
            "shared_card_uid": OTHER,
            "shared_card_name": "Dana",
            "shared_card_photo": "https://example.com/dana.jpg",
            "shared_card_ref_id": "",
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200, resp.text

    docs = [
        d.to_dict()
        for d in db.collection("users")
        .document(UID)
        .collection("chat_messages")
        .stream()
    ]
    user_docs = [d for d in docs if d.get("role") == "user"]
    assert len(user_docs) == 1, docs
    card = user_docs[0]
    assert card["shared_card_kind"] == "profile"
    assert card["shared_card_uid"] == OTHER
    assert card["shared_card_name"] == "Dana"
    assert card["shared_card_photo"] == "https://example.com/dana.jpg"
    assert card["shared_card_ref_id"] == ""
    # The reply row never carries a card.
    ayma_docs = [d for d in docs if d.get("role") == "ayma"]
    assert ayma_docs and "shared_card_kind" not in ayma_docs[0]

    hist = client.get(
        "/chat/history?limit=10", headers=_auth(monkeypatch)
    )
    assert hist.status_code == 200, hist.text
    rows = [m for m in hist.json()["messages"] if m["role"] == "user"]
    assert len(rows) == 1, hist.json()
    assert rows[0]["shared_card_kind"] == "profile"
    assert rows[0]["shared_card_uid"] == OTHER
    assert rows[0]["shared_card_name"] == "Dana"
    assert rows[0]["shared_card_photo"] == "https://example.com/dana.jpg"
    assert rows[0]["shared_card_ref_id"] == ""


def test_chat_turn_without_a_card_persists_none(monkeypatch):
    db = _seeded(monkeypatch, {})

    async def _capture(message, system_prompt=None, tool_declarations=None,
                       tool_fns=None, **_kw):
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        json={"message": "hi", "client_msg_id": "plain-send-1"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200, resp.text
    docs = [
        d.to_dict()
        for d in db.collection("users")
        .document(UID)
        .collection("chat_messages")
        .stream()
    ]
    assert docs, "the turn should still persist"
    for d in docs:
        assert "shared_card_kind" not in d
