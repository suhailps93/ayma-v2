"""Ayma in your DMs — a thread-aware assistant for a DM thread (§6.9).

One surface, two jobs, chosen by whether the thread has any messages yet:

* **opener** (empty thread) — up to four opener chips for the user to send
  first, grounded in that pair's ``matches/{matchId}`` compatibility analysis
  (``ai_explanation`` plus the requesting user's own ``user_explanation``).
  Preserves the former ``icebreakers.py`` behaviour and grounding.
* **coach** (live thread) — up to four suggested next lines the user (``me``)
  could send, grounded in BOTH the compatibility analysis and the recent
  messages, plus one short coaching ``tip``.

There is no separate generation pipeline: everything is derived on demand. If no
compatibility check has ever run for the pair there is no ``matches`` doc and
opener mode yields no chips; coach mode can still work from the messages alone.

Routed through the LLM provider abstraction on the ``dm_coach`` surface, which
defaults to the Meta/Muse brain (``config.llm_provider_dm_coach``). DM assist is
a nicety and must NEVER block the thread: it is exempt from the credit CAP
(``enforce_cap=False``, like the Practice coach) so a zero-credit user still
gets openers/coaching rather than a silently-empty bar, and on any generation
failure it returns the appropriate mode with empty chips and a null tip. The
spend is still metered under the ``icebreakers`` feature key.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import llm_provider
import token_ledger
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.dm")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "dm_coach.md"
_MAX_CHIPS = 4
# Server-side cap on the recent-thread tail the client sends (API contract).
_MAX_MESSAGES = 12

MODE_OPENER = "opener"
MODE_COACH = "coach"

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "chips": {"type": "array", "items": {"type": "string"}},
        "tip": {"type": "string"},
    },
    "required": ["chips"],
}


@lru_cache(maxsize=1)
def _load_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _grounding(db, uid: str, other: str) -> tuple[str, str]:
    """The pair's compatibility grounding: ``(ai_explanation, this user's
    user_explanation)``. Empty strings when there is no ``matches`` doc yet."""
    match_id = sorted_pair_key(uid, other)
    snap = db.collection("matches").document(match_id).get()
    if not snap.exists:
        return "", ""
    data = snap.to_dict() or {}
    ai_expl = str(data.get("ai_explanation", "")).strip()
    mine = str((data.get("user_explanation") or {}).get(uid, "")).strip()
    return ai_expl, mine


def _format_messages(messages: list[dict]) -> str:
    """The recent thread tail as a transcript (oldest first, newest last).
    ``me`` is the user we help; anything else is the match (``Them``)."""
    lines: list[str] = []
    for m in messages[-_MAX_MESSAGES:]:
        if not isinstance(m, dict):
            continue
        text = str(m.get("text", "")).strip()
        if not text:
            continue
        who = "Me" if str(m.get("from", "")).strip().lower() == "me" else "Them"
        lines.append(f"{who}: {text}")
    return "\n".join(lines)


def _clean_chips(result: object) -> list[str]:
    chips = result.get("chips", []) if isinstance(result, dict) else []
    out: list[str] = []
    for c in chips if isinstance(chips, list) else []:
        if isinstance(c, str) and c.strip():
            out.append(c.strip())
    return out[:_MAX_CHIPS]


def _clean_tip(result: object) -> str | None:
    tip = result.get("tip") if isinstance(result, dict) else None
    if isinstance(tip, str) and tip.strip():
        return tip.strip()
    return None


async def assist(
    db, uid: str, other: str, messages: list[dict] | None = None
) -> dict[str, object]:
    """Opener chips (empty thread) or coaching chips + tip (live thread).

    Returns ``{"mode", "chips", "tip"}``. Never raises and never blocks the
    thread: on any generation failure it returns the appropriate mode with no
    chips and a null tip.
    """
    messages = [m for m in (messages or []) if isinstance(m, dict)]
    coach = any(str(m.get("text", "")).strip() for m in messages)
    mode = MODE_COACH if coach else MODE_OPENER

    ai_expl, mine = _grounding(db, uid, other)

    if not coach and not (ai_expl or mine):
        # Opener with nothing to ground on — preserve the old "no chips" result.
        return {"mode": MODE_OPENER, "chips": [], "tip": None}

    if coach:
        contents = (
            "MODE: coach\n\n"
            "COMPATIBILITY ANALYSIS (private, for grounding only — do not quote):\n"
            f"{ai_expl or '(none)'}\n\n"
            "WHAT THIS USER WAS TOLD ABOUT THE MATCH:\n"
            f"{mine or '(none)'}\n\n"
            "RECENT MESSAGES (oldest first, newest last; 'Me' is the user you "
            "are helping):\n"
            f"{_format_messages(messages) or '(none)'}"
        )
    else:
        contents = (
            "MODE: opener\n\n"
            "COMPATIBILITY ANALYSIS (private, for grounding only — do not quote):\n"
            f"{ai_expl or '(none)'}\n\n"
            "WHAT THIS USER WAS TOLD ABOUT THE MATCH:\n"
            f"{mine or '(none)'}"
        )

    try:
        provider = llm_provider.get_llm_provider("dm_coach")
        result = await provider.generate_json(
            contents,
            system_prompt=_load_prompt(),
            response_schema=_RESPONSE_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_ICEBREAKERS,
            # DM assist is a nicety that must NEVER block the thread, so it is
            # exempt from the credit CAP (like the Practice coach, see
            # practice_llm): a zero-credit user still gets openers/coaching
            # instead of a silently-empty bar. The spend is still metered —
            # ``enforce_cap=False`` skips the cap check, not ``record``.
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001 - DM assist is a nicety, never blocks
        logger.exception(
            "dm assist generation failed for %s", sorted_pair_key(uid, other)
        )
        return {"mode": mode, "chips": [], "tip": None}

    tip = _clean_tip(result) if coach else None
    return {"mode": mode, "chips": _clean_chips(result), "tip": tip}
