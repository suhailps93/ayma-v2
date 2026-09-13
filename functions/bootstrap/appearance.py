"""One unified "Appearance" read of the user's photos (§ appearance).

Folds the three former photo skills — the structured ``physical_attributes``
record, the honest ``face_report`` and the honest ``body_report`` — into a
single report with three parts:

* **attributes** — the :mod:`physical_attributes` record + summary. Built by
  calling :func:`physical_attributes.refresh` (``persist_report=True``) so the
  flat Explore mirror and the ``physical-profile`` wiki section stay in step.
* **face** — the :mod:`face_report` shape (overall score, features, strengths,
  recommendations), computed from the best ``usable_for_face`` photo. No usable
  photo → ``{"status": "needs_face_photo"}``.
* **body** — the :mod:`body_report` shape, from the best ``usable_for_body``
  photo. None → ``{"status": "needs_body_photo"}``.

Persists one doc ``users/{uid}/appearance_reports/{id}`` and stamps
``users/{uid}/appearance/current`` with its ``report_id``. The three wiki
sections (``face-analysis`` / ``body-analysis`` / ``physical-profile``) are
written via :mod:`skill_memory` exactly as before, only for the sections that
were actually produced.

Everything here is best-effort on storage: a store failure still returns the
report. A credit-cap hit propagates :class:`token_ledger.TokenCapExceeded`.
"""

from __future__ import annotations

import logging

import body_report
import face_report
import media_embed
import physical_attributes
import skill_memory
import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.appearance")

# users/{uid}/appearance_reports/{auto-id} — one immutable doc per run.
REPORTS_COLLECTION = "appearance_reports"
# users/{uid}/appearance/current — a pointer at the latest run.
COLLECTION = "appearance"
DOC_ID = "current"

# Legacy per-skill report collections, merged (read-only) into the history.
_LEGACY_COLLECTIONS = ("face_reports", "body_reports", "physical_reports")

NEEDS_FACE = {"status": "needs_face_photo"}
NEEDS_BODY = {"status": "needs_body_photo"}

_MAX_PHOTOS = 6


# --- photo gathering ---------------------------------------------------------


def _grid_photos(db, uid: str) -> list[dict]:
    """The user's visible grid photos as
    ``[{"bytes", "mime", "attrs"}]`` in grid order, capped at ``_MAX_PHOTOS``.
    Unreadable photos are skipped."""
    try:
        prof = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        ) or {}
    except Exception:  # noqa: BLE001
        return []
    entries = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    entries.sort(key=lambda p: p.get("order", 0))
    out: list[dict] = []
    for e in entries[:_MAX_PHOTOS]:
        sp = str(e.get("storage_path") or "").strip()  # legacy inline shape
        attrs: dict = {}
        if not sp:
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
            attrs = media.get("attributes") or {}
        if not sp:
            continue
        try:
            data, mime = media_embed.download_bytes(sp)
        except Exception:  # noqa: BLE001
            continue
        if data:
            out.append(
                {"bytes": data, "mime": mime or "image/jpeg", "attrs": attrs}
            )
    return out


def _pick(photos: list[dict], extra: list[tuple[bytes, str]], flag: str):
    """The first grid photo whose shot-type tag ``flag`` is set, else the first
    attached ``extra`` image (user-supplied, single-subject intent), else
    ``None``. Returns ``(bytes, mime)`` or ``None``."""
    for p in photos:
        if (p.get("attrs") or {}).get(flag):
            return p["bytes"], p["mime"]
    if extra:
        return extra[0]
    return None


# --- the run ---------------------------------------------------------------


