"""Appearance report reads, history aggregation, and card hidden photos.

Read paths for the unified Appearance report (§ appearance report v2).
Also manages the shareable report card's hidden-photo list (card-only).

Legacy per-skill report collections (face_reports, body_reports, physical_reports)
are merged read-only into history() until sunset date: 2026-12-01 (post-v2 transition).

Split out of ``appearance.py`` (Tier-2 sweep item #10).
"""

from __future__ import annotations

import logging

import schema
from timefmt import iso_or_none
from appearance_storage import (
    COLLECTION,
    DOC_ID,
    REPORT_DOC_ID,
    REPORTS_COLLECTION,
    _category_status,
    _report_ref,
)

logger = logging.getLogger("ayma.appearance")

# Legacy per-skill report collections, merged (read-only) into the history.
# Sunset: 2026-12-01. After this date, legacy collections will no longer be merged into history.
_LEGACY_COLLECTIONS = ("face_reports", "body_reports", "physical_reports")
_LEGACY_COLLECTIONS_SUNSET = "2026-12-01"

# The profile field (``users/{uid}/profile/main``) holding the Storage paths
# the caller has removed from the shareable Appearance report card. Card-only:
# it never deletes the photo or its analysis — the full report still shows
# every photo. See :func:`report_adapters.appearance_blocks`.
HIDDEN_PHOTOS_FIELD = "report_card_hidden_photos"

_MAX_HIDDEN_PHOTOS = 32
_MAX_PHOTO_ID_LEN = 512


def _section_ok(section) -> bool:
    return not (isinstance(section, dict) and section.get("status"))


def _shape(rid: str, data: dict) -> dict:
    import appearance

    cat_fn = getattr(appearance, "_category_status", _category_status)
    return {
        "id": rid,
        "created_at": iso_or_none(data.get("created_at")),
        "attributes": data.get("attributes") or {},
        "face": data.get("face") or {},
        "body": data.get("body") or {},
        "photo_count": int(data.get("photo_count") or 0),
        "model": str(data.get("model") or ""),
        "source": str(data.get("source") or ""),
        # § appearance report v2 — additive, ignored by any client that
        # doesn't know about them yet.
        "score": data.get("score") or {"value": None, "basis": "none"},
        "finding_history": data.get("finding_history") or {},
        "category_status": data.get("category_status")
        or cat_fn(
            True, True, data.get("face") or {}, data.get("body") or {}
        ),
    }


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
    """Shape the caller's report as ``{id, created_at, attributes, face,
    body, photo_count, model, source, score, finding_history}``. ``None``
    when there is no report yet.

    There is only ever ONE report doc now (:data:`REPORT_DOC_ID`); ``"current"``
    (or any falsy id) resolves to it directly. A concrete other id is honoured
    read-only, purely so an old ``[appearance:<id>]`` chat marker minted before
    this module stopped creating a fresh doc per run doesn't 404 outright —
    it's normally already gone (:func:`_purge_legacy_report_docs`)."""
    import appearance

    shape_fn = getattr(appearance, "_shape", _shape)
    rid = (report_id or "").strip()
    try:
        col = (
            db.collection("users")
            .document(uid)
            .collection(REPORTS_COLLECTION)
        )
        target = rid if rid and rid not in ("current", REPORT_DOC_ID) else REPORT_DOC_ID
        snap = col.document(target).get()
        if not getattr(snap, "exists", False):
            return None
        return shape_fn(snap.id, snap.to_dict() or {})
    except Exception:  # noqa: BLE001
        logger.exception("appearance: get_report failed for %s/%s", uid, rid)
        return None


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


