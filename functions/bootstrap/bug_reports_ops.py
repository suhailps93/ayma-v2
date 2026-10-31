"""Bug/crash report capture — distinct from the ``feedback`` collection.

``bug_reports/{id}`` — a user reporting something broken about the APP
itself: a crash, a button that doesn't work, lost data, and so on. Written
by Ayma's ``report_bug`` tool (``skills/report_bug.py``) the moment the user
tells her about it in a normal chat turn — text or voice — optionally with
a screenshot attached the same turn.

This is a separate bucket from the unified ``feedback`` paths in this app:

* ``feedback/{id}`` (``feedback_ops.record``, ``source: ayma|thumbs_down``) —
  conversational-conduct feedback about how AYMA herself is handling the
  conversation. Not this.
* ``feedback/{id}`` (``feedback_ops.record_submission``,
  ``source: chat_card|settings_form``) — product bugs/feature requests from
  the in-chat feedback catcher and the Settings form (§15). Ayma never touches
  these rows.
* ``bug_reports/{id}`` (this module) — the older "just tell Ayma directly,
  mid-chat" path (founder request 2026-09-16). Kept as its own top-level
  collection; the user-facing flow is now the ``submit_feedback`` catcher
  (confirm-before-send, into ``feedback``), but this intake is left intact.

A top-level collection written only via the Admin SDK (clients can't write
it directly — see ``firestore.rules``). Writes are best-effort and never
raise, matching ``feedback_ops``.
"""

from __future__ import annotations

import logging

logger = logging.getLogger("ayma.bug_reports")

_MAX_TEXT = 4000


def _clip(s: str | None, n: int = _MAX_TEXT) -> str:
    return (s or "").strip()[:n]


def record(
    db,
    uid: str,
    description: str,
    *,
    image_path: str = "",
) -> str | None:
    """Append one bug-report row. ``image_path`` is the Storage path of a
    screenshot the user attached to the same chat turn, if any — passed
    through as-is, never re-uploaded. Returns the new doc id, or ``None``
    when there's nothing worth recording."""
    if not uid:
        return None
    description = _clip(description)
    if not description:
        return None

    try:
        from firebase_admin import firestore

        doc = db.collection("bug_reports").document()
        doc.set(
            {
                "uid": uid,
                "description": description,
                "image_path": _clip(image_path, 256) or None,
                "status": "new",
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id
    except Exception:  # noqa: BLE001 - capture must never break a request
        logger.exception("bug report record failed for %s", uid)
        return None
