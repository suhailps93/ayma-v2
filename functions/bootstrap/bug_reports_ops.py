"""Bug/crash report capture — unified with product feedback.

Every user-facing bug report now lands in the ONE ``feedback`` collection
as a product submission (:func:`feedback_ops.record_submission`,
``kind="bug"``, ``source="chat_card"``) — the same record shape the
in-chat feedback catcher (``submit_feedback`` → the user taps Send on the
draft card) and the Settings "Send feedback" form produce, triaged
together in the Developer → Feedback admin view.

This module used to write a separate ``bug_reports/{id}`` collection
(``description`` / ``image_path`` only, no kind/title/screen/version).
That split is what let Ayma file the same user report into two different
places depending on which tool she happened to pick: ``report_bug``
(always-on, voice included) wrote ``bug_reports`` immediately, while
``submit_feedback`` (text-only) drafted a card into ``feedback``, and
only the ``feedback`` rows showed up in the triage view. The founder
ruled that feedback and bug reports are the same thing (2026-11-08), so
:func:`record` — kept as the single entry point for the ``report_bug``
skill, the capability-gap guard and the self-check auto-filer, whose
call sites are unchanged — now delegates to the unified path.

Historical ``bug_reports`` rows are still handled by account
archival/purge; nothing new writes there. Writes are best-effort and
never raise, matching ``feedback_ops``.
"""

from __future__ import annotations

import logging

logger = logging.getLogger("ayma.bug_reports")


def record(
    db,
    uid: str,
    description: str,
    *,
    image_path: str = "",
) -> str | None:
    """Append one bug report as a unified product-feedback row
    (``feedback``, ``kind="bug"``). ``image_path`` is the Storage path of
    a screenshot the user attached to the same chat turn, if any — it
    becomes the row's single ``screenshot_paths`` entry, exactly as a
    chat card's screenshot does. Returns the new doc id, or ``None``
    when there's nothing worth recording."""
    desc = (description or "").strip()
    if not uid or not desc:
        return None

    try:
        import feedback_ops

        return feedback_ops.record_submission(
            db,
            uid,
            "bug",
            # No separate title: record_submission falls back to the
            # body's first chars, the same fallback a chat card with a
            # cleared title gets.
            "",
            desc,
            source="chat_card",
            screenshot_paths=(
                [image_path.strip()] if (image_path or "").strip() else []
            ),
        )
    except Exception:  # noqa: BLE001 - capture must never break a request
        logger.exception("bug report record failed for %s", uid)
        return None
