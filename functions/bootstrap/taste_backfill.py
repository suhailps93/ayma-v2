"""Taste backfill — fill a user's public Taste page from their existing context.

The Qloo "Taste match" card (``taste_match.py``) reads each person's public
Taste page (``Music: … / Film: … / Food: …``). That page is populated only when
the user answers the taste questionnaire nodes or when ``wiki_ingest`` catches a
favourite mid-conversation — so a user who talked about films and food long ago,
but was only ever asked about music, ends up with a half-empty card.

This module mines the content the user ALREADY has — their Story (every wiki
page) and their past voice + text conversation history — for music / film / food
favourites, and folds them onto the Taste page through the same deterministic
path a direct answer takes (``skills.questionnaire.merge_taste_mentions``: proper
names only, deduped, capped at 5 per domain, appended — never overwriting a
direct answer). It only ever writes names the user themselves stated, onto their
own public Taste page, by exactly the rules ``wiki_ingest`` already applies.

Best-effort and idempotent: when all three taste domains already have entries it
is a cheap no-op (three Firestore reads, no LLM); it never blocks or fails the
surface it rides on. Triggered when the taste signal is thin — on profile /
completeness / questionnaire reads and lazily when the taste card would render
with empty domains (see the callers in ``main.py`` / ``taste_match.py``).
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from prompt import load_prompt_file
import chat_history
import gemini
import token_ledger
import wiki_query
from skills import questionnaire

logger = logging.getLogger("ayma.taste_backfill")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "taste_extract.md"

_DOMAINS = ("music", "film", "food")

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "music": {"type": "array", "items": {"type": "string"}},
        "film": {"type": "array", "items": {"type": "string"}},
        "food": {"type": "array", "items": {"type": "string"}},
    },
}

# Source-text budgets (chars). The wiki/story is small; the transcript can be
# large, so it is tail-capped (the most recent turns are the most relevant) and
# the whole blob is bounded so one backfill call stays cheap.
_MAX_WIKI_CHARS = 8000
_MAX_TRANSCRIPT_CHARS = 12000
_MAX_TURNS = 400


def _taste_values(db, uid: str) -> dict[str, str]:
    """``{domain: value}`` for the three taste questionnaire nodes (empty string
    when a node is missing/blank). This is the authoritative taste signal —
    ``_sync_taste_page`` composes the public Taste page straight from these."""
    qcol = db.collection("users").document(uid).collection("questionnaire")
    out: dict[str, str] = {}
    for domain, node_id in questionnaire._TASTE_DOMAIN_NODES.items():
        snap = qcol.document(node_id).get()
        value = ""
        if getattr(snap, "exists", False):
            value = " ".join(str((snap.to_dict() or {}).get("value") or "").split())
        out[domain] = value
    return out


def is_thin(db, uid: str) -> bool:
    """True when ANY taste domain (music/film/food) has no entry yet — the
    signal that a backfill is worth attempting. Cheap: three Firestore reads,
    no LLM."""
    if not uid:
        return False
    try:
        values = _taste_values(db, uid)
    except Exception:  # noqa: BLE001 - a read failure just means "don't bother"
        logger.exception("taste_backfill: thin check read failed for %s", uid)
        return False
    return any(not values.get(d) for d in _DOMAINS)


def _transcript_text(db, uid: str) -> str:
    """The user's past voice + text turns as ``User:`` / ``Ayma:`` lines, oldest
    first, tail-capped to the most recent ``_MAX_TRANSCRIPT_CHARS``."""
    try:
        turns = chat_history._collect(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("taste_backfill: transcript read failed for %s", uid)
        return ""
    turns.sort(key=lambda t: (t.get("ts") is None, t.get("ts")))
    lines: list[str] = []
    for t in turns[-_MAX_TURNS:]:
        text = str(t.get("text") or "").strip()
        if not text:
            continue
        who = "User" if t.get("role") == "user" else "Ayma"
        lines.append(f"{who}: {text}")
    return "\n".join(lines)[-_MAX_TRANSCRIPT_CHARS:]


def _gather_source_text(db, uid: str) -> str:
    """The user's Story (all wiki pages, incl. any existing Taste page) plus
    their conversation history — the full existing context the extractor mines.
    Runs synchronous Firestore reads, so call it off the event loop."""
    parts: list[str] = []
    try:
        wiki = wiki_query.read_wiki_context(db, uid, max_chars=_MAX_WIKI_CHARS)
    except Exception:  # noqa: BLE001
        logger.exception("taste_backfill: wiki read failed for %s", uid)
        wiki = ""
    if wiki:
        parts.append("=== THEIR STORY (compiled profile notes) ===\n" + wiki)
    transcript = _transcript_text(db, uid)
    if transcript:
        parts.append("=== PAST CONVERSATIONS ===\n" + transcript)
    return "\n\n".join(parts)


async def backfill(db, uid: str, *, force: bool = False) -> list[str]:
    """Mine the user's Story + conversation history for taste favourites and fold
    them onto their public Taste page. Returns the domains that gained a name
    (``[]`` on a no-op).

    Idempotent: unless ``force``, a no-op the moment all three taste domains
    already have entries (no LLM call). Best-effort: any failure is logged and
    yields ``[]`` — it never raises."""
    if not uid:
        return []
    try:
        if not force and not is_thin(db, uid):
            return []
        text = await asyncio.to_thread(_gather_source_text, db, uid)
        if not text.strip():
            return []
        extracted = await gemini.generate_json(
            text,
            load_prompt_file(_PROMPT_PATH),
            _RESPONSE_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_TASTE_BACKFILL,
            enforce_cap=False,
            temperature=0.0,
        )
        mentions = {
            d: extracted.get(d)
            for d in _DOMAINS
            if isinstance(extracted, dict) and isinstance(extracted.get(d), list)
        }
        if not any(mentions.get(d) for d in _DOMAINS):
            return []
        # merge_taste_mentions validates the names (proper-name caps), appends
        # (dedup, max 5) without clobbering a direct answer, and re-syncs the
        # public Taste page. Synchronous Firestore writes → run off the loop.
        changed = await asyncio.to_thread(
            questionnaire.merge_taste_mentions, db, uid, mentions
        )
        if changed:
            logger.info(
                "taste_backfill: filled %s for %s", ", ".join(changed), uid
            )
        return changed
    except Exception:  # noqa: BLE001 - best-effort; never fail the caller
        logger.exception("taste_backfill: backfill failed for %s", uid)
        return []


async def _safe_backfill(db, uid: str) -> None:
    try:
        await backfill(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("taste_backfill: scheduled backfill failed for %s", uid)


def schedule(db, uid: str) -> bool:
    """Fire-and-forget a best-effort backfill on the running loop when the user's
    taste signal is thin. Returns False (a no-op) when the taste is already full,
    there's no uid, or there's no running loop (e.g. a synchronous unit test)."""
    if not db or not uid:
        return False
    try:
        if not is_thin(db, uid):
            return False
    except Exception:  # noqa: BLE001
        return False
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return False
    loop.create_task(_safe_backfill(db, uid))
    return True
