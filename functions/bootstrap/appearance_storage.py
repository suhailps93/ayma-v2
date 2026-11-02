"""Appearance report storage, diffing, scoring, and legacy purge.

Storage layer for the unified Appearance report (§ appearance report v2).
ONE persistent doc forever: ``users/{uid}/appearance_reports/current`` — a fixed
id, always overwritten in place, never a fresh auto-id per run.

Split out of ``appearance.py`` (Tier-2 sweep item #10).
"""

from __future__ import annotations

import logging
import time

from config import CONFIG
import physical_attributes

logger = logging.getLogger("ayma.appearance")

# users/{uid}/appearance_reports/current — the ONE persistent doc, forever.
REPORTS_COLLECTION = "appearance_reports"
REPORT_DOC_ID = "current"
# users/{uid}/appearance/current — a pointer, kept only for back-compat reads
# (story._skill_report_id, skill_runs.missing) that just check it exists.
COLLECTION = "appearance"
DOC_ID = "current"

NEEDS_FACE = {"status": "needs_face_photo"}
NEEDS_BODY = {"status": "needs_body_photo"}

# Per-category run outcome, surfaced to the client so the pre-run sheet and the
# report can tell "we ran it" from "you chose to skip it" from "there was no
# eligible photo for it" — and so a skipped/unavailable axis shows an add-photo
# prompt instead of a bogus 0-score section (§ founder: the "1% body" bug).
CAT_RAN = "ran"
CAT_SKIPPED = "skipped"
CAT_NO_ELIGIBLE = "no_eligible_photo"

_MAX_FINDING_HISTORY = 8


def _axis_ran(axis) -> bool:
    """A face/body axis actually produced a real read (not a
    :data:`NEEDS_FACE`/:data:`NEEDS_BODY` ``{"status": ...}`` placeholder)."""
    return isinstance(axis, dict) and not axis.get("status")


def _category_status(
    want_face: bool, want_body: bool, face: dict, body: dict
) -> dict:
    """``{"face": ..., "body": ...}`` outcome per axis — :data:`CAT_SKIPPED`
    when the axis was gated off, :data:`CAT_RAN` when it produced a read, else
    :data:`CAT_NO_ELIGIBLE` (wanted, but nothing eligible fed it)."""

    def one(want: bool, axis) -> str:
        if not want:
            return CAT_SKIPPED
        return CAT_RAN if _axis_ran(axis) else CAT_NO_ELIGIBLE

    return {"face": one(want_face, face), "body": one(want_body, body)}


def _report_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(REPORTS_COLLECTION)
        .document(REPORT_DOC_ID)
    )


