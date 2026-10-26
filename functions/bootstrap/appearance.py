"""One unified, PERSISTENT "Appearance" read of the user's photos
(§ appearance report v2).

Folds the three former photo skills — the structured ``physical_attributes``
record, the honest ``face_report`` and the honest ``body_report`` — into a
single report with three parts:

* **attributes** — the :mod:`physical_attributes` record + summary. Built by
  calling :func:`physical_attributes.refresh` so the flat Explore mirror and
  the ``physical-profile`` wiki section stay in step. Each field carries its
  own ``photo_ids`` (:func:`physical_attributes.merge`) — the photo(s) that
  are the basis for it.
* **face** — the :mod:`face_report` shape (overall score, features, strengths,
  recommendations), computed from the best ``usable_for_face`` photo. No usable
  photo → ``{"status": "needs_face_photo"}``.
* **body** — the :mod:`body_report` shape, from the best ``usable_for_body``
  photo. None → ``{"status": "needs_body_photo"}``.

ONE doc, forever: ``users/{uid}/appearance_reports/current`` — a fixed id,
always overwritten in place, never a fresh auto-id per run (that was the bug:
a 4-photo onboarding burst used to leave 7+ separate history docs behind).
Every run — an explicit ``POST /appearance/report``, a background
auto-analysis result, or the batched add-photos pipeline
(:func:`run_batch_photos`) — reads the previous doc first and:

* keeps whichever axis this run didn't touch (never regresses ``face``/
  ``body``/``attributes`` back to "needs a photo" just because this
  particular run only had evidence for one of them);
* records a per-field/per-axis ``finding_history`` entry whenever a value
  actually changes (the tattoo example: an old "no visible tattoos" finding
  is pushed into history, not silently dropped, when a later photo flips it);
* recomputes the single evolving ``score`` in place.

``users/{uid}/appearance/current`` stays a lightweight pointer
(``{report_id: "current", updated_at}``) purely for back-compat with
:mod:`story` and :mod:`skill_runs`, which only ever check it exists.

Everything here is best-effort on storage: a store failure still returns the
report. A credit-cap hit propagates :class:`token_ledger.TokenCapExceeded`.
"""

from __future__ import annotations

import logging
import time

import body_report
import face_report
import gemini
import media_embed
import physical_attributes
import schema
import skill_memory
import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.appearance")

# users/{uid}/appearance_reports/current — the ONE persistent doc, forever.
REPORTS_COLLECTION = "appearance_reports"
REPORT_DOC_ID = "current"
# users/{uid}/appearance/current — a pointer, kept only for back-compat reads
# (story._skill_report_id, skill_runs.missing) that just check it exists.
COLLECTION = "appearance"
DOC_ID = "current"

# Legacy per-skill report collections, merged (read-only) into the history.
_LEGACY_COLLECTIONS = ("face_reports", "body_reports", "physical_reports")

NEEDS_FACE = {"status": "needs_face_photo"}
NEEDS_BODY = {"status": "needs_body_photo"}

_MAX_PHOTOS = 6
_MAX_FINDING_HISTORY = 8


# --- photo gathering ---------------------------------------------------------


def _grid_photos(db, uid: str) -> list[dict]:
    """The user's visible grid photos as
    ``[{"bytes", "mime", "attrs", "path"}]`` in grid order, capped at
    ``_MAX_PHOTOS``. Unreadable photos are skipped."""
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
    # Public grid photos AND the ones removed from public but kept for
    # analysis (§8.3 — "remove from public" never drops a photo from the
    # appearance pool).
    entries = schema.analysis_photo_entries(prof)
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
                {
                    "bytes": data,
                    "mime": mime or "image/jpeg",
                    "attrs": attrs,
                    "path": sp,
                }
            )
    return out