async def run_appearance(
    db,
    uid: str,
    *,
    extra_images: list[tuple[bytes, str]] | None = None,
    want_face: bool = True,
    want_body: bool = True,
    source: str = "user",
) -> dict | None:
    """Build ``uid``'s unified Appearance report and persist it.

    Returns the report dict
    ``{id, created_at, attributes, face, body, photo_count, model, source}``,
    or ``None`` when the user has no readable photo at all. Propagates
    :class:`token_ledger.TokenCapExceeded`.
    """
    if not uid:
        return None
    extra = list(extra_images or [])
    photos = _grid_photos(db, uid)
    if not photos and not extra:
        _record(db, uid, "skipped", source, "no_photo")
        return None

    # --- attributes: reuse physical_attributes (keeps the mirror + wiki fresh)
    attributes: dict
    try:
        pa_kwargs = {"extra_images": extra} if extra else {}
        pa_doc = await physical_attributes.refresh(
            db, uid, persist_report=True, **pa_kwargs
        )
    except token_ledger.TokenCapExceeded:
        raise
    except Exception:  # noqa: BLE001 - a broken attrs pass shouldn't sink the report
        logger.exception("appearance: physical_attributes.refresh failed for %s", uid)
        pa_doc = None
    if pa_doc:
        pa_fields = pa_doc.get("fields") or {}
        attributes = {
            "record": pa_fields,
            "summary": physical_attributes.summary(pa_fields),
            "report_id": str(pa_doc.get("report_id") or ""),
            "photo_count": int(pa_doc.get("photo_count") or 0),
        }
    else:
        attributes = {"status": "needs_photo"}

    # --- face
    face: dict = dict(NEEDS_FACE)
    if want_face:
        pick = _pick(photos, extra, "usable_for_face")
        if pick is not None:
            report = await face_report.run(pick[0], pick[1], uid=uid)
            if isinstance(report, dict) and report.get("usable", True):
                face = report
                skill_memory.save_face_analysis(db, uid, report)
                skill_memory.promote(db, uid, "face_analysis")

    # --- body
    body: dict = dict(NEEDS_BODY)
    if want_body:
        pick = _pick(photos, extra, "usable_for_body")
        if pick is not None:
            report = await body_report.run(pick[0], pick[1], uid=uid)
            if isinstance(report, dict) and report.get("usable", True):
                body = report
                skill_memory.save_body_analysis(db, uid, report)
                skill_memory.promote(db, uid, "body_analysis")

    photo_count = len(photos) + len(extra)
    doc = {
        "attributes": attributes,
        "face": face,
        "body": body,
        "photo_count": photo_count,
        "model": CONFIG.gemini_model,
        "source": source,
    }

    report_id = _store(db, uid, doc)
    doc["id"] = report_id
    _stamp_current(db, uid, report_id)

    produced = [
        k
        for k, v in (("face", face), ("body", body))
        if not (isinstance(v, dict) and v.get("status"))
    ]
    if not (isinstance(attributes, dict) and attributes.get("status")):
        produced.append("attributes")
    _record(
        db, uid, "ok", source,
        f"produced={'+'.join(produced) or 'none'} photos={photo_count}",
    )
    return doc


