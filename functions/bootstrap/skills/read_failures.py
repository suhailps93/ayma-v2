"""``read_recent_failures`` — the analysis-mode-only reader for the
per-user failure log (``failure_log.py``; founder order 2026-11-09).

In analysis mode the user can ask why something failed; this tool is
how Ayma answers from the RECORD instead of improvising: it returns
this user's recorded failures — the exact one-or-two-line error text
captured when the action failed — for her to quote verbatim.

Gating is two-layered, like every scoped tool set in this registry:

* visibility — the text lane only declares/binds it on turns whose
  session is already in analysis mode (``skills.__init__``'s
  ``analysis`` flag / ``analysis_session_id``); the voice lane builds
  its tool list once per call, before the mode can be entered mid-call,
  so there the callable itself is the gate;
* the callable — bound with the session id, it re-checks the gate
  state on EVERY call and returns a plain refusal (never any record)
  unless analysis mode is ACTIVE for this (user, session).

Bound on ``(db, uid)`` from the authenticated session like every other
skill, and the records live under that same uid — a user can only ever
read their OWN failures; there is no parameter that names another user.
"""

from __future__ import annotations

from typing import Callable

import analysis_mode
import failure_log

from ._base import Skill

DECLARATION = {
    "name": "read_recent_failures",
    "description": (
        "ANALYSIS MODE ONLY. Read this user's recorded failure log: the "
        "exact one-or-two-line error recorded when something you tried "
        "failed (a tool error, a provider refusal, a permission error). "
        "Use it when the user asks why something failed, and quote the "
        "recorded error line EXACTLY — never paraphrase it, never add a "
        "cause that is not in the record. Pass a topic naming the thing "
        "that failed (e.g. 'image') to match a specific failure; omit it "
        "for the recent failures overall."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "topic": {
                "type": "string",
                "description": (
                    "optional keyword naming the thing that failed, "
                    "e.g. 'image generation'"
                ),
            },
        },
        "required": [],
    },
}

_REFUSAL = (
    "The failure log can only be read in analysis mode — outside it "
    "those records are not available."
)


def _bind(db, uid: str, *, session_id: str = "") -> Callable[..., str]:
    def read_recent_failures(topic: str = "") -> str:
        if (
            analysis_mode.read_state(db, uid, session_id)["status"]
            != analysis_mode.STATUS_ACTIVE
        ):
            return _REFUSAL
        topic = str(topic or "").strip()
        rows = failure_log.recent_failures(db, uid, limit=10, topic=topic)
        if not rows:
            if topic:
                return f"No failure was recorded for '{topic}'."
            return "No failures have been recorded for this user."
        lines = [
            "Recorded failures for this user, newest first. Quote the "
            "error text EXACTLY as written — one or two lines, no "
            "paraphrase, nothing added:"
        ]
        for row in rows:
            lines.append(f"- {row['action']} · {row['at']}")
            lines.append(row["error"])
        return "\n".join(lines)

    return read_recent_failures


SKILL = Skill(declaration=DECLARATION, bind=_bind)
