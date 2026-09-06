"""Feedback capture — two separate buckets (ARCHITECTURE.md §15, feedback loop).

* ``feedback/{id}`` — **conversational** feedback about how Ayma does her job
  (repeats questions, drifts off the questionnaire, rambles, ignores an answer,
  tone, pacing). Written by Ayma's ``record_feedback`` tool when she notices
  friction, and by the client's one-tap thumbs-down. A weekly job aggregates
  this and proposes additions to ``prompts/lessons.md`` (human-reviewed,
  eval-gated) — the base persona is never rewritten automatically.

* ``product_feedback/{id}`` — **bugs and feature requests**. Ayma never touches
  this bucket. Submitted from the Profile screen with optional screenshots;
  the dev team triages it by hand.

Both are top-level collections written only via the Admin SDK (clients can't
write them — see ``firestore.rules``). Writes are best-effort and never raise.
"""

from __future__ import annotations

import logging

logger = logging.getLogger("ayma.feedback")

# Controlled vocab so the weekly aggregation can bucket cleanly. Anything else
# is coerced to "other".
CATEGORIES = frozenset(
    {
        "repeated_question",
        "off_script",
        "rambling",
        "ignored_answer",
        "too_many_questions",
        "tone",
        "pacing",
        "thumbs_down",
        "other",
    }
)

_VALID_SOURCE = frozenset({"ayma", "user", "thumbs_down"})
_VALID_SEVERITY = frozenset({"low", "medium", "high"})
_VALID_KIND = frozenset({"bug", "idea"})

_MAX_TEXT = 4000


def _clip(s: str | None, n: int = _MAX_TEXT) -> str:
    return (s or "").strip()[:n]


def record(
    db,
    uid: str,
    category: str,
    note: str = "",
    *,
    quote: str = "",
    severity: str = "low",
    source: str = "ayma",
    session_id: str = "",
) -> str | None:
    """Append one conversational-feedback row. Returns the new doc id, or
    ``None`` when there's nothing to record."""
    if not uid:
        return None
    note, quote = _clip(note), _clip(quote)
    if not note and not quote:
        return None

    cat = category if category in CATEGORIES else "other"
    src = source if source in _VALID_SOURCE else "ayma"
    sev = severity if severity in _VALID_SEVERITY else "low"

    try:
        from firebase_admin import firestore

        doc = db.collection("feedback").document()
        doc.set(
            {
                "uid": uid,
                "session_id": _clip(session_id, 128),
                "category": cat,
                "note": note,
                "quote": quote,
                "severity": sev,
                "source": src,
                "status": "new",
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id
    except Exception:  # noqa: BLE001 - capture must never break a request
        logger.exception("feedback record failed for %s", uid)
        return None


def record_product(
    db,
    uid: str,
    kind: str,
    text: str,
    image_paths: list[str] | None = None,
    *,
    app_version: str = "",
) -> str | None:
    """Append one bug / feature-request row. Ayma does not read this bucket."""
    if not uid:
        return None
    text = _clip(text)
    if not text:
        return None

    k = kind if kind in _VALID_KIND else "bug"
    paths = [
        _clip(p, 256)
        for p in (image_paths or [])
        if isinstance(p, str) and p.strip()
    ][:6]

    try:
        from firebase_admin import firestore

        doc = db.collection("product_feedback").document()
        doc.set(
            {
                "uid": uid,
                "kind": k,
                "text": text,
                "image_paths": paths,
                "app_version": _clip(app_version, 64),
                "status": "new",
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id
    except Exception:  # noqa: BLE001
        logger.exception("product feedback record failed for %s", uid)
        return None
