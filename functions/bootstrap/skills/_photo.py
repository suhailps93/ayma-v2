"""Shared runner for the photo-report skills (sweep finding BE-#2).

``skills/face_report.py`` and ``skills/body_report.py`` were near-identical:
same latest-chat-image lookup (now :func:`skills._base.latest_chat_image`),
same download → ``engine.run`` → credit-cap → usable-check → save →
skill-run-ledger → store → teaser+sentinel flow, differing only in the
engine, the copy, and which collection/constants to use. That flow lives
here, parameterized by :class:`PhotoSkillSpec`; the two skills keep their
own declarations, copy, and bound function names.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Awaitable, Callable

import media_embed
import skill_runs
import token_ledger

from ._base import latest_chat_image


@dataclass(frozen=True)
class PhotoSkillSpec:
    """Everything that differs between the face and body report skills."""

    engine: object  # the engine module (``run`` / ``teaser``)
    no_image: str  # reply when there is no usable chat photo
    out_of_credits_context: str  # token_ledger context for the cap message
    save_analysis: Callable[[object, str, dict], None]  # skill_memory.save_*_analysis
    skill_run_kind: str  # skill_runs.FACE_REPORT | BODY_REPORT
    collection: str  # "face_reports" | "body_reports"
    name: str  # "face_report" | "body_report" (the [name:<id>] sentinel)


async def run_photo_skill(spec: PhotoSkillSpec, db, uid: str) -> str:
    """Run one photo-report skill turn: latest chat image → engine → store →
    teaser + sentinel (or the no-image / capped / unusable reply)."""
    from firebase_admin import firestore

    image_path = latest_chat_image(db, uid)
    if not image_path:
        return spec.no_image
    try:
        image_bytes, mime = media_embed.download_bytes(image_path)
    except Exception:  # noqa: BLE001
        return spec.no_image
    try:
        report = await spec.engine.run(
            image_bytes, mime, uid=uid, source_path=image_path
        )
    except ValueError:
        return spec.no_image
    except token_ledger.TokenCapExceeded:
        return token_ledger.out_of_credits_message(
            spec.out_of_credits_context
        )

    # An unusable read is not a report: no stored doc, no `[<name>:…]`
    # marker (the client must not offer a "View report" button for it).
    if not report.get("usable", True):
        return spec.engine.teaser(report)

    spec.save_analysis(db, uid, report)
    skill_runs.record(
        db, uid, spec.skill_run_kind,
        status=skill_runs.STATUS_OK, source="user", detail="chat",
    )

    doc_id = ""
    try:
        ref = (
            db.collection("users")
            .document(uid)
            .collection(spec.collection)
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

    # A short teaser + the `[<name>:<id>]` sentinel — never the
    # score/verdict/findings dumped inline (§ founder: keep report-result
    # chat messages to a teaser + link, full contents live in the report
    # view only).
    summary = spec.engine.teaser(report)
    if doc_id:
        summary = f"{summary}\n\n[{spec.name}:{doc_id}]"
    return summary


def bind_photo_skill(
    spec: PhotoSkillSpec,
) -> Callable[[object, str], Callable[..., Awaitable[str]]]:
    """A skill ``bind`` closing over ``(db, uid)`` — the inner function keeps
    the skill's own name so bound-callable reprs still read naturally."""

    def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
        async def _run() -> str:
            return await run_photo_skill(spec, db, uid)

        _run.__name__ = spec.name
        return _run

    return _bind
