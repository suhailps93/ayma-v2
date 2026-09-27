"""Tests for ai_assessment — Ayma's judgment layer behind "AI notes".

Covers, per the founder feature (2026-09-26):
* distinct-prompt generation over fake data produces judgment-style notes,
  including a red flag grounded in a moderation-flagged DM (the Dillu case)
  and a green flag;
* incremental gating: unchanged inputs never re-hit Gemini; the DM watermark
  keeps already-seen messages out of later prompts; the debounce holds for
  unflagged material and a new moderation flag bypasses it;
* ledger metering under the dedicated `ai_notes` feature, uncapped;
* surface: the assessment page appears in `story.get_ai_notes` (the screen the
  founder reads) but never in the Story editor, and stays out of the standing
  chat context while remaining recall-reachable.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import ai_assessment
import gemini
import story
import token_ledger
import wiki_query
from fake_firestore import FakeDb

UID = "u1"
OTHER = "u2"


def _dt(day: int, hour: int = 12) -> datetime:
    return datetime(2026, 9, day, hour, tzinfo=timezone.utc)


_FLAGGED_TEXT = "hey wanna see something naughty tonight"
_KIND_TEXT = "that gallery show you mentioned sounded amazing - how was it?"

_MODEL_NOTES = {
    "notes": [
        {
            "observation": (
                "Sent an unsolicited sexual message to a match - potentially "
                "repulsive behaviour."
            ),
            "evidence": "DM to Dillu, 2026-09-12 (moderation-flagged: sexual content)",
            "polarity": "red",
            "severity": "high",
        },
        {
            "observation": "Shows genuine curiosity about his matches' lives.",
            "evidence": "DM to Dillu, 2026-09-13",
            "polarity": "green",
            "severity": "medium",
        },
    ]
}


def _db() -> FakeDb:
    db = FakeDb()
    db.docs[("users", UID, "wiki_pages", "identity")] = {
        "page_type": "identity",
        "visibility": "public",
        "ai_body": "Suhail, 40, lives in Kochi.",
    }
    db.docs[("users", OTHER, "profile", "main")] = {"name": "Dillu Thomas"}
    db.docs[("dm_threads", "t1")] = {
        "participants": [UID, OTHER],
        "last_message_at": _dt(13),
    }
    db.docs[("dm_threads", "t1", "messages", "m1")] = {
        "sender_uid": UID,
        "type": "text",
        "body": _FLAGGED_TEXT,
        "created_at": _dt(12),
        "moderated": True,
        "moderation_reason": "unsolicited sexual content",
        "moderation_categories": ["sexual"],
    }
    db.docs[("dm_threads", "t1", "messages", "m2")] = {
        "sender_uid": UID,
        "type": "text",
        "body": _KIND_TEXT,
        "created_at": _dt(13),
    }
    # Inbound message — never part of the user's own behavioural signals.
    db.docs[("dm_threads", "t1", "messages", "m3")] = {
        "sender_uid": OTHER,
        "type": "text",
        "body": "please stop messaging me like that",
        "created_at": _dt(12, 13),
    }
    return db


def _fake_gemini(calls: list, notes=None):
    async def _json(contents, system_prompt, response_schema=None, **kw):
        calls.append({"contents": contents, "system": system_prompt, "kw": kw})
        return dict(_MODEL_NOTES) if notes is None else notes

    return _json


def _run(coro):
    # Not asyncio.run(): that unsets the global event loop on exit, and this
    # file sorts before test_backfill_ops.py, whose legacy
    # `get_event_loop().run_until_complete` _run still needs it. A private
    # loop leaves global asyncio state untouched.
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _page(db):
    return db.docs.get(("users", UID, "wiki_pages", ai_assessment.PAGE_ID))


# --- generation ----------------------------------------------------------------


def test_refresh_builds_judgment_page_from_wiki_and_flagged_dms(monkeypatch):
    db = _db()
    calls: list = []
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini(calls))

    assert _run(ai_assessment.refresh(db, UID)) is True
    assert len(calls) == 1

    contents = calls[0]["contents"]
    # The flagged DM (the Dillu case) is in the prompt, with its verdict and
    # the recipient's name.
    assert _FLAGGED_TEXT in contents
    assert "unsolicited sexual content" in contents
    assert "Dillu" in contents
    # The unflagged outbound sample and the wiki are there too; inbound
    # messages from the other person are not.
    assert _KIND_TEXT in contents
    assert "Suhail, 40, lives in Kochi." in contents
    assert "please stop messaging me" not in contents
    # Distinct prompt: the judgment instructions, not the ingest prompt.
    assert "candid" in calls[0]["system"].lower()
    assert "polarity" in calls[0]["system"]

    page = _page(db)
    assert page is not None
    assert page["page_type"] == ai_assessment.PAGE_TYPE
    assert page["visibility"] == "ai_only"
    body = page["ai_body"]
    assert "Red flags" in body and "Green flags" in body
    assert "(high) Sent an unsolicited sexual message" in body
    assert "DM to Dillu, 2026-09-12" in body
    # Compact digest for matching: red first, severity carried.
    digest = page["frontmatter"]["digest"]
    assert digest.startswith("RED(high):")
    assert "GREEN(medium):" in digest
    assert ai_assessment.digest(db, UID) == digest


def test_metered_under_own_feature_uncapped(monkeypatch):
    db = _db()
    calls: list = []
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini(calls))

    _run(ai_assessment.refresh(db, UID))

    kw = calls[0]["kw"]
    assert kw["feature"] == token_ledger.FEATURE_AI_NOTES == "ai_notes"
    assert kw["uid"] == UID
    # Ayma-initiated background judgment: still recorded, never blocked on an
    # empty balance (same stance as completeness/persona evolution).
    assert kw["enforce_cap"] is False


def test_empty_model_notes_still_write_placeholder_and_gate(monkeypatch):
    db = _db()
    calls: list = []
    monkeypatch.setattr(
        gemini, "generate_json", _fake_gemini(calls, notes={"notes": []})
    )

    assert _run(ai_assessment.refresh(db, UID)) is True
    page = _page(db)
    assert "Nothing noteworthy yet." in page["ai_body"]
    assert page["frontmatter"]["digest"] == ""
    # The empty result still stamps the gate, so the next pass skips.
    assert _run(ai_assessment.refresh(db, UID)) is False
    assert len(calls) == 1


# --- incremental gating ---------------------------------------------------------


def test_unchanged_inputs_never_rerun(monkeypatch):
    db = _db()
    calls: list = []
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini(calls))

    assert _run(ai_assessment.refresh(db, UID)) is True
    assert _run(ai_assessment.refresh(db, UID)) is False
    assert _run(ai_assessment.refresh(db, UID)) is False
    assert len(calls) == 1


def test_new_unflagged_material_is_debounced_then_incremental(monkeypatch):
    db = _db()
    calls: list = []
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini(calls))
    _run(ai_assessment.refresh(db, UID))

    # A new outbound DM lands minutes later: the gate sees new material but
    # the non-flag debounce holds — no second paid call yet.
    db.docs[("dm_threads", "t1", "messages", "m4")] = {
        "sender_uid": UID,
        "type": "text",
        "body": "coffee saturday? I know a quiet place near the marina",
        "created_at": _dt(14),
    }
    assert _run(ai_assessment.refresh(db, UID)) is False
    assert len(calls) == 1

    # Age the last run past the debounce window -> it runs, and the prompt is
    # incremental: only the message NEWER than the stored watermark is in the
    # sample (m2 was already consumed last run), while the flagged message is
    # always in scope, and the previous notes ride along for carry-forward.
    key = ("users", UID, "wiki_pages", ai_assessment.PAGE_ID)
    db.docs[key]["generated_at_ms"] = (
        db.docs[key]["generated_at_ms"]
        - (ai_assessment._MIN_REFRESH_INTERVAL_S + 60) * 1000
    )
    assert _run(ai_assessment.refresh(db, UID)) is True
    assert len(calls) == 2
    contents = calls[1]["contents"]
    assert "coffee saturday?" in contents
    assert _KIND_TEXT not in contents
    assert _FLAGGED_TEXT in contents
    assert "Sent an unsolicited sexual message" in contents  # prior notes


def test_new_moderation_flag_bypasses_debounce(monkeypatch):
    db = _db()
    calls: list = []
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini(calls))
    _run(ai_assessment.refresh(db, UID))

    # Moderation flags an (old) message after the last run — the founder's
    # canonical case must not wait out the debounce.
    db.docs[("dm_threads", "t1", "messages", "m2")] = dict(
        db.docs[("dm_threads", "t1", "messages", "m2")],
        moderated=True,
        moderation_reason="sexual content",
        moderation_categories=["sexual"],
    )
    assert _run(ai_assessment.refresh(db, UID)) is True
    assert len(calls) == 2
    assert f'[FLAGGED: sexual content; categories: sexual] to Dillu' in calls[1][
        "contents"
    ]


def test_nothing_to_judge_is_a_noop(monkeypatch):
    db = FakeDb()  # no wiki, no DMs
    calls: list = []
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini(calls))
    assert _run(ai_assessment.refresh(db, UID)) is False
    assert calls == []


# --- surfaces --------------------------------------------------------------------


def test_page_shows_in_ai_notes_view_but_not_story_editor(monkeypatch):
    db = _db()
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini([]))
    _run(ai_assessment.refresh(db, UID))

    notes_ids = [s["page_id"] for s in story.get_ai_notes(db, UID)["sections"]]
    assert ai_assessment.PAGE_ID in notes_ids
    section = next(
        s
        for s in story.get_ai_notes(db, UID)["sections"]
        if s["page_id"] == ai_assessment.PAGE_ID
    )
    assert section["visibility"] == "ai_only"
    assert "Red flags" in section["body"]

    story_ids = [s["page_id"] for s in story.get_story(db, UID)["sections"]]
    assert ai_assessment.PAGE_ID not in story_ids


def test_excluded_from_chat_context_but_recall_reachable(monkeypatch):
    db = _db()
    monkeypatch.setattr(gemini, "generate_json", _fake_gemini([]))
    _run(ai_assessment.refresh(db, UID))

    standing = wiki_query.read_wiki_context(
        db, UID, exclude_page_types=ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT
    )
    assert "Red flags" not in standing
    assert "Suhail, 40" in standing  # the rest of the wiki still flows

    # Unfiltered AI read path (and matching, via its own labeled digest
    # block) still sees it; recall(topic) finds it by keyword.
    assert "Red flags" in wiki_query.read_wiki_context(db, UID)
    assert "unsolicited sexual message" in wiki_query.recall_snippets(
        db, UID, "any red flags or repulsive behaviour in assessment?"
    )
