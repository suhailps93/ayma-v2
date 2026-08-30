"""Session-end persistence of the raw turn window (§1.7 step 8).

One Firestore doc per session at ``users/{uid}/raw_turns/{session_id}``,
upserted with the full interleaved voice+text window. It is written repeatedly
during a session (each ``/chat`` turn, the agent worker's shutdown, an explicit
client ``/post-turn``) but only ever as a single doc — "batch write the full
turn window once per session". Memory extraction into ``wiki_pages`` is Step 21.
"""

from __future__ import annotations

from firebase_admin import firestore

from transcript import Turn


def persist_raw_turns(
    db: firestore.firestore.Client,
    uid: str,
    session_id: str,
    turns: list[Turn],
) -> None:
    """Upsert the session's raw-turn window. No-op for an empty window."""
    if not uid or not session_id or not turns:
        return
    doc = (
        db.collection("users")
        .document(uid)
        .collection("raw_turns")
        .document(session_id)
    )
    payload = {
        "turns": [{"role": t.role, "text": t.text} for t in turns],
        "turn_count": len(turns),
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    doc.set(payload, merge=True)
