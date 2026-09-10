"""Re-engagement cron (ARCHITECTURE.md §7.1, §7.9 step 7).

Scheduled job (same Cloud Scheduler pattern as lint / matching). For each user
idle at least ``CONFIG.reengage_inactive_days`` days and past their personal
backoff window, Ayma writes **one** outbound message:

* a **profile share** if the user has a strong unacted-on scored match
  (score ≥ ``CONFIG.reengage_min_match_score`` or already ``mutual_interest``);
* otherwise a **personalised check-in** drawn from the user's wiki — never a
  generic "we miss you".

The message is a real Ayma-authored ``raw_turns`` entry (so it's in the user's
transcript when they return) plus a check-in push (§7.1). After sending, the
backoff gap doubles (7 → 14 → 28 …); it resets once the user is active again.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

import gemini
import token_ledger
from config import CONFIG
from notifications_triggers import notify_checkin
from post_turn import persist_raw_turns
from transcript import ROLE_AYMA, Turn
from wiki_query import read_wiki_context

logger = logging.getLogger("ayma.reengage")

REENGAGE_FIELD = "reengagement"

_CHECKIN_SCHEMA = {
    "type": "object",
    "properties": {"message": {"type": "string"}},
    "required": ["message"],
}

_CHECKIN_SYSTEM = (
    "You are Ayma, a warm matchmaker messaging a user who has been away for a "
    "while. Using the notes below, write ONE short message (1-2 sentences) that "
    "picks up a specific thread from what you know about them — a plan they "
    "mentioned, an interest, something they were weighing. Sound like a friend "
    "checking in, not a marketing email. No greetings like 'Hey there', no "
    "'we miss you', no emoji spam."
)


def _as_utc(dt) -> datetime | None:
    if not isinstance(dt, datetime):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _profile_name(db, uid: str) -> str:
    try:
        snap = db.collection("users").document(uid).collection(
            "profile"
        ).document("main").get()
        name = (snap.to_dict() or {}).get("name", "") if snap.exists else ""
        return name.strip() or "someone"
    except Exception:  # noqa: BLE001
        return "someone"


def _best_unacted_match(db, uid: str):
    """Highest-scoring match this user hasn't responded to yet, if it clears
    the §7.1 bar. Returns ``(other_uid, score, status)`` or ``None``."""
    best = None
    try:
        q = db.collection("matches").where("uids", "array_contains", uid)
        docs = list(q.stream())
    except Exception:  # noqa: BLE001
        logger.exception("reengage match scan failed for %s", uid)
        return None
    for d in docs:
        m = d.to_dict() or {}
        status = m.get("status")
        if status not in ("scored", "mutual_interest"):
            continue
        if uid in (m.get("accepted_by") or []):
            continue
        score = float(m.get("score", 0.0))
        if status != "mutual_interest" and score < CONFIG.reengage_min_match_score:
            continue
        other = next((u for u in (m.get("uids") or []) if u != uid), None)
        if not other:
            continue
        rank = (1 if status == "mutual_interest" else 0, score)
        if best is None or rank > best[0]:
            best = (rank, other, score, status)
    if not best:
        return None
    return best[1], best[2], best[3]


async def _compose_message(db, uid: str):
    """Return ``(text, deep_link)`` for this user's re-engagement message."""
    match = _best_unacted_match(db, uid)
    if match:
        other, score, status = match
        name = _profile_name(db, other)
        if status == "mutual_interest":
            text = (
                f"You and {name} both said yes — that conversation is waiting "
                f"whenever you want to start it."
            )
        else:
            text = (
                f"I found someone I think you'd click with — {name}. Come take "
                f"a look when you have a minute."
            )
        return text, f"profile/{other}"

    _GENERIC = (
        "It's been a little while — whenever you're ready to pick things "
        "back up, I'm here."
    )
    wiki = read_wiki_context(db, uid)
    if not wiki:
        return _GENERIC, "chat"
    try:
        # LLM background work — gated on credits like the rest of the loop.
        # A broke user still gets the generic nudge below, just not a
        # personalised one.
        result = await gemini.generate_json(
            f"What I know about them:\n{wiki}",
            system_prompt=_CHECKIN_SYSTEM,
            response_schema=_CHECKIN_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_REENGAGE,
        )
    except token_ledger.TokenCapExceeded:
        return _GENERIC, "chat"
    text = ""
    if isinstance(result, dict):
        text = str(result.get("message", "")).strip()
    if not text:
        text = (
            "Thinking of you — whenever you want to get back to it, just say "
            "the word."
        )
    return text, "chat"


def _due(user: dict, now: datetime) -> bool:
    last_active = _as_utc(user.get("last_active_at"))
    if last_active is None:
        return False  # never engaged — nothing to re-engage
    if now - last_active < timedelta(days=CONFIG.reengage_inactive_days):
        return False
    re = user.get(REENGAGE_FIELD) or {}
    last_sent = _as_utc(re.get("last_sent_at"))
    if last_sent is not None and last_active <= last_sent:
        # Still away since the last nudge — respect the backoff window.
        next_at = _as_utc(re.get("next_eligible_at"))
        if next_at is not None and now < next_at:
            return False
    return True


def _next_backoff(user: dict, now: datetime) -> int:
    re = user.get(REENGAGE_FIELD) or {}
    last_sent = _as_utc(re.get("last_sent_at"))
    last_active = _as_utc(user.get("last_active_at"))
    prev = int(re.get("backoff_days", 0) or 0)
    came_back = last_sent is not None and last_active is not None and (
        last_active > last_sent
    )
    if prev <= 0 or came_back:
        return CONFIG.reengage_backoff_start_days
    return prev * 2


async def run(
    db, user_limit: int | None = None, *, now: datetime | None = None
) -> dict:
    user_limit = user_limit or CONFIG.reengage_user_limit
    now = now or datetime.now(timezone.utc)
    scanned = sent = 0

    snaps = list(db.collection("users").limit(user_limit).stream())
    for snap in snaps:
        scanned += 1
        uid = snap.id
        user = snap.to_dict() or {}
        if not _due(user, now):
            continue
        try:
            text, deep_link = await _compose_message(db, uid)
            session_id = f"reengage-{now.strftime('%Y%m%d')}"
            persist_raw_turns(db, uid, session_id, [Turn(ROLE_AYMA, text)])
            await notify_checkin(db, uid, text, deep_link=deep_link)
            backoff = _next_backoff(user, now)
            db.collection("users").document(uid).set(
                {
                    REENGAGE_FIELD: {
                        "last_sent_at": firestore.SERVER_TIMESTAMP,
                        "backoff_days": backoff,
                        "next_eligible_at": now + timedelta(days=backoff),
                    }
                },
                merge=True,
            )
            sent += 1
        except Exception:  # noqa: BLE001
            logger.exception("re-engagement failed for %s", uid)

    return {"users_scanned": scanned, "messages_sent": sent}
