"""Headless face / body report generation (§ face report, § body report).

``POST /face-report`` / ``/body-report`` and the chat ``face_report`` /
``body_report`` skills both need an HTTP request or a chat turn to run. This is
the no-context entry point the skill-run reconciler (:mod:`skill_runs`) uses: it
runs the engine over the user's primary profile photo, stores the
``{kind}_reports`` doc, refreshes the ``private`` skill-memory page and — since
it only ever runs on the account owner — promotes that page into their own
story, exactly like the explicit-ask path in ``main._run_report_endpoint``.

Best-effort on storage: a store failure still returns the report. A credit-cap
hit propagates as :class:`token_ledger.TokenCapExceeded` for the caller.
"""

from __future__ import annotations

import logging

import body_report
import face_report
import media_embed
import schema
import skill_memory

logger = logging.getLogger("ayma.skillreports")

_ENGINES = {"face": face_report, "body": body_report}
_PAGE_TYPE = {"face": "face_analysis", "body": "body_analysis"}
_SAVE = {
    "face": skill_memory.save_face_analysis,
    "body": skill_memory.save_body_analysis,
}


def primary_profile_photo_path(db, uid: str) -> str:
    """The ``storage_path`` of ``uid``'s primary (lowest-order) profile photo,
    or ``""`` when they have none. Mirrors ``main._primary_profile_photo_path``
    without the FastAPI ``get_db`` dependency."""
    try:
        prof = schema.profile_doc(db, uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        return ""
    entries = [
        p for p in (prof.get(schema.PF_PHOTOS) or []) if isinstance(p, dict)
    ]
    entries.sort(key=lambda p: p.get("order", 0))
    for e in entries:
        sp = str(e.get("storage_path") or "").strip()  # legacy inline shape
        if sp:
            return sp
        mid = str(e.get("media_id") or "").strip()
        if not mid:
            continue
        try:
            media = (
                db.collection("users")
                .document(uid)
                .collection("user_media")
                .document(mid)
                .get()
                .to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            continue
        sp = str(media.get("storage_path") or "").strip()
        if sp:
            return sp
    return ""


async def run_report(db, uid: str, kind: str) -> dict | None:
    """Run the ``kind`` (``"face"`` | ``"body"``) report on ``uid``'s primary
    profile photo, headless.

    Returns ``{"report", "report_id", "usable"}``; ``None`` when the user has no
    readable profile photo. Stores the ``{kind}_reports`` doc, upserts the
    ``private`` skill-memory page and promotes it into the user's story on a
    usable read. Propagates :class:`token_ledger.TokenCapExceeded`.
    """
    if kind not in _ENGINES:
        raise ValueError(f"kind must be 'face' or 'body', got {kind!r}")

    path = primary_profile_photo_path(db, uid)
    if not path:
        return None
    try:
        image_bytes, mime = media_embed.download_bytes(path)
    except Exception:  # noqa: BLE001 - an unreadable photo is not an error here
        logger.exception("run_report: unreadable primary photo for %s", uid)
        return None
    if not image_bytes:
        return None

    report = await _ENGINES[kind].run(
        image_bytes, mime, uid=uid, source_path=path
    )
    if not isinstance(report, dict):
        report = {}
    usable = bool(report.get("usable", True))

    _SAVE[kind](db, uid, report)
    if usable:
        skill_memory.promote(db, uid, _PAGE_TYPE[kind])

    report_id = ""
    try:
        from firebase_admin import firestore

        ref = (
            db.collection("users")
            .document(uid)
            .collection(f"{kind}_reports")
            .add(
                {
                    "report": report,
                    "image_path": path,
                    "source": "auto",
                    "created_at": firestore.SERVER_TIMESTAMP,
                }
            )
        )
        if isinstance(ref, tuple):
            report_id = getattr(ref[1], "id", "") or ""
        else:
            report_id = getattr(ref, "id", "") or ""
    except Exception:  # noqa: BLE001 - a store failure shouldn't lose the read
        logger.exception("run_report: %s_reports store failed for %s", kind, uid)

    return {"report": report, "report_id": report_id, "usable": usable}
