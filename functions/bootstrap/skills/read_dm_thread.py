"""``read_dm_thread`` — pull a user's recent DM messages with one of their
matches into the chat, so Ayma can give real feedback on how they're talking to
someone. She does NOT see these by default; this is an explicit, on-request
lookup (§6.6, §6.8).
"""

from __future__ import annotations

from typing import Callable

from pair_key import sorted_pair_key

from ._base import Skill

_MAX_MESSAGES = 30

DESCRIPTION = (
    "Read the user's recent DMs with one of their matches, when they ask you "
    "to weigh in on that conversation. Pass the person's name."
)

DECLARATION = {
    "name": "read_dm_thread",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "person": {
                "type": "string",
                "description": "the match's name, as the user says it",
            }
        },
        "required": ["person"],
    },
}


def _resolve_other_uid(db, uid: str, person: str) -> str | None:
    """Find the match uid whose profile name best matches ``person``, among the
    people this user actually has a DM thread with."""
    want = person.strip().lower()
    if not want:
        return None
    try:
        threads = list(
            db.collection("dm_threads")
            .where("participants", "array_contains", uid)
            .stream()
        )
    except Exception:  # noqa: BLE001
        return None

    best: tuple[int, str] | None = None  # (match strength, uid)
    for t in threads:
        parts = (t.to_dict() or {}).get("participants") or []
        other = next((p for p in parts if p != uid), None)
        if not other:
            continue
        try:
            prof = (
                db.collection("users").document(other)
                .collection("profile").document("main").get().to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            continue
        name = str(prof.get("name") or "").strip().lower()
        first = name.split(" ")[0] if name else ""
        strength = 0
        if name and name == want:
            strength = 3
        elif first and first == want:
            strength = 2
        elif name and (want in name or name in want):
            strength = 1
        if strength and (best is None or strength > best[0]):
            best = (strength, other)
    return best[1] if best else None


def _bind(db, uid: str) -> Callable[..., str]:
    def read_dm_thread(person: str = "") -> str:
        other = _resolve_other_uid(db, uid, person)
        if not other:
            return (
                f"couldn't find a conversation with '{person}' — check the "
                "name, or they may not be a match yet"
            )
        thread_id = sorted_pair_key(uid, other)
        try:
            msgs = list(
                db.collection("dm_threads")
                .document(thread_id)
                .collection("messages")
                .order_by("created_at")
                .stream()
            )
        except Exception:  # noqa: BLE001
            return "couldn't load that conversation right now"
        rows = msgs[-_MAX_MESSAGES:]
        if not rows:
            return f"you haven't messaged {person} yet"

        lines = []
        for m in rows:
            d = m.to_dict() or {}
            who = "You" if d.get("sender_uid") == uid else person
            mtype = str(d.get("type") or "text")
            body = str(d.get("body") or "").strip()
            if mtype == "photo":
                body = "[photo]"
            elif mtype == "voice":
                body = "[voice message]"
            elif mtype == "shared_profile":
                body = "[shared a profile]"
            lines.append(f"{who}: {body}")
        return "Recent messages:\n" + "\n".join(lines)

    return read_dm_thread


SKILL = Skill(declaration=DECLARATION, bind=_bind)