def _attributes_payload(pa_doc: dict | None) -> dict:
    """Shape a ``physical_attributes/current``-style doc into the
    ``attributes`` section of an Appearance report. ``{"status":
    "needs_photo"}`` when there's no doc at all."""
    if not pa_doc:
        return {"status": "needs_photo"}
    pa_fields = pa_doc.get("fields") or {}
    return {
        "record": pa_fields,
        "summary": physical_attributes.summary(pa_fields),
        "report_id": str(pa_doc.get("report_id") or ""),
        "photo_count": int(pa_doc.get("photo_count") or 0),
        "source_photos": list(pa_doc.get("photo_paths") or []),
    }


def _pick(photos: list[dict], extra: list[tuple[bytes, str, str]], flag: str):
    """The first grid photo whose shot-type tag ``flag`` is set, else the first
    attached ``extra`` image (user-supplied, single-subject intent), else
    ``None``. Returns ``(bytes, mime, storage_path)`` or ``None``."""
    for p in photos:
        if (p.get("attrs") or {}).get(flag):
            return p["bytes"], p["mime"], p.get("path", "")
    if extra:
        return extra[0]
    return None


# --- dedup: skip the Gemini passes when the photo set hasn't moved ----------


def _identified_paths(
    photos: list[dict], extra: list[tuple[bytes, str, str]]
) -> list[str] | None:
    """The storage path of every photo this run would analyse, or ``None``
    when any one of them can't be reliably identified (typically an
    ``extra_images`` / chat-attachment entry with no real storage path) — in
    which case the caller must not attempt the unchanged-photo-set dedup
    below and should just run analysis normally rather than risk a false
    "nothing changed" match."""
    paths: list[str] = []
    for p in photos:
        sp = str(p.get("path") or "").strip()
        if not sp:
            return None
        paths.append(sp)
    for e in extra:
        sp = str(e[2]).strip() if len(e) > 2 and e[2] else ""
        if not sp:
            return None
        paths.append(sp)
    return paths


def _unchanged_since_last_run(db, uid: str, current_paths: list[str] | None) -> dict | None:
    """The persisted ``appearance_reports/current`` doc when ``current_paths``
    (this run's fully-identified photo set) is exactly the set already
    reflected there — ``attributes.source_photos``, which
    :func:`physical_attributes.refresh` always derives from the *whole*
    grid + extra set, so it's the one field that captures everything this run
    would otherwise re-analyse. Set comparison — order doesn't matter, but
    any addition or removal counts as a change. ``None`` (never dedup) when
    ``current_paths`` is ``None``/empty, there's no previous report yet, or
    it has no recorded photo set to compare against."""
    if not current_paths:
        return None
    prev = _read_report_doc(db, uid)
    if not prev:
        return None
    prev_attrs = prev.get("attributes")
    prev_paths = prev_attrs.get("source_photos") if isinstance(prev_attrs, dict) else None
    if not isinstance(prev_paths, list) or not prev_paths:
        return None
    if set(prev_paths) != set(current_paths):
        return None
    return prev


# --- the run ---------------------------------------------------------------


