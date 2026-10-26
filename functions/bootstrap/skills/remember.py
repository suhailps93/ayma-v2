"""``remember`` — Ayma's own trigger to fold the live conversation into her
long-term notes (the wiki, §2.3).

Replaces the old every-turn automatic ingest, which re-read the whole growing
transcript + every wiki page through Gemini after *every* message (§ cost
review 2026-09-07). Now the notes update only:

* when Ayma calls this tool because something worth keeping came up, and
* at session end (``/post_turn`` runs a full pass regardless).

A tool call is rate-limited to once per :data:`_MIN_TURN_GAP` turns — inside
that window the call is acknowledged but deferred to the session-end pass.
"""

from __future__ import annotations

from typing import Callable


from ._base import Skill

# Ayma may trigger a notes update at most once every this many turns.
_MIN_TURN_GAP = 5

DESCRIPTION = (
    "Fold something just learned about this person into your long-term notes "
    "— a value, preference, history, dealbreaker. Skip small talk or anything "
    "already in your notes; one line on what stood out is enough."
)

DECLARATION = {
    "name": "remember",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "highlight": {
                "type": "string",
                "description": "what stood out (optional)",
            }
        },
    },
}


def _bind(
    db,
    uid: str,
    *,
    session_id: str = "",
    turn_index: int = 0,
    turns: list | None = None,
) -> Callable[..., str]:
    async def remember(highlight: str = "") -> str:
        import wiki_ingest
        from transcript import ROLE_AYMA, Turn

        sess = (
            db.collection("users")
            .document(uid)
            .collection("sessions")
            .document(session_id or "_adhoc")
        )
        snap = sess.get()
        last = -(10**6)
        if snap.exists:
            last = int(
                (snap.to_dict() or {}).get("wiki_last_ingest_turn", last)
            )
        if turn_index - last < _MIN_TURN_GAP:
            return "noted — I'll fold that into your story when we wrap up"

        window = list(turns or [])
        if not window and highlight.strip():
            window = [Turn(ROLE_AYMA, f"(worth remembering) {highlight.strip()}")]
        if not window:
            return "nothing to save yet"

        sess.set({"wiki_last_ingest_turn": turn_index}, merge=True)
        written = await wiki_ingest.ingest(db, uid, session_id, window)
        return (
            f"updated your story ({written} section(s))"
            if written
            else "noted"
        )

    return remember


SKILL = Skill(declaration=DECLARATION, bind=_bind)
