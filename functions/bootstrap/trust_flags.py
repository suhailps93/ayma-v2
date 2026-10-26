"""Trust flags on ``users/{uid}`` (ARCHITECTURE.md §5.5, §5.10 step 8).

The Lint job (§2.3) catches a user contradicting themselves across
conversations and records it here through :func:`sync_self_contradictions`.
Heavily-flagged users are down-weighted in matching (``matching_skill``),
never excluded.
"""

from __future__ import annotations

from datetime import datetime, timezone

from matching_schema import TRUST_FLAG_SELF_CONTRADICTION


def sync_self_contradictions(db, uid: str, details: list[str]) -> int:
    """Make the user's ``self_contradiction`` flags exactly the contradictions
    the latest lint run found (``details``), keeping other flag types as they
    are. Returns how many self-contradiction flags remain.

    The lint re-reads the whole wiki every night and rewords the same
    contradiction a little differently each time. Appending every run's
    wording piled up near-duplicate flags (one user had nine flags for three
    contradictions), and since matching takes a penalty per flag, the same
    issue was charged again every night until the score hit the penalty cap.
    Mirroring the latest run instead means a flag count reflects the
    contradictions the wiki has now, and a resolved one drops off. A detail
    the previous run already recorded keeps its original ``flagged_at``.
    """
    wanted: list[str] = []
    for d in details:
        d = str(d or "").strip()
        if d and d not in wanted:
            wanted.append(d)
    ref = db.collection("users").document(uid)
    existing = [
        f for f in ((ref.get().to_dict() or {}).get("trust_flags") or [])
        if isinstance(f, dict)
    ]
    previous = {
        f.get("detail"): f for f in existing
        if f.get("type") == TRUST_FLAG_SELF_CONTRADICTION
    }
    kept = [f for f in existing if f.get("type") != TRUST_FLAG_SELF_CONTRADICTION]
    now = datetime.now(timezone.utc)
    current = [
        previous.get(d) or {
            "type": TRUST_FLAG_SELF_CONTRADICTION, "detail": d, "flagged_at": now,
        }
        for d in wanted
    ]
    if [*kept, *current] != existing:
        ref.set({"trust_flags": [*kept, *current]}, merge=True)
    return len(current)