async def run_appearance(
    db,
    uid: str,
    *,
    extra_images: list[tuple[bytes, str, str]] | None = None,
    want_face: bool = True,
    want_body: bool = True,
    source: str = "user",
) -> dict | None:
    """Build ``uid``'s unified Appearance report and persist it.

    ``extra_images`` are ``(bytes, mime, storage_path)`` tuples — chat
    attachments already resolved by the caller; ``storage_path`` is ``""``
    only when the caller genuinely has none to give.

    Returns the report dict
    ``{id, created_at, attributes, face, body, photo_count, model, source}``,
    or ``None`` when the user has no readable photo at all. ``attributes``
    carries a ``source_photos`` list and each of ``face`` / ``body`` (when
    produced) carries its own ``source_photos`` — see
    :func:`physical_attributes.refresh`, :func:`face_report.run` and
    :func:`body_report.run`. Propagates :class:`token_ledger.TokenCapExceeded`.

    Founder's call: "if user rerun the Photo analysis without adding new
    photos just share the last aggregated one" — when every photo this run
    would analyse (grid + ``extra_images``, by storage path) is exactly the
    set already reflected on the persisted report, all three Gemini vision
    passes (:func:`physical_attributes.refresh`, :func:`face_report.run`,
    :func:`body_report.run`) are skipped entirely and the existing persisted
    report is returned unchanged (see :func:`_unchanged_since_last_run`). Any
    addition or removal — or a photo that can't be reliably identified by
    storage path — falls through to a normal run.
    """
    if not uid:
        return None
    extra = list(extra_images or [])
    photos = _grid_photos(db, uid)
    if not photos and not extra:
        _record(db, uid, "skipped", source, "no_photo")
        return None

    current_paths = _identified_paths(photos, extra)
    prev = _unchanged_since_last_run(db, uid, current_paths)
    if prev is not None:
        _record(db, uid, "skipped", source, "unchanged_photos")
        return {
            "id": REPORT_DOC_ID,
            "attributes": prev.get("attributes") or {},
            "face": prev.get("face") or dict(NEEDS_FACE),
            "body": prev.get("body") or dict(NEEDS_BODY),
            "photo_count": int(prev.get("photo_count") or 0),
            "model": str(prev.get("model") or ""),
            "source": prev.get("source") or source,
            "score": prev.get("score") or {"value": None, "basis": "none"},
            "finding_history": prev.get("finding_history") or {},
        }

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
    attributes = _attributes_payload(pa_doc)

    # --- face
    face: dict = dict(NEEDS_FACE)
    if want_face:
        pick = _pick(photos, extra, "usable_for_face")
        if pick is not None:
            report = await face_report.run(
                pick[0], pick[1], uid=uid, source_path=pick[2]
            )
            if isinstance(report, dict) and report.get("usable", True):
                face = report
                skill_memory.save_face_analysis(db, uid, report)
                skill_memory.promote(db, uid, "face_analysis")

    # --- body
    body: dict = dict(NEEDS_BODY)
    if want_body:
        pick = _pick(photos, extra, "usable_for_body")
        if pick is not None:
            report = await body_report.run(
                pick[0], pick[1], uid=uid, source_path=pick[2]
            )
            if isinstance(report, dict) and report.get("usable", True):
                body = report
                skill_memory.save_body_analysis(db, uid, report)
                skill_memory.promote(db, uid, "body_analysis")

    photo_count = len(photos) + len(extra)
    doc = _persist_report(
        db, uid,
        attributes=attributes, face=face, body=body,
        photo_count=photo_count, source=source,
    )

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
    """Keep the ONE persistent report in step with a background auto-analysis
    result, WITHOUT re-running :func:`run_appearance` and WITHOUT any new
    Gemini call — every value here is either already-computed (``face``/
    ``body``, the report :func:`auto_analysis.analyse_photo` just merged) or a
    cheap Firestore read (``physical_attributes.current``, the previous
    persistent report).

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
        prev = _read_report_doc(db, uid)
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
        attributes: dict = _attributes_payload(pa_doc)
        photo_count = attributes["photo_count"]
    else:
        prev_attrs = prev.get("attributes")
        attributes = (
            prev_attrs if isinstance(prev_attrs, dict) and prev_attrs
            else {"status": "needs_photo"}
        )
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

    try:
        doc = _persist_report(
            db, uid,
            attributes=attributes, face=face_val, body=body_val,
            photo_count=photo_count, source=source,
        )
    except Exception:  # noqa: BLE001 - _persist_report already guards this; belt & suspenders
        logger.exception("appearance: background-result store failed for %s", uid)
        return ""
    return str(doc.get("id") or "")


# --- storage: ONE persistent doc, diffed and updated in place --------------


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


def _persist_report(
    db, uid: str, *, attributes: dict, face: dict, body: dict,
    photo_count: int, source: str,
) -> dict:
    """Write the ONE persistent ``appearance_reports/current`` doc, updating
    it in place — never a fresh auto-id doc. Diffs against whatever was there
    before (:func:`_diff_into_history`) and recomputes the single evolving
    ``score``. Always returns a usable doc (``id`` empty when the store itself
    failed) — never raises."""
    prev = _read_report_doc(db, uid)
    history_map = _diff_into_history(prev, attributes, face, body)
    doc = {
        "attributes": attributes,
        "face": face,
        "body": body,
        "photo_count": photo_count,
        "model": CONFIG.gemini_model,
        "source": source,
        "score": _compute_score(face, body),
        "finding_history": history_map,
    }
    stored = False
    try:
        from firebase_admin import firestore

        payload = dict(doc)
        payload["created_at"] = firestore.SERVER_TIMESTAMP
        _report_ref(db, uid).set(payload)
        stored = True
        _stamp_current(db, uid)
        _purge_legacy_report_docs(db, uid)
    except Exception:  # noqa: BLE001 - a store failure shouldn't lose the read
        logger.exception("appearance: report store failed for %s", uid)
    doc["id"] = REPORT_DOC_ID if stored else ""
    return doc


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
    """Shape the caller's report as ``{id, created_at, attributes, face,
    body, photo_count, model, source, score, finding_history}``. ``None``
    when there is no report yet.

    There is only ever ONE report doc now (:data:`REPORT_DOC_ID`); ``"current"``
    (or any falsy id) resolves to it directly. A concrete other id is honoured
    read-only, purely so an old ``[appearance:<id>]`` chat marker minted before
    this module stopped creating a fresh doc per run doesn't 404 outright —
    it's normally already gone (:func:`_purge_legacy_report_docs`)."""
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
        return _shape(snap.id, snap.to_dict() or {})
    except Exception:  # noqa: BLE001
        logger.exception("appearance: get_report failed for %s/%s", uid, rid)
        return None


