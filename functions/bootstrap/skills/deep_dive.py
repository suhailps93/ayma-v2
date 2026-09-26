"""``deep_dive`` — a consented web lookup on a named person (§ deep dive).

Either the user on themselves ("search me so I don't have to repeat it") or on
someone they're about to meet. Returns a digest for Ayma to walk through with
the user; confirmations flow into the wiki through normal ingest. Never runs
unprompted, never on a third party the user isn't meeting.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and
livekit ``function_tool`` awaits it in voice.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import deep_dive as engine
import skill_memory
import skill_runs
import token_ledger

from ._base import Skill

DESCRIPTION = (
    "Web-research a person (digest + links). ONLY on an explicit ask to look "
    "up the user themselves or someone they're meeting — never unprompted, "
    "never a third party."
)

DECLARATION = {
    "name": "deep_dive",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "full_name": {
                "type": "string",
            },
            "subject": {
                "type": "string",
                "enum": ["self", "other"],
                "description": "'self' when they research themselves",
            },
            "context": {
                "type": "string",
                "description": "optional city/employer disambiguator, or \"\"",
            },
        },
        "required": ["full_name", "subject"],
    },
}


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def deep_dive(
        full_name: str, subject: str = "other", context: str = ""
    ) -> str:
        is_self = subject == "self"
        if is_self:
            # Prefer the profile's real identity and fold in location + the
            # (never-searched) phone note when looking the user up.
            prof_name = engine.profile_full_name(db, uid)
            if prof_name:
                full_name = prof_name
            extra = engine.profile_dive_context(db, uid, full_name)
            if extra:
                context = f"{context} {extra}".strip()
        try:
            digest = await engine.run(
                full_name,
                db=db,
                uid=uid,
                context=context,
                is_self=is_self,
            )
        except ValueError:
            return "give me their full name and I'll look them up"
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(token_ledger.CONTEXT_DEEP_DIVE)
        # Only a self-lookup goes into the user's wiki / Your Story; research on
        # someone they're meeting stays a private chat note (+ the reuse cache).
        if is_self:
            skill_memory.save_web_findings(db, uid, digest)
            skill_runs.record(
                db, uid, skill_runs.DEEP_DIVE,
                status=skill_runs.STATUS_OK, source="user", detail="chat",
            )
        # A short teaser + the `[deep_dive:<id>]` sentinel the client renders
        # as a "View research" card — never the summary/facts/links dumped
        # inline (§ founder: keep report-result chat messages to a teaser +
        # link). `engine.run` already persisted the report when `db`/`uid`
        # were given, under the same id `dive_report_id` computes here.
        summary = engine.teaser(digest)
        if digest.get("confidence") != "not_found" and (
            digest.get("facts") or digest.get("summary")
        ):
            report_id = engine.dive_report_id(name=full_name)
            if report_id:
                summary = f"{summary}\n\n[deep_dive:{report_id}]"
        return summary

    return deep_dive


SKILL = Skill(declaration=DECLARATION, bind=_bind)
