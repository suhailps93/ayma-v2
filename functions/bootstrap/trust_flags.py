"""Trust flags on ``users/{uid}`` (ARCHITECTURE.md §5.5, §5.10 step 8).

Two sources, no new detection machinery: the Lint job (§2.3) catches a user
contradicting themselves across conversations, and the face-embedding check
(§2.5) catches a new photo that doesn't match the user's established face. Both
call :func:`add_trust_flag`. Heavily-flagged users are down-weighted in
matching (``matching_skill``), never excluded.
"""

from __future__ import annotations

from datetime import datetime, timezone

from matching_schema import TRUST_FLAG_TYPES


def add_trust_flag(db, uid: str, flag_type: str, detail: str) -> bool:
    """Append a ``{type, detail, flagged_at}`` flag unless an identical
    ``(type, detail)`` is already recorded. Returns True if it was added."""
    if flag_type not in TRUST_FLAG_TYPES or not detail.strip():
        return False
    ref = db.collection("users").document(uid)
    existing = (ref.get().to_dict() or {}).get("trust_flags") or []
    if any(
        f.get("type") == flag_type and f.get("detail") == detail.strip()
        for f in existing
        if isinstance(f, dict)
    ):
        return False
    existing.append(
        {
            "type": flag_type,
            "detail": detail.strip(),
            "flagged_at": datetime.now(timezone.utc),
        }
    )
    ref.set({"trust_flags": existing}, merge=True)
    return True