# --- shareable report card: hidden photos (card-only) --------------------

# The profile field (``users/{uid}/profile/main``) holding the Storage paths
# the caller has removed from the shareable Appearance report card. Card-only:
# it never deletes the photo or its analysis — the full report still shows
# every photo. See :func:`report_adapters.appearance_blocks`.
HIDDEN_PHOTOS_FIELD = "report_card_hidden_photos"

_MAX_HIDDEN_PHOTOS = 32
_MAX_PHOTO_ID_LEN = 512


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
        data = get_report(db, uid, report_id)
    return _pool_from_data(data) if data else []


def read_card_hidden(db, uid: str) -> list[str]:
    """The raw ``report_card_hidden_photos`` list stored on the caller's
    profile, or ``[]`` (never raises). Not intersected with the live pool —
    callers that need the effective set do that themselves."""
    try:
        snap = schema.profile_doc(db, uid).get()
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
    pool = set(analysed_photo_ids(db, uid))
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
    schema.profile_doc(db, uid).set({HIDDEN_PHOTOS_FIELD: cleaned}, merge=True)
    return cleaned


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
        # § appearance report v2 — additive, ignored by any client that
        # doesn't know about them yet.
        "score": data.get("score") or {"value": None, "basis": "none"},
        "finding_history": data.get("finding_history") or {},
    }


def _section_ok(section) -> bool:
    return not (isinstance(section, dict) and section.get("status"))


