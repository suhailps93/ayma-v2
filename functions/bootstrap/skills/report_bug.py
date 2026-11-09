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

This tool is ALSO the filing path for capability gaps (founder rule,
2026-11-07): when a user asks for something no tool can do, Ayma calls it
with a description starting ``Capability gap:`` and the deterministic
guard in :mod:`capability_gap` takes over — exclusion refusal + one
report per distinct gap per session — writing through this same
``bug_reports_ops`` path into the unified ``feedback`` collection
(kind ``bug``). No new tool, no new collection.
"""

from __future__ import annotations

from typing import Callable

import bug_reports_ops
import capability_gap

from ._base import Skill

DESCRIPTION = (
    "Log a bug / crash / technical problem with the APP ITSELF, as soon as "
    "the user describes one. Feedback on your own conversation handling goes "
    "to `record_feedback`. Also file a capability gap with this tool — "
    "description starting `Capability gap:` — when a user asks for "
    "something no tool you have can do. A bug report IS feedback: it "
    "lands in the same unified feedback list as a `submit_feedback` card, "
    "as kind `bug`."
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
                    "what went wrong, in the user's own words"
                ),
            },
        },
        "required": ["description"],
    },
}


def _bind(
    db, uid: str, *, image_path: str = "", session_id: str = ""
) -> Callable[..., str]:
    def report_bug(description: str) -> str:
        """Log an app bug/crash report; a screenshot attached this same
        turn (``image_path``) is saved alongside it automatically. A
        description starting ``Capability gap:`` is a capability-gap
        report instead — routed through the deterministic guard in
        :mod:`capability_gap` (same unified ``feedback`` collection)."""
        if capability_gap.is_gap_description(description):
            return capability_gap.handle_gap_report(
                db, uid, session_id, description
            )
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
