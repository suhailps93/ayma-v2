"""Shared constants and tiny helpers for the manual-profile-text modules.

Tier-2 sweep monolith split #12: this holds the preamble of the former
``profile_manual.py`` monolith (limits, field names, pin/suppression tuning,
diff kinds, heading/contact regexes, classifier/moderation schemas,
``ProfileTextError``, the ``_prompt`` file loader and ``_norm``) so the
section modules (``profile_manual_text``, ``profile_manual_diff``,
``profile_manual_moderation``, ``profile_manual_save``,
``profile_manual_proposals``) and the ``profile_manual`` facade all share one
copy. Moved verbatim — no behavior change.
"""

from __future__ import annotations

import logging
import re
from datetime import timedelta
from pathlib import Path

logger = logging.getLogger("ayma.profile_manual")


def _mark_avatar_stale(db, uid: str) -> None:
    """Flag the user's standing AI-avatar snapshot stale after a manual
    profile/wiki edit. Cheap (no LLM); the background sweep rebuilds it at most
    once an hour and only if the source actually changed. Best-effort — a stale
    hook must never break a profile write."""
    try:
        import persona_snapshot

        persona_snapshot.mark_persona_stale(db, uid)
    except Exception:  # noqa: BLE001
        logger.debug("persona stale hook failed", exc_info=True)

_PROMPTS = Path(__file__).with_name("prompts")

MAX_TEXT_CHARS = 12000
MAX_TITLE_CHARS = 40
MAX_CUSTOM_SECTIONS = 10
F_CUSTOM = "custom_section"
CUSTOM_PAGE_TYPE = "misc"
_CUSTOM_ID_PREFIX = "custom-"
_MAX_SLUG_CHARS = 40
F_PINNED = "manual_pinned"
F_PROPOSAL = "pending_proposal"

# A pinned sentence is treated as "already on the public text" — so it is NOT
# re-appended as a duplicate — when it is a substring of the public text or a
# near-duplicate of a sentence already there above this ratio. This is what
# stops a reworded fact (the user changed "bachelors of science" to "BTech", or
# "Malayalam, English, and Tamil and Hindi" to "Malayalam and English") from
# being resurrected verbatim and piling up as garbled duplicate text — the
# founder bug 2026-10-28. Reworded restatements of one sentence score ~0.85+;
# genuinely distinct facts score well under 0.6, so 0.7 separates them safely.
_PIN_SIMILAR = 0.7

# A direct user edit (story.save_section / profile_manual._write_section /
# remove_section) stamps user_updated_at and suppresses the NEXT ingest's
# re-proposal of it. A single lagging re-ingest is not always the only one in
# flight after an edit, so suppression stays active for any ingest landing
# within this window of the user's edit — not just the first — so a user edit
# reliably applies in place and never re-surfaces as an Apply/Dismiss card
# while stale passes drain (founder bug 2026-10-28).
_SUPPRESS_WINDOW = timedelta(minutes=10)

KIND_REMOVED = "removed_fact"
KIND_ADDED = "added_fact"
KIND_WORDING = "wording_only"
_KINDS = (KIND_REMOVED, KIND_ADDED, KIND_WORDING)

_HEADING = re.compile(r"^##\s+(.+?)\s*$")
_URL = re.compile(r"(?:https?://|www\.)\S+", re.IGNORECASE)
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
_PHONE = re.compile(r"\+?\d[\d\s().\-]{6,}\d")
_MIN_PHONE_DIGITS = 9

_CLASSIFY_SCHEMA = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "kind": {"type": "string", "enum": list(_KINDS)},
                },
                "required": ["id", "kind"],
            },
        }
    },
    "required": ["items"],
}

_MODERATION_SCHEMA = {
    "type": "object",
    "properties": {"flagged": {"type": "boolean"}, "reason": {"type": "string"}},
    "required": ["flagged", "reason"],
}


class ProfileTextError(ValueError):
    """A manual-edit save that cannot proceed. ``code`` is machine-readable
    (``bad_sections`` / ``bad_title`` / ``too_many_sections`` / ``too_long`` /
    ``contact_info`` / ``moderation`` / ``moderation_unavailable`` /
    ``stale``); ``str(exc)`` is user-facing."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _prompt(name: str) -> str:
    return (_PROMPTS / name).read_text(encoding="utf-8").strip()


def _norm(text: str) -> str:
    return " ".join((text or "").split())
