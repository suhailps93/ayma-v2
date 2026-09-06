"""Durable, user-visible chat transcript — ``users/{uid}/chat_messages/{id}``.

Distinct from ``raw_turns`` (the per-session substrate wiki ingest reads): this
is the continuous thread the Ayma tab renders and paginates, one Firestore doc
per message. Written only by ``POST /chat``; read back by ``GET /chat/history``.
Image messages carry the ``uploads/{uid}/…`` ``image_path`` — the client
resolves it to a download URL the same way it does profile photos.
"""

from __future__ import annotations

from datetime import datetime

from firebase_admin import firestore

_MAX_TEXT = 8000
_MAX_PAGE = 100


def _col(db, uid: str):
    return (
        db.collection("users").document(uid).collection("chat_messages")
    )


def append(
    db,
    uid: str,
    role: str,
    text: str,
    *,
    image_path: str | None = None,
) -> None:
    """Append one message. No-op for an unknown role or an empty text with no
    image. Best-effort — callers wrap it so a write failure never fails /chat."""
    if not uid or role not in ("user", "ayma"):
        return
    text = (text or "").strip()
    if not text and not image_path:
        return
    _col(db, uid).add(
        {
            "role": role,
            "text": text[:_MAX_TEXT],
            "image_path": image_path or "",
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )


def recent(
    db, uid: str, *, before: datetime | None = None, limit: int = 40
) -> dict:
    """Up to ``limit`` messages older than ``before`` (or the latest), returned
    oldest-first, plus ``next_before`` — the ISO cursor for the next older page
    (``None`` when the start of history is reached)."""
    limit = max(1, min(int(limit), _MAX_PAGE))
    query = _col(db, uid).order_by(
        "created_at", direction=firestore.Query.DESCENDING
    )
    if before is not None:
        query = query.where("created_at", "<", before)
    docs = list(query.limit(limit).stream())

    messages = []
    for doc in reversed(docs):
        data = doc.to_dict() or {}
        ts = data.get("created_at")
        messages.append(
            {
                "role": data.get("role", "ayma"),
                "text": data.get("text", ""),
                "image_path": data.get("image_path", ""),
                "created_at": ts.isoformat() if hasattr(ts, "isoformat")
                else None,
            }
        )

    next_before = None
    if len(docs) == limit:
        # Cursor for the next (older) page: the oldest doc in this page that has
        # a usable timestamp. ``docs`` is newest-first, so walk from the tail.
        # Skipping past a missing / not-yet-resolved ``created_at`` keeps a
        # single half-written doc from dead-ending pagination.
        for doc in reversed(docs):
            ts = (doc.to_dict() or {}).get("created_at")
            if hasattr(ts, "isoformat"):
                next_before = ts.isoformat()
                break
    return {"messages": messages, "next_before": next_before}
