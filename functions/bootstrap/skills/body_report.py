"""``body_report`` — an honest physique analysis of a body photo the user
shared in this chat (§ body report).

The body-photo counterpart to :mod:`skills.face_report`. Runs only when the
user explicitly asks Ayma to analyse / rate / review a physique in a photo they
have sent. It grabs the most recent chat image, runs the :mod:`body_report`
engine, stores the full report under ``users/{uid}/body_reports/{id}``, and
returns a short summary plus a ``[body_report:<id>]`` sentinel line the client
can detect to open the full in-app report view.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import body_report as engine
import media_embed
import skill_memory
import skill_runs
import token_ledger

from ._base import Skill

DESCRIPTION = (
    "Produce an honest physique analysis of a body photo the user shared in "
    "this chat. Call it only when the user explicitly asks you to analyse / "
    "rate / review a body or physique in a photo they've sent. Not for random "
    "photos."
)

DECLARATION = {
    "name": "body_report",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_IMAGE = "share a clear full-length photo first and I'll take a look"


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
    async def body_report() -> str:
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
                "out of credits — reload on your profile to run a body report"
            )

        # An unusable read is not a report: no stored doc, no `[body_report:…]`
        # marker (the client must not offer a "View report" button for it).
        if not report.get("usable", True):
            return engine.render(report)

        skill_memory.save_body_analysis(db, uid, report)
        skill_runs.record(
            db, uid, skill_runs.BODY_REPORT,
            status=skill_runs.STATUS_OK, source="user", detail="chat",
        )

        doc_id = ""
        try:
            ref = (
                db.collection("users")
                .document(uid)
                .collection("body_reports")
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
            summary = f"{summary}\n\n[body_report:{doc_id}]"
        return summary

    return body_report


SKILL = Skill(declaration=DECLARATION, bind=_bind)
