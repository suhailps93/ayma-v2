"""Direct-message thread + message writes (ARCHITECTURE.md §6.6, §6.7, §6.8,
§6.11 steps 8–10).
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

from dm_schema import (
    DM_MESSAGES_COLLECTION,
    DM_THREADS_COLLECTION,
    MESSAGE_TYPES,
    MESSAGE_VOICE,
    TRANSCRIPT_DONE,
    TRANSCRIPT_EMPTY,
    TRANSCRIPT_ERROR,
    TRANSCRIPT_PENDING,
    thread_id,
)
from matching_schema import block_id

logger = logging.getLogger("ayma.dm")


def blocked_between(db, uid_a: str, uid_b: str) -> bool:
    blocks = db.collection("blocks")
    return (
        blocks.document(block_id(uid_a, uid_b)).get().exists
        or blocks.document(block_id(uid_b, uid_a)).get().exists
    )


def ensure_thread(db, uid_a: str, uid_b: str) -> str:
    tid = thread_id(uid_a, uid_b)
    ref = db.collection(DM_THREADS_COLLECTION).document(tid)
    if not ref.get().exists:
        lo, hi = sorted((uid_a, uid_b))
        ref.set(
            {
                "participants": [lo, hi],
                "created_at": firestore.SERVER_TIMESTAMP,
                "last_message_at": firestore.SERVER_TIMESTAMP,
                "last_read_at": {},
            }
        )
    return tid


def post_message(
    db,
    sender_uid: str,
    thread_with: str,
    msg_type: str,
    body: str,
    attachment: dict | None = None,
    moderation: dict | None = None,
    report_share: dict | None = None,
) -> str:
    """Append a message to the pair's thread. Returns the message id. Raises on
    a bad type or when the pair has a block between them.

    ``attachment`` (for ``image`` / ``file`` messages) adds ``attachment_url``,
    ``attachment_path``, ``mime``, ``file_name`` and ``size`` to the doc; ``body``
    then holds an optional caption.

    ``report_share`` (``shared_report`` messages) is stored as the doc's
    ``report_share`` map: ``{token, title, summary, card_url}``.

    ``moderation`` (a ``{flagged, reason, categories}`` verdict from
    ``dm_moderation.moderate``, text messages only) never blocks the send —
    when ``flagged`` is true it only adds ``moderated: True`` plus
    ``moderation_reason`` / ``moderation_categories`` to the doc so the
    message can be shown flagged. A falsy/absent verdict writes nothing extra.
    """
    if msg_type not in MESSAGE_TYPES:
        raise ValueError(f"bad message type: {msg_type}")
    if blocked_between(db, sender_uid, thread_with):
        raise PermissionError("blocked")

    tid = ensure_thread(db, sender_uid, thread_with)
    thread_ref = db.collection(DM_THREADS_COLLECTION).document(tid)
    msg_ref = thread_ref.collection(DM_MESSAGES_COLLECTION).document()
    doc: dict[str, object] = {
        "sender_uid": sender_uid,
        "type": msg_type,
        "body": body,
        "created_at": firestore.SERVER_TIMESTAMP,
    }
    if msg_type == MESSAGE_VOICE:
        # The message is complete and playable from this write. ``body`` is
        # the canonical Storage path for backwards compatibility;
        # ``audio_path`` names it explicitly for new clients. Transcription
        # starts as ``pending`` and is filled in later by ``dm_ingest`` — it
        # never gates this delivery write.
        doc.update(
            {
                "audio_path": body,
                "transcript": "",
                "transcript_status": TRANSCRIPT_PENDING,
            }
        )
    if attachment:
        doc.update(
            {
                "attachment_url": str(attachment.get("attachment_url", "")),
                "attachment_path": str(attachment.get("attachment_path", "")),
                "mime": str(attachment.get("mime", "")),
                "file_name": str(attachment.get("file_name", "")),
                "size": int(attachment.get("size", 0) or 0),
            }
        )
        if "duration_ms" in attachment:
            doc["duration_ms"] = max(
                0, int(attachment.get("duration_ms", 0) or 0)
            )
    if report_share:
        doc["report_share"] = {
            k: str(report_share.get(k, ""))
            for k in ("token", "title", "summary", "card_url")
        }
    if moderation and moderation.get("flagged"):
        doc.update(
            {
                "moderated": True,
                "moderation_reason": str(moderation.get("reason", "")),
                "moderation_categories": [
                    str(c) for c in (moderation.get("categories") or [])
                ],
            }
        )
    msg_ref.set(doc)
    thread_ref.set(
        {
            "last_message_at": firestore.SERVER_TIMESTAMP,
            # Per-recipient unread counter; the recipient's client resets its
            # own entry to 0 on opening the thread (see firestore.rules).
            "unread": {thread_with: firestore.Increment(1)},
        },
        merge=True,
    )

    # Persistent AI-avatar snapshot: the sender's own sent DMs feed their
    # avatar's texting-style exemplars, so flag their standing snapshot stale.
    # Cheap, no LLM; the background sweep rebuilds it at most once an hour and
    # only if the source content actually changed. Only the SENDER's avatar is
    # affected (never the recipient's — their content isn't in the sender's
    # snapshot). Best-effort: it must never break the send.
    try:
        import persona_snapshot

        persona_snapshot.mark_persona_stale(db, sender_uid)
    except Exception:  # noqa: BLE001 - the stale hook must never break a send
        pass

    return msg_ref.id


def mark_moderated(db, thread_id: str, msg_id: str, moderation: dict) -> None:
    """Apply a moderation verdict to an already-posted message.

    Called from a background task (``main._moderate_dm_message``) *after*
    the send has already returned to the sender — the moderation check never
    blocks or delays delivery. A falsy/unflagged verdict is a no-op; the doc
    is left untouched.
    """
    if not moderation or not moderation.get("flagged"):
        return
    msg_ref = (
        db.collection(DM_THREADS_COLLECTION)
        .document(thread_id)
        .collection(DM_MESSAGES_COLLECTION)
        .document(msg_id)
    )
    msg_ref.set(
        {
            "moderated": True,
            "moderation_reason": str(moderation.get("reason", "")),
            "moderation_categories": [
                str(c) for c in (moderation.get("categories") or [])
            ],
        },
        merge=True,
    )


def attach_transcript(
    db, thread_id: str, msg_id: str, transcript: str, status: str
) -> None:
    """Attach a background transcription result to a delivered voice message.

    This runs after the message has already been delivered. Only terminal
    states may be attached here; ``pending`` is written by ``post_message``
    at delivery time.
    """
    if status not in (TRANSCRIPT_DONE, TRANSCRIPT_EMPTY, TRANSCRIPT_ERROR):
        raise ValueError(f"bad transcript status: {status}")
    msg_ref = (
        db.collection(DM_THREADS_COLLECTION)
        .document(thread_id)
        .collection(DM_MESSAGES_COLLECTION)
        .document(msg_id)
    )
    msg_ref.set(
        {
            "transcript": str(transcript or ""),
            "transcript_status": status,
            "transcript_updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )


def voice_message_audio_path(
    db, thread_id: str, msg_id: str
) -> tuple[str, str] | None:
    """``(sender_uid, audio_path)`` for a voice message, else ``None``.

    Used by the participant-checked playback-url endpoint. The stored path
    must belong to the message sender's own ``uploads/`` tree; anything else
    is treated as not playable rather than resolved.
    """
    snap = (
        db.collection(DM_THREADS_COLLECTION)
        .document(thread_id)
        .collection(DM_MESSAGES_COLLECTION)
        .document(msg_id)
        .get()
    )
    if not getattr(snap, "exists", False):
        return None
    doc = snap.to_dict() or {}
    if doc.get("type") != MESSAGE_VOICE:
        return None
    sender_uid = str(doc.get("sender_uid", "") or "")
    audio_path = str(doc.get("audio_path") or doc.get("body") or "")
    if not sender_uid or not audio_path.startswith(f"uploads/{sender_uid}/"):
        return None
    return sender_uid, audio_path