def record_background_result(
    db,
    uid: str,
    *,
    face: dict | None = None,
    body: dict | None = None,
    source: str = "auto",
) -> str:
    """Keep ``appearance/current`` in step with a background auto-analysis
    result, WITHOUT re-running :func:`run_appearance` and WITHOUT any new
    Gemini call — every value here is either already-computed (``face``/
    ``body``, the report :func:`auto_analysis.analyse_photo` just merged) or a
    cheap Firestore read (``physical_attributes.current``, the previous
    ``appearance_reports`` doc).

    Only the part(s) actually passed in (``face``, ``body``) get fresh
    content. The other part — the axis this particular photo/run didn't touch
    — reuses the *previous* Appearance report's value for it, so e.g. a
    body-only auto-analysis run never regresses an already-produced face
    section back to :data:`NEEDS_FACE`. Only when there is no previous report
    to reuse from at all does the untouched part fall back to
    ``NEEDS_FACE``/``NEEDS_BODY``.

    Best-effort like the rest of this module: any failure (a bad
    ``physical_attributes.current`` read, a store failure, ...) is logged and
    swallowed — returns ``""`` — never raises. A no-op (returns ``""``
    immediately) when neither ``face`` nor ``body`` was passed, or ``uid`` is
    blank.
    """
    if not uid or (face is None and body is None):
        return ""

    prev: dict = {}
    try:
        prev = get_report(db, uid, "current") or {}
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: previous-report read failed for %s", uid
        )

    try:
        pa_doc = physical_attributes.current(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: physical_attributes.current failed for %s", uid
        )
        pa_doc = None
    if pa_doc:
        pa_fields = pa_doc.get("fields") or {}
        attributes: dict = {
            "record": pa_fields,
            "summary": physical_attributes.summary(pa_fields),
            "report_id": str(pa_doc.get("report_id") or ""),
            "photo_count": int(pa_doc.get("photo_count") or 0),
        }
        photo_count = attributes["photo_count"]
    else:
        attributes = {"status": "needs_photo"}
        photo_count = int(prev.get("photo_count") or 0)

    prev_face = prev.get("face")
    face_val = (
        face
        if isinstance(face, dict)
        else (prev_face if isinstance(prev_face, dict) and prev_face else dict(NEEDS_FACE))
    )
    prev_body = prev.get("body")
    body_val = (
        body
        if isinstance(body, dict)
        else (prev_body if isinstance(prev_body, dict) and prev_body else dict(NEEDS_BODY))
    )

    doc = {
        "attributes": attributes,
        "face": face_val,
        "body": body_val,
        "photo_count": photo_count,
        "model": CONFIG.gemini_model,
        "source": source,
    }
    try:
        report_id = _store(db, uid, doc)
    except Exception:  # noqa: BLE001 - _store already guards this; belt & suspenders
        logger.exception("appearance: background-result store failed for %s", uid)
        return ""
    if report_id:
        _stamp_current(db, uid, report_id)
    return report_id


# --- storage --------------------------------------------------------------


def _store(db, uid: str, doc: dict) -> str:
    try:
        from firebase_admin import firestore

        payload = dict(doc)
        payload["created_at"] = firestore.SERVER_TIMESTAMP
        ref = (
            db.collection("users")
            .document(uid)
            .collection(REPORTS_COLLECTION)
            .add(payload)
        )
        if isinstance(ref, tuple):
            return getattr(ref[1], "id", "") or ""
        return getattr(ref, "id", "") or ""
    except Exception:  # noqa: BLE001 - a store failure shouldn't lose the read
        logger.exception("appearance: report store failed for %s", uid)
        return ""


