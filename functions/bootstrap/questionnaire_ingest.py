"""Mandatory session-end questionnaire capture (requirements 3 & 4).

The in-call model is *asked* to call ``record_answer`` the moment a user answers
a tree question — but historically nothing guaranteed it did, so a real answer
given right before a session ended (out of credits, dropped network, app killed)
was acknowledged in-session and then never written anywhere structured, and the
node it belonged to read as unanswered and got re-asked next session (the
2026-09-20 incident; see :func:`post_turn.persist_and_ingest`).

This module closes that at the structured-store level. It runs on the existing
session-end ingest path (:func:`wiki_ingest.ingest`, with
``capture_questionnaire=True``), deterministically — not depending on the model
remembering — and does two things from one Gemini pass over the turn window:

1. **Tree answers.** For every still-open questionnaire item, if the user
   concretely answered it in this conversation, record it through the same
   validated write the ``record_answer`` tool uses
   (:func:`skills.questionnaire.record_answer_direct`) — questionnaire doc,
   hard-filter mirror, completeness recompute. This is the "record_answer as
   the first line" guarantee.

2. **Supplemental topics.** Information the user volunteered that matches no tree
   item — an off-tree topic, or an answer to something that was never asked — is
   recorded in tree-node shape (section, topic, value, state) in the per-user
   supplemental store (:mod:`supplemental`), so the check-before-asking gate
   counts it as known and never raises it again. The shared master
   ``question_tree.json`` is never edited.

Best-effort throughout: this never raises, so it is safe inside the
shutdown/disconnect ingest hook, and a failure simply leaves the next session to
try again (the nightly backfill re-runs the same path).
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

import gemini
import question_tree
import supplemental
import token_ledger
from skills import questionnaire as questionnaire_skill
from transcript import ROLE_USER, Turn

logger = logging.getLogger("ayma.questionnaire_ingest")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "questionnaire_ingest.md"

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "answers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "node_id": {"type": "string"},
                    "value": {"type": "string"},
                    "source": {"type": "string", "enum": ["stated", "inferred"]},
                },
                "required": ["node_id", "value"],
            },
        },
        "supplemental": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "section": {"type": "string"},
                    "topic": {"type": "string"},
                    "value": {"type": "string"},
                    "status": {
                        "type": "string",
                        "enum": list(supplemental.VALID_STATUS),
                    },
                },
                "required": ["topic", "value"],
            },
        },
    },
    "required": ["answers"],
}


@lru_cache(maxsize=1)
def _load_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _questionnaire_store(db, uid: str) -> dict[str, dict]:
    out: dict[str, dict] = {}
    try:
        for snap in (
            db.collection("users")
            .document(uid)
            .collection("questionnaire")
            .stream()
        ):
            out[snap.id] = snap.to_dict() or {}
    except Exception:  # noqa: BLE001 - no store read just means every node is open
        logger.exception("questionnaire store read failed for %s", uid)
    return out


def _profile(db, uid: str) -> dict:
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
        )
        return (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001
        return {}


def _open_candidates(store: dict, profile: dict) -> list[dict]:
    """The intent tree's nodes that have no recorded structured answer yet — the
    only items worth extracting (an already-recorded node is left untouched)."""
    intent = (
        (store.get("relationship_intent") or {}).get("value")
        or profile.get("relationship_intent")
        or profile.get("qz_relationship_intent")
    )
    return [
        n for n in question_tree.nodes_for_intent(intent)
        if n["id"] not in store
        and not (profile.get(f"qz_{n['id']}") is not None and str(profile.get(f"qz_{n['id']}")).strip())
    ]


def _candidate_block(candidates: list[dict]) -> str:
    items = [
        {
            "id": n["id"],
            "section": n["page_type"],
            "label": n["label"],
            "kind": n["kind"],
            "options": n.get("options"),
            "scale": n.get("scale"),
            "ayma_prompt": n.get("ayma_prompt"),
        }
        for n in candidates
    ]
    sections = sorted(supplemental._valid_sections())
    return (
        "OPEN QUESTIONNAIRE ITEMS:\n"
        + json.dumps({"items": items}, ensure_ascii=False)
        + "\n\nALLOWED SECTIONS:\n"
        + json.dumps({"sections": sections}, ensure_ascii=False)
    )


def _conversation_block(turns: list[Turn]) -> str:
    out = ["Recent conversation:"]
    for t in turns:
        who = "User" if t.role == ROLE_USER else "Ayma"
        text = (t.text or "").strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)


def _has_user_speech(turns: list[Turn]) -> bool:
    return any(t.role == ROLE_USER and (t.text or "").strip() for t in turns)


async def record_from_turns(db, uid: str, session_id: str, turns: list[Turn]) -> dict:
    """Run one deterministic capture pass. Returns
    ``{"answers": n, "supplemental": m}`` (counts actually recorded). Never
    raises."""
    result = {"answers": 0, "supplemental": 0}
    if not uid or not turns or not _has_user_speech(turns):
        return result
    try:
        store = _questionnaire_store(db, uid)
        candidates = _open_candidates(store, _profile(db, uid))
        # Nothing open and nothing can be volunteered into a tree item — but the
        # user can still volunteer an off-tree topic, so only skip the LLM when
        # there is genuinely nothing to do: there is always a supplemental path,
        # so run whenever there is user speech. (The candidate list may be empty;
        # the model then returns answers=[] and only supplemental, which is fine.)
        contents = _candidate_block(candidates) + "\n\n" + _conversation_block(turns)
        raw = await gemini.generate_json(
            contents,
            system_prompt=_load_prompt(),
            response_schema=_RESPONSE_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_QUESTIONNAIRE,
            session_id=session_id,
            enforce_cap=False,
            temperature=0.0,
        )
    except Exception:  # noqa: BLE001 - best-effort; the next session retries
        logger.exception("questionnaire capture pass failed for %s/%s", uid, session_id)
        return result

    data = raw if isinstance(raw, dict) else {}
    candidate_ids = {n["id"] for n in candidates}

    for a in data.get("answers") or []:
        if not isinstance(a, dict):
            continue
        nid = str(a.get("node_id") or "").strip()
        value = str(a.get("value") or "").strip()
        source = str(a.get("source") or "stated").strip().lower()
        # Only record a still-open item, through the shared validated write —
        # which rejects a thin/invalid answer and leaves the node open.
        if nid in candidate_ids and value:
            out = questionnaire_skill.record_answer_direct(
                db, uid, nid, value, source, session_id=session_id, turns=turns
            )
            if isinstance(out, str) and out.startswith("recorded"):
                result["answers"] += 1

    for s in data.get("supplemental") or []:
        if not isinstance(s, dict):
            continue
        slug = supplemental.record_supplemental(
            db,
            uid,
            str(s.get("section") or ""),
            str(s.get("topic") or ""),
            str(s.get("value") or ""),
            str(s.get("status") or "answered"),
            session_id=session_id,
        )
        if slug:
            result["supplemental"] += 1

    # A supplemental write doesn't itself trigger a completeness recompute (only
    # _record does, per tree answer); schedule one so the state-check surface
    # reflects the just-captured volunteered topics. Best-effort, no-op without
    # a running loop (e.g. a sync unit test).
    if result["supplemental"]:
        try:
            import completeness

            completeness.schedule(db, uid)
        except Exception:  # noqa: BLE001
            pass

    if result["answers"] or result["supplemental"]:
        logger.info(
            "questionnaire capture uid=%s session=%s answers=%d supplemental=%d",
            uid, session_id, result["answers"], result["supplemental"],
        )
    return result
