"""Your Story — the single-document editor over the user's wiki pages.

One scrolling document: every ``users/{uid}/wiki_pages`` the user is allowed to
see (not ``ai_only``, not ``user_hidden``), each rendered as ONE body —
``user_edits`` if the user has overridden it, otherwise ``ai_body`` (skill
pages are compiled from their structured source). ``ai_body`` is never written
here.

Visibility is ``public`` | ``private`` only in the UI. ``ai_only`` survives in
Firestore purely as the resting state of a section the user deleted (kept so
Ayma still carries it and a revert can restore it).

Private spans: an inline ``{{private}} … {{/private}}`` marker inside a body.
Shown dimmed in the private view; stripped entirely from the public view and
from ``public_profile``.

AI-only spans: an inline ``{{ai_only}} … {{/ai_only}}`` marker — the
passage-level equivalent of a page's whole-section ``ai_only`` visibility.
Written by "Delete from profile" (``skills.story_edit.remove_from_profile``):
the passage stays in the body (Ayma still has it, and it's revertible) but is
excluded from both the public view *and* the normal "Story" editor view
(:func:`strip_ai_only_spans`) — only "Ayma's Notes" shows it, rendered in the
app's existing red "removed" tone. A span is one of exactly three kinds —
``public`` / ``private`` / ``ai_only`` — never more than one at a time.

``face-analysis`` / ``body-analysis`` / ``physical-profile`` / ``web-findings``
(:data:`REPORT_LINKED_PAGE_IDS`) each carry a ``report_id`` in their section
dict, pointing at the dedicated report screen for that content (the client
renders a summary card + link there instead of the full body, to avoid
showing the same report twice). ``report_id`` is ``None`` when no report has
been run yet; the key is present only for these four page types — absent
entirely from every other section's dict.

Every Firestore field name lives here — ``schema.py`` is read-only.

Tier-2 sweep monolith split #12:
Split 1,015-line monolith into focused submodules along its section banners:
- story_common: field/collection names, visibility markers, span markers,
  page-order tables, tiny helpers
- story_spans: private / ai_only inline spans
- story_pages: page reads + skill-section markdown compilation
- story_versions: per-section version history
- story_reads: public read API + section provenance
- story_writes: public write API (save/visibility/remove/revert/snapshot)
- story_chat: passage chat turn

This module remains the facade re-exporting all symbols for 100% backward
compatibility.
"""

from __future__ import annotations

import logging
import re
import time

from firebase_admin import firestore

# Dependencies re-exported for callers and test monkeypatch compatibility
import gemini
import report_blocks as rb
import token_ledger
from timefmt import iso_or_none

from story_common import (
    AI_ONLY_CLOSE,
    AI_ONLY_OPEN,
    AUTHOR_AYMA,
    AUTHOR_USER,
    F_AI_BODY,
    F_AI_BODY_UPDATED_AT,
    F_PAGE_TYPE,
    F_PENDING_PROPOSAL,
    F_SUPPRESS_PROPOSAL,
    F_TITLE,
    F_USER_EDITS,
    F_USER_HIDDEN,
    F_USER_UPDATED_AT,
    F_VISIBILITY,
    NOTE_AI_LEARNED,
    PRIVATE_CLOSE,
    PRIVATE_OPEN,
    REPORT_LINKED_PAGE_IDS,
    SKILL_PAGE_IDS,
    SNAPSHOT_DEBOUNCE_SECONDS,
    VIS_AI_ONLY,
    VIS_PRIVATE,
    VIS_PUBLIC,
    WIKI_PAGES,
    _NARRATIVE_ORDER,
    _SKILL_ORDER,
    _SKILL_TITLES,
    _SPAN_RE,
    _label,
    _now_ms,
    _pages_col,
    _section_order,
    _section_title,
    _server_ts,
    _to_epoch,
    humanize,
)
from story_spans import (
    _serialize_spans,
    apply_span_action,
    parse_spans,
    sentence_spans,
    strip_ai_only_spans,
    strip_private_spans,
)
from story_pages import (
    _URL_RE,
    _ai_updated_since_user,
    _all_pages,
    _display_body,
    _editor_pages,
    _effective_body,
    _latest_report,
    _photo_url_safe,
    _report_markdown,
    _skill_report_id,
    _web_findings_markdown,
)
from story_versions import (
    MAX_SECTION_VERSIONS,
    SECTION_VERSIONS,
    _section_history,
    _section_versions_col,
    _snapshot_section,
    get_section_version,
    list_section_versions,
)
from story_reads import (
    _section_dict,
    get_ai_notes,
    get_section_provenance,
    get_story,
)
from story_writes import (
    _require_page,
    maybe_snapshot_section_after_ai,
    remove_section,
    revert_section,
    save_section,
    set_visibility,
)
from story_chat import (
    _CHAT_SCHEMA,
    _CHAT_SYS,
    _chat_contents,
    edit_section,
)

logger = logging.getLogger("ayma.story")

__all__ = [
    "WIKI_PAGES",
    "F_AI_BODY",
    "F_USER_EDITS",
    "F_VISIBILITY",
    "F_USER_HIDDEN",
    "F_USER_UPDATED_AT",
    "F_AI_BODY_UPDATED_AT",
    "F_PAGE_TYPE",
    "F_TITLE",
    "F_SUPPRESS_PROPOSAL",
    "F_PENDING_PROPOSAL",
    "VIS_PUBLIC",
    "VIS_PRIVATE",
    "VIS_AI_ONLY",
    "AUTHOR_USER",
    "AUTHOR_AYMA",
    "SNAPSHOT_DEBOUNCE_SECONDS",
    "NOTE_AI_LEARNED",
    "PRIVATE_OPEN",
    "PRIVATE_CLOSE",
    "AI_ONLY_OPEN",
    "AI_ONLY_CLOSE",
    "_SPAN_RE",
    "SKILL_PAGE_IDS",
    "_SKILL_ORDER",
    "_SKILL_TITLES",
    "REPORT_LINKED_PAGE_IDS",
    "_NARRATIVE_ORDER",
    "_server_ts",
    "_now_ms",
    "humanize",
    "_label",
    "_section_title",
    "_section_order",
    "_pages_col",
    "_to_epoch",
    "parse_spans",
    "_serialize_spans",
    "strip_private_spans",
    "strip_ai_only_spans",
    "sentence_spans",
    "apply_span_action",
    "_effective_body",
    "_editor_pages",
    "_all_pages",
    "_ai_updated_since_user",
    "_display_body",
    "_skill_report_id",
    "_photo_url_safe",
    "_latest_report",
    "_report_markdown",
    "_URL_RE",
    "_web_findings_markdown",
    "SECTION_VERSIONS",
    "MAX_SECTION_VERSIONS",
    "_section_versions_col",
    "_section_history",
    "_snapshot_section",
    "list_section_versions",
    "get_section_version",
    "_section_dict",
    "get_story",
    "get_ai_notes",
    "get_section_provenance",
    "_require_page",
    "save_section",
    "set_visibility",
    "remove_section",
    "revert_section",
    "maybe_snapshot_section_after_ai",
    "_CHAT_SYS",
    "_CHAT_SCHEMA",
    "_chat_contents",
    "edit_section",
    "gemini",
    "rb",
    "token_ledger",
    "firestore",
    "iso_or_none",
    "logger",
]