def _stamp_current(db, uid: str, report_id: str) -> None:
    if not report_id:
        return
    try:
        from firebase_admin import firestore

        db.collection("users").document(uid).collection(COLLECTION).document(
            DOC_ID
        ).set(
            {
                "report_id": report_id,
                "updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001
        logger.exception("appearance: current stamp failed for %s", uid)


def _record(db, uid: str, status: str, source: str, detail: str = "") -> None:
    try:
        import skill_runs

        skill_runs.record(
            db, uid, skill_runs.APPEARANCE,
            status=status, source=source, detail=detail,
        )
    except Exception:  # noqa: BLE001
        logger.exception("appearance: skill-run record failed for %s", uid)


# --- reads --------------------------------------------------------------------


def current(db, uid: str) -> dict | None:
    """The caller's stored ``appearance/current`` pointer doc, or ``None``."""
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection(COLLECTION)
            .document(DOC_ID)
            .get()
        )
    except Exception:  # noqa: BLE001
        return None
    return snap.to_dict() if getattr(snap, "exists", False) else None


def get_report(db, uid: str, report_id: str) -> dict | None:
    """Shape a stored ``appearance_reports`` doc (or, for ``"current"``, the
    latest one) as ``{id, created_at, attributes, face, body, photo_count,
    model, source}``. ``None`` when there is no such report."""
    rid = (report_id or "").strip()
    try:
        col = (
            db.collection("users")
            .document(uid)
            .collection(REPORTS_COLLECTION)
        )
        if rid and rid != "current":
            snap = col.document(rid).get()
            if not getattr(snap, "exists", False):
                return None
            return _shape(snap.id, snap.to_dict() or {})
        ptr = current(db, uid) or {}
        pid = str(ptr.get("report_id") or "").strip()
        if pid:
            snap = col.document(pid).get()
            if getattr(snap, "exists", False):
                return _shape(snap.id, snap.to_dict() or {})
        # Fall back to the newest report doc.
        newest = _newest(col)
        return _shape(newest.id, newest.to_dict() or {}) if newest else None
    except Exception:  # noqa: BLE001
        logger.exception("appearance: get_report failed for %s/%s", uid, rid)
        return None


def _newest(col):
    try:
        from firebase_admin import firestore

        snaps = list(
            col.order_by(
                "created_at", direction=firestore.Query.DESCENDING
            ).limit(1).stream()
        )
        return snaps[0] if snaps else None
    except Exception:  # noqa: BLE001
        snaps = sorted(
            col.stream(),
            key=lambda s: str((s.to_dict() or {}).get("created_at") or ""),
            reverse=True,
        )
        return snaps[0] if snaps else None


def _iso(v):
    return v.isoformat() if hasattr(v, "isoformat") else None


def _shape(rid: str, data: dict) -> dict:
    return {
        "id": rid,
        "created_at": _iso(data.get("created_at")),
        "attributes": data.get("attributes") or {},
        "face": data.get("face") or {},
        "body": data.get("body") or {},
        "photo_count": int(data.get("photo_count") or 0),
        "model": str(data.get("model") or ""),
        "source": str(data.get("source") or ""),
    }


def _section_ok(section) -> bool:
    return not (isinstance(section, dict) and section.get("status"))


def history(db, uid: str, *, limit: int = 20) -> list[dict]:
    """The caller's Appearance runs newest-first, with the legacy per-skill
    report collections merged in as read-only ``legacy: true`` rows so nothing
    from before the merge is lost. Each row:
    ``{id, created_at, has_face, has_body, summary, legacy, kind}``."""
    rows: list[dict] = []

    def _col(name):
        return (
            db.collection("users").document(uid).collection(name)
        )

    try:
        for s in _stream_desc(_col(REPORTS_COLLECTION), limit):
            d = s.to_dict() or {}
            attrs = d.get("attributes") or {}
            summ = ""
            if isinstance(attrs, dict):
                summ = str(attrs.get("summary") or "")
            rows.append(
                {
                    "id": s.id,
                    "created_at": _iso(d.get("created_at")),
                    "has_face": _section_ok(d.get("face")),
                    "has_body": _section_ok(d.get("body")),
                    "summary": summ,
                    "legacy": False,
                    "kind": "appearance",
                }
            )
    except Exception:  # noqa: BLE001
        logger.exception("appearance: history read failed for %s", uid)

    for name in _LEGACY_COLLECTIONS:
        kind = name.replace("_reports", "")
        try:
            for s in _stream_desc(_col(name), limit):
                d = s.to_dict() or {}
                rep = d.get("report") or {}
                if kind in ("face", "body") and not rep.get("usable", True):
                    continue
                if kind == "physical":
                    summ = str(d.get("summary") or "")
                else:
                    verdict = str(rep.get("verdict") or "")
                    score = rep.get("overall_score", 0)
                    summ = (f"{verdict} — {score}/10" if verdict else "").strip(" —")
                rows.append(
                    {
                        "id": s.id,
                        "created_at": _iso(d.get("created_at")),
                        "has_face": kind == "face",
                        "has_body": kind == "body",
                        "summary": summ,
                        "legacy": True,
                        "kind": kind,
                    }
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "appearance: legacy %s history read failed for %s", name, uid
            )

    rows.sort(key=lambda r: r.get("created_at") or "", reverse=True)
    return rows[:limit]


def _stream_desc(col, limit: int):
    try:
        from firebase_admin import firestore

        return list(
            col.order_by(
                "created_at", direction=firestore.Query.DESCENDING
            ).limit(limit).stream()
        )
    except Exception:  # noqa: BLE001 - missing index / empty / fake client
        return sorted(
            col.stream(),
            key=lambda s: str((s.to_dict() or {}).get("created_at") or ""),
            reverse=True,
        )[:limit]
