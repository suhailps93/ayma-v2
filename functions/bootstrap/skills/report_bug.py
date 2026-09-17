"""``report_bug`` — capture an app crash/bug/problem report, right from a
normal Ayma chat turn (founder request 2026-09-16 — "a tool ... to report
app crashes and bugs with the app").

Distinct from ``record_feedback`` (``skills/record_feedback.py``), which is
only for when AYMA'S OWN conduct in the conversation fell short — this is
for problems with the APP ITSELF: a crash, a broken button, lost chat
history, anything technical going wrong. Ayma calls it as soon as the user
describes such a problem, in their own words, whether typed or spoken. If
they attached a screenshot to the very message reporting the bug, its
Storage path is saved alongside the report automatically (§ ``main.py``
``_prepare_chat``'s ``image_path`` handling, the same attach-a-photo
composer ``edit_photo`` reuses) — no separate upload step, and no argument
for it on the tool itself, since the model never sees or needs to pass a
path.

Always-on: registered in ``skills._REGISTRY`` like ``record_feedback``, so
it's available on every chat surface (main chat, voice, Your Story, etc.)
rather than gated behind a special screen — a crash can happen anywhere.
"""

from __future__ import annotations

from typing import Callable

import bug_reports_ops

from ._base import Skill

DESCRIPTION = (
    "Log a bug / crash / technical-problem report about the APP ITSELF — "
    "'the app crashed', 'this button doesn't work', 'I lost my chat "
    "history', 'X won't load'. Call it as soon as the user describes such a "
    "problem, in their own words. Not for feedback about how YOU (Ayma) are "
    "handling this conversation — use `record_feedback` for that instead."
)

DECLARATION = {
    "name": "report_bug",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "description": {
                "type": "string",
                "description": (
                    "what went wrong, in the user's own words — what "
                    "happened, what they expected instead, and when, as "
                    "much as they've said"
                ),
            },
        },
        "required": ["description"],
    },
}


def _bind(db, uid: str, *, image_path: str = "") -> Callable[..., str]:
    def report_bug(description: str) -> str:
        """Log an app bug/crash report; a screenshot attached this same
        turn (``image_path``) is saved alongside it automatically."""
        rid = bug_reports_ops.record(
            db, uid, description, image_path=image_path,
        )
        if not rid:
            return "couldn't log that — try describing the problem again"
        if image_path:
            return f"logged with your screenshot ({rid})"
        return f"logged ({rid})"

    return report_bug


SKILL = Skill(declaration=DECLARATION, bind=_bind)