def history(db, uid: str, *, limit: int = 20) -> list[dict]:
    """The caller's current Appearance report (one row, since there is only
    ever one now) plus the legacy per-skill report collections merged in as
    read-only ``legacy: true`` rows so nothing from before the merge is lost.
    Each row: ``{id, created_at, has_face, has_body, summary, legacy, kind}``.
    """
    rows: list[dict] = []

    def _col(name):
        return (
            db.collection("users").document(uid).collection(name)
        )

    try:
        snap = _report_ref(db, uid).get()
        if getattr(snap, "exists", False):
            d = snap.to_dict() or {}
            attrs = d.get("attributes") or {}
            summ = str(attrs.get("summary") or "") if isinstance(attrs, dict) else ""
            rows.append(
                {
                    "id": snap.id,
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


# --- batching: "add photos" flows (§ appearance batching) -------------------


async def run_batch_photos(
    db,
    uid: str,
    new_photos: list[tuple[str, list[float] | None, dict | None]],
    *,
    source: str = "add_photos",
) -> None:
    """The one pipeline every "add photo(s) to the grid" call site should use
    instead of triggering per-photo analysis directly — a single photo add is
    just a batch of one.

    ``new_photos`` — ``[(storage_path, embedding, attributes), ...]`` — are
    the photos actually added together in ONE action, already resolved by the
    caller from their ``user_media`` docs (this module stays decoupled from
    that schema). Each is run through
    :func:`auto_analysis.analyse_photo` UNCHANGED — the exact same
    group-shot / face-match-to-reference / usable-flag gating and face/body
    engine calls as any other auto-analysis photo, merging into the ONE
    persistent report (:func:`record_background_result`, which it already
    calls). Then, once — never once per photo — the structured attributes
    record is re-derived over the caller's FULL current photo set
    (:func:`physical_attributes.refresh` always reads the whole grid, so this
    naturally has every other current photo as context too, not just the new
    ones, satisfying the "resolve contradictions against the full set" ask).

    Best-effort: one photo's analysis failing never stops the rest or the
    attributes refresh; never raises. A no-op pass over ``new_photos`` (still
    runs the attributes refresh) when it's empty — harmless to call after a
    remove/reorder if a caller wants the record re-derived too."""
    import auto_analysis

    seen: set[str] = set()
    for storage_path, embedding, attrs in new_photos:
        sp = (storage_path or "").strip()
        if not sp or sp in seen:
            continue
        seen.add(sp)
        try:
            await auto_analysis.analyse_photo(
                db, uid, sp, embedding=embedding, attributes=attrs,
            )
        except Exception:  # noqa: BLE001 - one bad photo must not sink the batch
            logger.exception(
                "appearance: batch analyse_photo failed for %s/%s", uid, sp
            )

    try:
        await physical_attributes.refresh(db, uid)
    except Exception:  # noqa: BLE001 - refresh() already guards TokenCapExceeded etc.
        logger.exception("appearance: batch attributes refresh failed for %s", uid)


# --- corrections: free-text, mirrors story.edit_section's pattern ----------

_CORRECTION_SYS = (
    "You are Ayma, correcting ONE finding in a user's photo-based appearance "
    "report because they told you, in their own words, that it's wrong. You "
    "are given the finding's current value and whatever photo(s) of them are "
    "on file as its evidence (there may be none). Trust the user's own "
    "statement about their own body/appearance the way you'd trust any other "
    "self-report, UNLESS the photos directly and clearly contradict it — in "
    "that case say so honestly in `reply` rather than silently complying. "
    "Reply with one short, warm acknowledgement sentence, and the corrected "
    "value."
)
_CORRECTION_SCHEMA = {
    "type": "object",
    "properties": {
        "reply": {"type": "string"},
        # An attribute finding: coerced against the field's own enum/type
        # afterward — never trusted verbatim. A face/body finding: folded
        # into that axis's verdict_note as-is.
        "value": {"type": "string"},
    },
    "required": ["reply", "value"],
}


async def correct_finding(db, uid: str, finding_id: str, message: str) -> dict:
    """Free-text correction for one finding in the caller's Appearance report
    (§ appearance corrections) — mirrors :func:`story.edit_section`'s
    passage-chat pattern (one Gemini call, the user's own words plus the
    actual evidence), but for one structured finding instead of narrative
    prose, and committed immediately: a factual correction doesn't need
    Story's separate propose-then-save step.

    ``finding_id`` is either a :func:`physical_attributes.fields` name (an
    attribute finding) or ``"face"`` / ``"body"``.

    * **attribute** — the corrected value is validated against the exact
      schema ``POST /physical-attributes/correct`` enforces
      (:func:`physical_attributes._coerce` / ``_is_known``) and written to
      ``profile/main`` — becoming a ``stated`` value, the same
      highest-precedence path any other self-report takes
      (:func:`physical_attributes.merge`) — so it survives a later
      photo-based refresh instead of being silently overwritten back. The
      persistent report is then re-synced so the change shows immediately,
      going through the normal diff (:func:`_diff_into_history`), so the
      superseded value lands in ``finding_history`` like any other change.
    * **face** / **body** — there's no ``stated`` slot for these; the
      correction is folded into that axis's ``verdict_note`` and the prior
      finding is pushed into ``finding_history``. Known gap: unlike an
      attribute correction, nothing stops a LATER auto-analysis run over a
      new photo from overwriting this again — there's no "stated" precedence
      mechanism for face/body the way there is for attributes.

    Returns ``{ok, reply, finding_id, value}``, or ``{ok: False, reply,
    finding_id}`` when the model's proposed value didn't validate (nothing is
    written), or ``{usage_capped: True}``. Raises ``KeyError`` when
    ``finding_id`` isn't a real field/axis, or there's no report yet;
    ``ValueError`` when ``message`` is blank."""
    text = (message or "").strip()
    if not text:
        raise ValueError("message is required")

    report = _read_report_doc(db, uid)
    if not report:
        raise KeyError("no appearance report yet")

    is_attribute = finding_id in physical_attributes.fields()
    if not is_attribute and finding_id not in ("face", "body"):
        raise KeyError(finding_id)

    if is_attribute:
        current_val = (
            (report.get("attributes") or {}).get("record") or {}
        ).get(finding_id) or {}
        photo_ids = list(current_val.get("photo_ids") or [])
    else:
        current_val = report.get(finding_id) or {}
        photo_ids = list(current_val.get("source_photos") or [])
    if not photo_ids:
        photo_ids = list((report.get("attributes") or {}).get("source_photos") or [])

    images: list[tuple[bytes, str]] = []
    for p in photo_ids[:4]:
        try:
            data, mime = media_embed.download_bytes(p)
        except Exception:  # noqa: BLE001 - a bad/missing photo just isn't shown
            continue
        if data:
            images.append((data, mime or "image/jpeg"))

    enum_hint = ""
    if is_attribute:
        allowed = physical_attributes._enum_values().get(finding_id)
        if allowed:
            opts = ", ".join(v for v in allowed if v != "unknown")
            enum_hint = f" Allowed values for this field: {opts}."

    contents = (
        f"Finding: {finding_id}\n"
        f"Current value: {current_val.get('value', current_val.get('verdict'))!r}\n"
        f"User's feedback: {text}\n"
        f"{enum_hint}"
    )
    try:
        result = await gemini.generate_json(
            contents,
            system_prompt=_CORRECTION_SYS,
            response_schema=_CORRECTION_SCHEMA,
            images=images or None,
            uid=uid,
            feature=token_ledger.FEATURE_PHYSICAL_ATTRS,
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    result = result if isinstance(result, dict) else {}
    reply = str(result.get("reply") or "Got it — updated.").strip()
    raw_value = result.get("value")

    if is_attribute:
        coerced = physical_attributes._coerce(finding_id, raw_value)
        if not physical_attributes._is_known(finding_id, coerced):
            return {"ok": False, "reply": reply, "finding_id": finding_id}
        try:
            db.collection("users").document(uid).collection(
                "profile"
            ).document("main").set({finding_id: coerced}, merge=True)
        except Exception:  # noqa: BLE001
            logger.exception(
                "appearance: correction write failed for %s/%s", uid, finding_id
            )
            return {"ok": False, "reply": reply, "finding_id": finding_id}
        try:
            pa_doc = await physical_attributes.refresh(db, uid)
        except token_ledger.TokenCapExceeded:
            pa_doc = None
        except Exception:  # noqa: BLE001
            logger.exception(
                "appearance: correction refresh failed for %s/%s", uid, finding_id
            )
            pa_doc = None
        attributes = _attributes_payload(pa_doc) if pa_doc else (
            report.get("attributes") or {"status": "needs_photo"}
        )
        _persist_report(
            db, uid,
            attributes=attributes,
            face=report.get("face") or dict(NEEDS_FACE),
            body=report.get("body") or dict(NEEDS_BODY),
            photo_count=int((pa_doc or {}).get("photo_count") or report.get("photo_count") or 0),
            source="correction",
        )
        return {"ok": True, "reply": reply, "finding_id": finding_id, "value": coerced}

    # face / body: no "stated" slot -> fold into the axis's own note in place.
    axis = dict(current_val) if isinstance(current_val, dict) else {}
    note = str(raw_value or "").strip()
    prev_note = str(axis.get("verdict_note") or "").strip()
    axis["verdict_note"] = f"{prev_note} {note}".strip() if note else prev_note
    axis["user_correction"] = text

    now_ms = int(time.time() * 1000)
    history_map = dict(report.get("finding_history") or {})
    if isinstance(current_val, dict) and not current_val.get("status"):
        _push_finding_history(
            history_map, finding_id, current_val,
            photo_ids=photo_ids, reason=f"you corrected this: {text[:140]}",
            now_ms=now_ms,
        )
    doc = dict(report)
    doc[finding_id] = axis
    doc["finding_history"] = history_map
    doc["source"] = "correction"
    stored = False
    try:
        from firebase_admin import firestore

        payload = dict(doc)
        payload["created_at"] = firestore.SERVER_TIMESTAMP
        _report_ref(db, uid).set(payload)
        stored = True
        _stamp_current(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: correction store failed for %s/%s", uid, finding_id
        )
    return {
        "ok": stored, "reply": reply, "finding_id": finding_id, "value": axis,
    }


async def clear_finding(db, uid: str, finding_id: str) -> dict:
    """Clear a previously-``stated`` attribute override back to unknown/
    computed: deletes ``finding_id`` off ``profile/main`` (so
    :func:`physical_attributes.merge`'s precedence falls through to whatever
    the photo analysis — or nothing — says) and re-syncs the persisted
    Appearance report exactly like :func:`correct_finding`'s attribute
    branch does.

    Only ever valid for a real :func:`physical_attributes.fields` name —
    face/body have no stated slot to clear, so a caller should route those to
    :func:`correct_finding` instead; this raises ``KeyError`` for them too,
    belt-and-suspenders against a caller that doesn't already filter them
    out. Also raises ``KeyError`` when there's no report yet.

    Returns ``{ok: True, finding_id}``."""
    report = _read_report_doc(db, uid)
    if not report:
        raise KeyError("no appearance report yet")
    if finding_id not in physical_attributes.fields():
        raise KeyError(finding_id)

    from firebase_admin import firestore

    db.collection("users").document(uid).collection("profile").document(
        "main"
    ).set({finding_id: firestore.DELETE_FIELD}, merge=True)

    try:
        pa_doc = await physical_attributes.refresh(db, uid)
    except token_ledger.TokenCapExceeded:
        pa_doc = None
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: clear-finding refresh failed for %s/%s", uid, finding_id
        )
        pa_doc = None
    attributes = _attributes_payload(pa_doc) if pa_doc else (
        report.get("attributes") or {"status": "needs_photo"}
    )
    _persist_report(
        db, uid,
        attributes=attributes,
        face=report.get("face") or dict(NEEDS_FACE),
        body=report.get("body") or dict(NEEDS_BODY),
        photo_count=int((pa_doc or {}).get("photo_count") or report.get("photo_count") or 0),
        source="correction",
    )
    return {"ok": True, "finding_id": finding_id}
