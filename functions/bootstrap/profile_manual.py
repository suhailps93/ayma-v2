"""Manual editing of the user's public profile text, and the approve-before-
apply flow for Ayma's later updates to it.

The public profile is the set of ``public`` wiki pages (see
:mod:`public_profile`). The manual editor shows them as one plain text — each
section under a ``## Title`` heading — and :func:`save_text` turns an edit of
that text into per-section ``user_edits`` overrides:

* A sentence-level diff (before vs after) is classified by a model call
  (``prompts/profile_diff_classify.md``) into removed facts, added facts and
  wording-only changes.
* Removed facts are never lost: each is kept as an inline ``{{ai_only}}`` span
  in the section body, which is exactly how "Ayma's notes" already holds
  passages removed from the profile (the page's ``ai_body`` memory is not
  touched either). Users cannot delete individual notes.
* Added facts are written into the page's ``manual_pinned`` list (user-stated;
  Ayma must keep them) and appended to ``ai_body`` so Ayma knows them.
* Wording-only changes touch neither.
* The text the user wrote becomes the public text.

A ``## Title`` heading that matches none of the profile's sections becomes a
custom section of the user's own: a ``misc`` wiki page, public, whose
``title`` field carries the user's title (see :func:`_plan_sections`).
Removing it later follows the same removed-content rule as any section.

New text is moderated like any other user-facing text: a length cap, no phone
numbers or email addresses (links are allowed), and a model safety pass
(``prompts/profile_text_moderation.md``).

Later AI updates to a public page's text are never applied silently:
:func:`route_ai_update` (called by ``wiki_ingest``) freezes the current public
text as the page's ``user_edits`` and stores the AI's rewrite as a
``pending_proposal`` on the page. The user then reviews it **one change at a
time**: the sentence diff is split into per-change rows with stable ids
(:func:`list_proposals`), and each added or removed sentence is applied
(:func:`apply_change`) or dismissed (:func:`dismiss_change`) on its own; the
decisions so far are kept in the proposal's ``decided`` map until every change
is resolved, when the proposal is cleared. :func:`apply_proposal` /
:func:`dismiss_proposal` decide the whole section at once (Apply all / Dismiss
all).

Applying a change shows it on the **public** profile; dismissing it never
discards anything. A dismissed addition — and any sentence removed from the
public text — is kept as an inline ``{{ai_only}}`` span and in the page's
``ai_body``, which is exactly how "Ayma's notes" holds material that is off
the public profile: ``story.get_ai_notes`` still shows it and Ayma's
matching/chat read path (``wiki_query.read_wiki_context``) reads every page's
``ai_body`` unfiltered, so Ayma keeps knowing it. Pinned sentences and
``ai_only`` spans are re-attached on every rebuild, so a decision can never
drop them. Everything lives on the ``wiki_pages`` docs, so account deletion
and the knowledge wipe already cover it.

Tier-2 sweep monolith split #12:
Split 1,174-line monolith into focused submodules along its section banners:
- profile_manual_common: limits, field names, diff kinds, regexes, schemas,
  ProfileTextError, prompt loader, normalizer
- profile_manual_text: reading the public text + planning edits
- profile_manual_diff: sentence diffing + model classification
- profile_manual_moderation: contact-info + safety moderation
- profile_manual_save: saving a manual edit
- profile_manual_proposals: Ayma's propose/apply-or-dismiss flow

This module remains the facade re-exporting all symbols for 100% backward
compatibility.
"""

from __future__ import annotations

import asyncio
import difflib
import hashlib
import logging
import re
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Dependencies re-exported for callers and test monkeypatch compatibility
from timefmt import utcnow
import gemini
import report_blocks as rb
import story
import token_ledger
from wiki_schema import page_types

