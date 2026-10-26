"""Marketing / interview turn caps (ARCHITECTURE.md §3.3, §3.10 step 3).

A pre-signup ``marketing`` session is capped at 10 turns and an ``interview``
(preboarding) session at 40; ``active`` sessions are uncapped. The counter lives
on ``users/{uid}`` as ``marketing_turn_count`` / ``interview_turn_count`` and is
checked + incremented on every ``/chat`` (and reported by ``/bootstrap``) so a
spoofed client can't get around it.

Sequence per capped mode, cap = N:
- turns 1..N: normal, counter climbs to N.
- turn N+1: one nudge/fallback response, counter climbs to N+1.
- turn N+2 and beyond: refused, counter frozen.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


from config import CONFIG

_PROMPTS = Path(__file__).with_name("prompts")

MODE_MARKETING = "marketing"
MODE_INTERVIEW = "interview"
_FIELD = {
    MODE_MARKETING: "marketing_turn_count",
    MODE_INTERVIEW: "interview_turn_count",
}
_CAP = {
    MODE_MARKETING: lambda: CONFIG.cap_marketing_turns,
    MODE_INTERVIEW: lambda: CONFIG.cap_interview_turns,
}


@lru_cache(maxsize=8)
def _canned(name: str) -> str:
    return (_PROMPTS / f"{name}.md").read_text(encoding="utf-8").strip()


@dataclass(frozen=True)
class TurnCapResult:
    allowed: bool  # False -> refuse this turn, do not call the model
    canned_reply: str | None  # a nudge/fallback text to return instead
    fallback_form: bool  # interview cap-out -> client shows the manual form
    mode: str
    count: int  # turns taken (after this call's increment, when it happened)
    cap: int


def evaluate(db, uid: str, mode: str) -> TurnCapResult:
    """Check the cap for ``mode`` and, when a turn is spent, increment the
    counter. Uncapped modes always return ``allowed`` with no side effect."""
    if mode not in _FIELD:
        return TurnCapResult(True, None, False, mode, 0, 0)

    cap = _CAP[mode]()
    field = _FIELD[mode]
    user_ref = db.collection("users").document(uid)
    snap = user_ref.get()
    count = int((snap.to_dict() or {}).get(field, 0)) if snap.exists else 0

    if count < cap:
        user_ref.set({field: count + 1}, merge=True)
        return TurnCapResult(True, None, False, mode, count + 1, cap)

    if count == cap:
        user_ref.set({field: count + 1}, merge=True)
        if mode == MODE_MARKETING:
            return TurnCapResult(
                False, _canned("marketing_nudge"), False, mode, count + 1, cap
            )
        return TurnCapResult(
            False, _canned("interview_capped"), True, mode, count + 1, cap
        )

    # count > cap — hard refuse, counter frozen
    canned = (
        _canned("marketing_capped")
        if mode == MODE_MARKETING
        else _canned("interview_capped")
    )
    return TurnCapResult(
        False, canned, mode == MODE_INTERVIEW, mode, count, cap
    )


def peek(db, uid: str, mode: str) -> dict:
    """Read-only cap state for ``/bootstrap`` — no increment."""
    if mode not in _FIELD:
        return {"mode": mode, "count": 0, "cap": 0, "reached": False}
    cap = _CAP[mode]()
    field = _FIELD[mode]
    snap = db.collection("users").document(uid).get()
    count = int((snap.to_dict() or {}).get(field, 0)) if snap.exists else 0
    return {"mode": mode, "count": count, "cap": cap, "reached": count >= cap}
