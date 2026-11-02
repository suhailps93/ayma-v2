"""Shared constants and tiny helpers for the Your Story modules.

Tier-2 sweep monolith split #12: this holds the preamble of the former
``story.py`` monolith (Firestore field/collection names, visibility/author
markers, span markers, page-order tables, and the small ``_server_ts`` /
``_now_ms`` / ``humanize`` / ``_label`` / ``_section_title`` /
``_section_order`` / ``_pages_col`` / ``_to_epoch`` helpers) so the section
modules (``story_spans``, ``story_pages``, ``story_versions``,
``story_reads``, ``story_writes``, ``story_chat``) and the ``story`` facade
all share one copy. Moved verbatim — no behavior change.
"""

from __future__ import annotations

import logging
import re
import time

from firebase_admin import firestore

logger = logging.getLogger("ayma.story")

# --- Firestore field / collection names (local, not in schema.py) -----------
WIKI_PAGES = "wiki_pages"

F_AI_BODY = "ai_body"
F_USER_EDITS = "user_edits"
F_VISIBILITY = "visibility"
F_USER_HIDDEN = "user_hidden"
F_USER_UPDATED_AT = "user_updated_at"
F_AI_BODY_UPDATED_AT = "ai_body_updated_at"
F_PAGE_TYPE = "page_type"
F_TITLE = "title"
# A one-shot flag a DIRECT user edit (save_section / remove_section) stamps on
# the page so the very next ingest's ``profile_manual.route_ai_update`` does NOT
# re-propose the user's own change as a pending "Public profile updates"
# Apply/Dismiss card — a user-requested edit applies in place and is done
# (founder bug 2026-10-28). route_ai_update consumes (clears) it. The proposal
# field itself is ``profile_manual.F_PROPOSAL``; its name is mirrored here only
# so a direct edit can clear a now-stale pending card at edit time.
F_SUPPRESS_PROPOSAL = "suppress_next_proposal"
F_PENDING_PROPOSAL = "pending_proposal"

VIS_PUBLIC = "public"
VIS_PRIVATE = "private"
VIS_AI_ONLY = "ai_only"

AUTHOR_USER = "user"
AUTHOR_AYMA = "ayma"

SNAPSHOT_DEBOUNCE_SECONDS = 300

NOTE_AI_LEARNED = "learned from a conversation"

PRIVATE_OPEN = "{{private}}"
PRIVATE_CLOSE = "{{/private}}"
AI_ONLY_OPEN = "{{ai_only}}"
AI_ONLY_CLOSE = "{{/ai_only}}"
_SPAN_RE = re.compile(r"\{\{/?(?:private|ai_only)\}\}")

# Skill pages: compiled from structured data, shown under a divider.
SKILL_PAGE_IDS = ("web-findings", "face-analysis", "body-analysis")
_SKILL_ORDER = {pid: i for i, pid in enumerate(SKILL_PAGE_IDS)}
_SKILL_TITLES = {
    "web-findings": "Web findings",
    "face-analysis": "Facial analysis",
    "body-analysis": "Physique analysis",
}


# The four page types with their own dedicated, already-designed report
# screen — the client renders these as a compact summary card + "View full
# report" link instead of the full inline body (§ Your Story report links).
# ``physical-profile`` isn't in ``SKILL_PAGE_IDS`` (it doesn't sort under the
# "FROM AYMA'S SKILLS" divider — see ``_section_order``) but still gets a
# ``report_id`` here.
REPORT_LINKED_PAGE_IDS = (
    "face-analysis",
    "body-analysis",
    "physical-profile",
    "web-findings",
)

# Narrative section display order; unknown page_types sort after, alpha by title.
_NARRATIVE_ORDER = [
    "identity",
    "background",
    "career",
    "values",
    "personality",
    "goals",
    "relationships",
    "family",
    "dealbreakers",
    "lifestyle",
    "interests",
    "health",
    "misc",
]


def _server_ts():
    return firestore.SERVER_TIMESTAMP


def _now_ms() -> int:
    return int(time.time() * 1000)


def humanize(text: str) -> str:
    """``web_findings`` -> ``Web Findings`` (title case, for section headings)."""
    base = (text or "").replace("_", " ").replace("-", " ").strip()
    return base.title() if base else "Misc"


def _label(text: str) -> str:
    """``hair_styling`` -> ``Hair styling`` (sentence case, for inline labels)."""
    base = (text or "").replace("_", " ").replace("-", " ").strip()
    return base[:1].upper() + base[1:] if base else ""


def _section_title(page_id: str, page_type: str, title: str = "") -> str:
    """A user-titled (custom) section keeps its own ``title``; every other
    section is titled by its page type."""
    if page_id in _SKILL_TITLES:
        return _SKILL_TITLES[page_id]
    return (title or "").strip() or humanize(page_type)


def _section_order(page_id: str, page_type: str) -> int:
    if page_id in _SKILL_ORDER:
        return 300 + _SKILL_ORDER[page_id]
    if page_type in _NARRATIVE_ORDER:
        return 100 + _NARRATIVE_ORDER.index(page_type)
    return 200


def _pages_col(db, uid):
    return db.collection("users").document(uid).collection(WIKI_PAGES)


def _to_epoch(v) -> float:
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    if hasattr(v, "timestamp"):
        try:
            return float(v.timestamp())
        except Exception:  # noqa: BLE001
            return 0.0
    return 0.0