from profile_manual_common import (
    CUSTOM_PAGE_TYPE,
    F_CUSTOM,
    F_PINNED,
    F_PROPOSAL,
    KIND_ADDED,
    KIND_REMOVED,
    KIND_WORDING,
    MAX_CUSTOM_SECTIONS,
    MAX_TEXT_CHARS,
    MAX_TITLE_CHARS,
    ProfileTextError,
    _CLASSIFY_SCHEMA,
    _CUSTOM_ID_PREFIX,
    _EMAIL,
    _HEADING,
    _KINDS,
    _MAX_SLUG_CHARS,
    _MIN_PHONE_DIGITS,
    _MODERATION_SCHEMA,
    _PHONE,
    _PIN_SIMILAR,
    _PROMPTS,
    _SUPPRESS_WINDOW,
    _URL,
    _mark_avatar_stale,
    _norm,
    _prompt,
)
from profile_manual_text import (
    _clean_body,
    _new_page_id,
    _parse_headings,
    _reserved_titles,
    _slug,
    assemble_text,
    custom_pages,
    get_text,
    plan_sections,
    public_sections,
    text_version,
    validate_title,
)
from profile_manual_diff import _blocks, _classify, diff_segments
from profile_manual_moderation import _moderate, check_contact_info
from profile_manual_save import _build_body, _write_section, save_text
from profile_manual_proposals import (
    F_SUGGEST_NOTIFIED,
    _change_items,
    _compose_body,
    _decide_all,
    _decide_one,
    _decided_map,
    _dedupe_changes,
    _edited_within_window,
    _iter_changes,
    _live_matches_decisions,
    _load_proposal,
    _pins_to_append,
    _prune_pins,
    _rebuild_public,
    _similar,
    _title,
    _write_decided,
    apply_change,
    apply_proposal,
    consume_new_suggestions,
    dismiss_change,
    dismiss_proposal,
    list_proposals,
    pending_change_keys,
    preserve,
    route_ai_update,
)

logger = logging.getLogger("ayma.profile_manual")

__all__ = [
    "_mark_avatar_stale",
    "_PROMPTS",
    "MAX_TEXT_CHARS",
    "MAX_TITLE_CHARS",
    "MAX_CUSTOM_SECTIONS",
    "F_CUSTOM",
    "CUSTOM_PAGE_TYPE",
    "_CUSTOM_ID_PREFIX",
    "_MAX_SLUG_CHARS",
    "F_PINNED",
    "F_PROPOSAL",
    "_PIN_SIMILAR",
    "_SUPPRESS_WINDOW",
    "KIND_REMOVED",
    "KIND_ADDED",
    "KIND_WORDING",
    "_KINDS",
    "_HEADING",
    "_URL",
    "_EMAIL",
    "_PHONE",
    "_MIN_PHONE_DIGITS",
    "_CLASSIFY_SCHEMA",
    "_MODERATION_SCHEMA",
    "ProfileTextError",
    "_prompt",
    "_norm",
    "public_sections",
    "assemble_text",
    "text_version",
    "get_text",
    "_parse_headings",
    "_clean_body",
    "_reserved_titles",
    "validate_title",
    "custom_pages",
    "_slug",
    "_new_page_id",
    "plan_sections",
    "_blocks",
    "diff_segments",
    "_classify",
    "check_contact_info",
    "_moderate",
    "_build_body",
    "save_text",
    "_write_section",
    "_similar",
    "_pins_to_append",
    "_prune_pins",
    "preserve",
    "_edited_within_window",
    "route_ai_update",
    "_title",
    "_iter_changes",
    "_change_items",
    "_dedupe_changes",
    "_decided_map",
    "_rebuild_public",
    "_compose_body",
    "_write_decided",
    "_live_matches_decisions",
    "list_proposals",
    "F_SUGGEST_NOTIFIED",
    "pending_change_keys",
    "consume_new_suggestions",
    "_load_proposal",
    "_decide_one",
    "apply_change",
    "dismiss_change",
    "_decide_all",
    "apply_proposal",
    "dismiss_proposal",
    "asyncio",
    "difflib",
    "hashlib",
    "re",
    "unicodedata",
    "datetime",
    "timedelta",
    "timezone",
    "Path",
    "utcnow",
    "gemini",
    "rb",
    "story",
    "token_ledger",
    "page_types",
    "logger",
]