def _read_report_doc(db, uid: str) -> dict:
    try:
        snap = _report_ref(db, uid).get()
        return (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001
        return {}


def _finding_fingerprint(value) -> tuple:
    """A cheap "did this actually change" comparison key for one face/body
    report dict — the parts a viewer would notice moving."""
    if not isinstance(value, dict):
        return (repr(value),)
    return (
        value.get("verdict"),
        value.get("overall_score"),
        tuple(value.get("strengths") or ()),
        tuple(value.get("improvements") or ()),
    )


def _push_finding_history(
    history_map: dict, key: str, old_value: dict, *, photo_ids, reason: str, now_ms: int,
) -> None:
    entries = list(history_map.get(key) or [])
    entries.append(
        {
            "value": old_value.get("value", old_value.get("verdict")),
            "source": old_value.get("source", ""),
            "confidence": old_value.get("confidence", ""),
            "photo_ids": list(photo_ids or []),
            "changed_at_ms": now_ms,
            "reason": reason,
        }
    )
    history_map[key] = entries[-_MAX_FINDING_HISTORY:]


def _diff_into_history(prev: dict, attributes: dict, face: dict, body: dict) -> dict:
    """Compare the about-to-be-written sections against the previous stored
    doc and return an updated ``finding_history`` map: one entry appended per
    field/axis whose known value actually changed (a brand-new finding, or a
    reused/unchanged one, adds nothing)."""
    now_ms = int(time.time() * 1000)
    history_map: dict = dict(prev.get("finding_history") or {})

    prev_attrs = prev.get("attributes") or {}
    prev_record = prev_attrs.get("record") if isinstance(prev_attrs, dict) else {}
    new_record = attributes.get("record") if isinstance(attributes, dict) else {}
    if isinstance(prev_record, dict) and isinstance(new_record, dict):
        for field, new_val in new_record.items():
            old_val = prev_record.get(field)
            if not (isinstance(old_val, dict) and isinstance(new_val, dict)):
                continue
            if not physical_attributes._is_known(field, old_val.get("value")):
                continue  # nothing known before -> a first finding, not a change
            if (
                old_val.get("value") == new_val.get("value")
                and old_val.get("source") == new_val.get("source")
            ):
                continue
            reason = (
                "new photo evidence" if new_val.get("source") == "photo"
                else "you updated this"
            )
            _push_finding_history(
                history_map, field, old_val,
                photo_ids=old_val.get("photo_ids"), reason=reason, now_ms=now_ms,
            )

    for key, new_val in (("face", face), ("body", body)):
        old_val = prev.get(key)
        if not (isinstance(old_val, dict) and not old_val.get("status")):
            continue  # nothing known before
        if _finding_fingerprint(old_val) == _finding_fingerprint(new_val):
            continue
        _push_finding_history(
            history_map, key, old_val,
            photo_ids=old_val.get("source_photos"),
            reason="new photo evidence", now_ms=now_ms,
        )
    return history_map


def _compute_score(face: dict, body: dict) -> dict:
    """The ONE evolving appearance score — an average of whichever axis
    score(s) are currently known, recomputed (not appended to) on every
    persist. ``basis`` names which axis/axes fed it."""
    face_score = (
        face.get("overall_score")
        if isinstance(face, dict) and not face.get("status")
        else None
    )
    body_score = (
        body.get("overall_score")
        if isinstance(body, dict) and not body.get("status")
        else None
    )
    scores = [s for s in (face_score, body_score) if isinstance(s, (int, float))]
    if not scores:
        return {"value": None, "basis": "none"}
    basis = "+".join(
        b for b, s in (("face", face_score), ("body", body_score))
        if isinstance(s, (int, float))
    )
    return {"value": round(sum(scores) / len(scores), 1), "basis": basis}


def _purge_legacy_report_docs(db, uid: str) -> None:
    """One-off cleanup for the "one doc per run" bug this module used to
    have: delete any leftover ``appearance_reports`` doc that isn't the fixed
    :data:`REPORT_DOC_ID`, so an old per-run doc never shows up alongside the
    new persistent one. Per the founder's call — wipe stale data rather than
    migrate it. Self-limiting: once purged for a user, the stream is just
    ``[current]`` and this is a cheap no-op. Best-effort."""
    try:
        col = (
            db.collection("users").document(uid).collection(REPORTS_COLLECTION)
        )
        for snap in col.stream():
            if snap.id != REPORT_DOC_ID:
                col.document(snap.id).delete()
    except Exception:  # noqa: BLE001
        logger.exception("appearance: legacy report purge failed for %s", uid)


def _stamp_current(db, uid: str) -> None:
    try:
        from firebase_admin import firestore

        db.collection("users").document(uid).collection(COLLECTION).document(
            DOC_ID
        ).set(
            {
                "report_id": REPORT_DOC_ID,
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


def _persist_report(
    db, uid: str, *, attributes: dict, face: dict, body: dict,
    photo_count: int, source: str, category_status: dict | None = None,
) -> dict:
    """Write the ONE persistent ``appearance_reports/current`` doc, updating
    it in place — never a fresh auto-id doc. Diffs against whatever was there
    before (:func:`_diff_into_history`) and recomputes the single evolving
    ``score``. ``category_status`` (``{"face", "body"}`` -> ran/skipped/
    no_eligible_photo) is persisted as-is when given, else re-derived from the
    face/body values so a correction/clear re-sync — which only touches the
    attributes axis — never drops it. Always returns a usable doc (``id`` empty
    when the store itself failed) — never raises."""
    import appearance  # dynamic facade access for test monkeypatch compatibility

    read_doc_fn = getattr(appearance, "_read_report_doc", _read_report_doc)
    diff_fn = getattr(appearance, "_diff_into_history", _diff_into_history)
    cat_fn = getattr(appearance, "_category_status", _category_status)
    axis_fn = getattr(appearance, "_axis_ran", _axis_ran)
    score_fn = getattr(appearance, "_compute_score", _compute_score)
    stamp_fn = getattr(appearance, "_stamp_current", _stamp_current)
    purge_fn = getattr(appearance, "_purge_legacy_report_docs", _purge_legacy_report_docs)
    ref_fn = getattr(appearance, "_report_ref", _report_ref)

    prev = read_doc_fn(db, uid)
    history_map = diff_fn(prev, attributes, face, body)
    if category_status is None:
        category_status = cat_fn(
            axis_fn(face), axis_fn(body), face, body
        )
    doc = {
        "attributes": attributes,
        "face": face,
        "body": body,
        "photo_count": photo_count,
        "model": CONFIG.gemini_model,
        "source": source,
        "score": score_fn(face, body),
        "finding_history": history_map,
        "category_status": category_status,
    }
    stored = False
    try:
        from firebase_admin import firestore

        payload = dict(doc)
        payload["created_at"] = firestore.SERVER_TIMESTAMP
        ref_fn(db, uid).set(payload)
        stored = True
        stamp_fn(db, uid)
        purge_fn(db, uid)
    except Exception:  # noqa: BLE001 - a store failure shouldn't lose the read
        logger.exception("appearance: report store failed for %s", uid)
    doc["id"] = REPORT_DOC_ID if stored else ""
    return doc
