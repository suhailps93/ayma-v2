"""``face_report`` — an honest facial-beauty analysis of a photo the user
shared in this chat (§ face report).

Runs only when the user explicitly asks Ayma to analyse / rate / review a face
in a photo they have sent. It grabs the most recent chat image, runs the
:mod:`face_report` engine, stores the full report under
``users/{uid}/face_reports/{id}``, and returns a short summary plus a
``[face_report:<id>]`` sentinel line the client can detect to open the full
in-app report view.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and livekit
``function_tool`` awaits it in voice.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import face_report as engine
import media_embed
import token_ledger

from ._base import Skill

DESCRIPTION = (
    "Produce an honest facial-beauty analysis of a photo the user shared in "
    "this chat. Call it only when the user explicitly asks you to analyse / "
    "rate / review a face in a photo they've sent. Not for random photos."
)

DECLARATION = {
    "name": "face_report",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_IMAGE = "share a clear photo of the face first and I'll take a look"


def _latest_chat_image(db, uid: str) -> str:
    """The ``image_path`` of the most recent ``chat_messages`` doc that has
    one, or ``""``."""
    from firebase_admin import firestore

    try:
        docs = (
            db.collection("users")
            .document(uid)
            .collection("chat_messages")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(30)
            .stream()
        )
    except Exception:  # noqa: BLE001 - a missing index / empty collection
        return ""
    for d in docs:
        path = str((d.to_dict() or {}).get("image_path", "")).strip()
        if path:
            return path
    return ""


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def face_report() -> str:
        from firebase_admin import firestore

        image_path = _latest_chat_image(db, uid)
        if not image_path:
            return _NO_IMAGE
        try:
            image_bytes, mime = media_embed.download_bytes(image_path)
        except Exception:  # noqa: BLE001
            return _NO_IMAGE
        try:
            report = await engine.run(image_bytes, mime, uid=uid)
        except ValueError:
            return _NO_IMAGE
        except token_ledger.TokenCapExceeded:
            return (
                "out of credits — reload on your profile to run a face report"
            )

        doc_id = ""
        try:
            ref = (
                db.collection("users")
                .document(uid)
                .collection("face_reports")
                .add(
                    {
                        "report": report,
                        "image_path": image_path,
                        "created_at": firestore.SERVER_TIMESTAMP,
                    }
                )
            )
            doc_id = getattr(ref[1], "id", "") if isinstance(ref, tuple) else ""
        except Exception:  # noqa: BLE001 - a store failure shouldn't lose the read
            doc_id = ""

        summary = engine.render(report)
        if doc_id:
            summary = f"{summary}\n\n[face_report:{doc_id}]"
        return summary

    return face_report


SKILL = Skill(declaration=DECLARATION, bind=_bind)