def history(db, uid: str, *, limit: int = 20) -> list[dict]:
    """The caller's current Appearance report (one row, since there is only
    ever one now) plus the legacy per-skill report collections merged in as
    read-only ``legacy: true`` rows so nothing from before the merge is lost.
    Each row: ``{id, created_at, has_face, has_body, summary, legacy, kind}``.
    """
    import appearance

    ref_fn = getattr(appearance, "_report_ref", _report_ref)
    section_ok_fn = getattr(appearance, "_section_ok", _section_ok)
    stream_desc_fn = getattr(appearance, "_stream_desc", _stream_desc)
    legacy_cols = getattr(appearance, "_LEGACY_COLLECTIONS", _LEGACY_COLLECTIONS)

    rows: list[dict] = []

    def _col(name):
        return (
            db.collection("users").document(uid).collection(name)
        )

    try:
        snap = ref_fn(db, uid).get()
        if getattr(snap, "exists", False):
            d = snap.to_dict() or {}
            attrs = d.get("attributes") or {}
            summ = str(attrs.get("summary") or "") if isinstance(attrs, dict) else ""
            rows.append(
                {
                    "id": snap.id,
                    "created_at": iso_or_none(d.get("created_at")),
                    "has_face": section_ok_fn(d.get("face")),
                    "has_body": section_ok_fn(d.get("body")),
                    "summary": summ,
                    "legacy": False,
                    "kind": "appearance",
                }
            )
    except Exception:  # noqa: BLE001
        logger.exception("appearance: history read failed for %s", uid)

    for name in legacy_cols:
        kind = name.replace("_reports", "")
        try:
            for s in stream_desc_fn(_col(name), limit):
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
                        "created_at": iso_or_none(d.get("created_at")),
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


def _pool_from_data(data: dict | None) -> list[str]:
    """The ordered pool of Storage paths that fed the caller's Appearance
    report — the face photo(s) first, then the body photo(s), then the
    Attributes grid — deduped, order preserved. This is exactly the pool the
    report card draws its up-to-four photos from (same order as
    ``AppearanceCardData.fromReport``), and the set a hidden-photo id must
    belong to."""
    out: list[str] = []
    for key in ("face", "body", "attributes"):
        rec = data.get(key) if isinstance(data, dict) else None
        paths = rec.get("source_photos") if isinstance(rec, dict) else None
        for p in paths or []:
            s = str(p or "").strip()
            if s and s not in out:
                out.append(s)
    return out


def analysed_photo_ids(
    db, uid: str, report_id: str = "current", *, data: dict | None = None
) -> list[str]:
    """The caller's analysed-photo pool (see :func:`_pool_from_data`). Reads
    the report itself unless ``data`` (an already-loaded :func:`get_report`
    result) is supplied, so a caller that already has it needn't read twice."""
    if data is None:
        import appearance

        get_report_fn = getattr(appearance, "get_report", get_report)
        data = get_report_fn(db, uid, report_id)
    return _pool_from_data(data) if data else []


def read_card_hidden(db, uid: str) -> list[str]:
    """The raw ``report_card_hidden_photos`` list stored on the caller's
    profile, or ``[]`` (never raises). Not intersected with the live pool —
    callers that need the effective set do that themselves."""
    import appearance

    schema_mod = getattr(appearance, "schema", schema)
    try:
        snap = schema_mod.profile_doc(db, uid).get()
    except Exception:  # noqa: BLE001
        return []
    doc = snap.to_dict() if getattr(snap, "exists", False) else None
    raw = (doc or {}).get(HIDDEN_PHOTOS_FIELD)
    if not isinstance(raw, list):
        return []
    return [str(p).strip() for p in raw if str(p or "").strip()]


def set_card_hidden(db, uid: str, ids) -> list[str]:
    """Persist the caller's choice of analysed photos to keep OFF the
    shareable report card, by Storage path. Validates that every id is one of
    the caller's OWN analysed photos (``ValueError`` otherwise — only your own
    photo ids), dedupes, and writes the cleaned list to the profile doc.
    Returns the stored list. Card-only: it never deletes a photo or its
    analysis."""
    import appearance

    photo_ids_fn = getattr(appearance, "analysed_photo_ids", analysed_photo_ids)
    schema_mod = getattr(appearance, "schema", schema)

    pool = set(photo_ids_fn(db, uid))
    cleaned: list[str] = []
    for i in ids or []:
        s = str(i or "").strip()
        if not s:
            continue
        if len(s) > _MAX_PHOTO_ID_LEN:
            raise ValueError("photo id too long")
        if s not in pool:
            raise ValueError(f"{s!r} is not one of your analysed photos")
        if s not in cleaned:
            cleaned.append(s)
        if len(cleaned) > _MAX_HIDDEN_PHOTOS:
            raise ValueError("too many hidden photos")
    schema_mod.profile_doc(db, uid).set({HIDDEN_PHOTOS_FIELD: cleaned}, merge=True)
    return cleaned
