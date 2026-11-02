"""Appearance analysis engine: photo gathering, selection, dedup, and execution.

Coordinates the Gemini vision passes across physical_attributes, face_report,
and body_report into the unified Appearance report (§ appearance report v2).

Split out of ``appearance.py`` (Tier-2 sweep item #10).
"""

from __future__ import annotations

import logging

import body_report
import face_report
import media_embed
import physical_attributes
import schema
import skill_memory
import token_ledger
from appearance_storage import (
    CAT_NO_ELIGIBLE,
    CAT_RAN,
    CAT_SKIPPED,
    NEEDS_BODY,
    NEEDS_FACE,
    REPORT_DOC_ID,
    _axis_ran,
    _category_status,
    _persist_report,
    _read_report_doc,
    _record,
)

logger = logging.getLogger("ayma.appearance")

_MAX_PHOTOS = 6


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
        mid = str(e.get("media_id") or "").strip()
        attrs: dict = {}
        if not sp:
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
                    "media_id": mid,
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


def _bucket_eligible(attrs: dict, flag: str) -> bool:
    """Whether ``attrs`` lands a photo in the pre-run sheet's ``flag`` bucket —
    the SAME auto-categorisation :func:`photo_attrs.eligibility` uses, so the
    backend honours exactly the photos the sheet could have offered and no
    others. A photo clearly for one axis (e.g. a face-only crop) is never
    eligible for the other; an untagged/ambiguous photo is eligible for both,
    so a freshly-added, not-yet-classified photo the user picked is still read.
    """
    uf = bool(attrs.get("usable_for_face"))
    ub = bool(attrs.get("usable_for_body"))
    return (uf or not ub) if flag == "usable_for_face" else (ub or not uf)


def _pick_all(
    photos: list[dict],
    extra: list[tuple[bytes, str, str]],
    flag: str,
    *,
    only_media_ids: set[str] | None = None,
) -> list[tuple[bytes, str, str]]:
    """Every photo to feed this axis, as ``[(bytes, mime, storage_path), …]`` —
    all fed together to :func:`face_report.run` / :func:`body_report.run` for
    ONE combined read of the same person.

    When ``only_media_ids`` is given (an explicit, grid-based selection from the
    pre-run sheet) ALL *selected* grid photos that are bucket-eligible for the
    axis (:func:`_bucket_eligible`) are returned, in grid order, capped at
    :data:`_MAX_PHOTOS` — honouring the user's own pick, including an
    untagged/freshly-added photo, while still refusing a photo clearly meant for
    the other axis (§ founder 2026-10-28: all photos selectable, the user's
    choice drives the read). The ``extra`` fallback is deliberately NOT taken for
    an explicit selection: a chat attachment is never silently substituted for a
    named grid photo — so a selection that matches nothing eligible resolves to
    "not available", never a bogus read.

    With no explicit selection (``only_media_ids is None`` — the chat/auto path)
    the legacy behaviour stands: the single best photo — the first grid photo
    whose shot-type ``flag`` is set, else the first attached ``extra`` image — as
    a one-item list, so the auto path spends on just one photo. Empty list when
    nothing qualifies."""
    import appearance

    bucket_fn = getattr(appearance, "_bucket_eligible", _bucket_eligible)
    if only_media_ids is not None:
        out: list[tuple[bytes, str, str]] = []
        for p in photos:
            attrs = p.get("attrs") or {}
            if p.get("media_id") in only_media_ids and bucket_fn(attrs, flag):
                out.append((p["bytes"], p["mime"], p.get("path", "")))
        return out[:_MAX_PHOTOS]
    for p in photos:
        if (p.get("attrs") or {}).get(flag):
            return [(p["bytes"], p["mime"], p.get("path", ""))]
    if extra:
        return [extra[0]]
    return []


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
    import appearance

    read_doc_fn = getattr(appearance, "_read_report_doc", _read_report_doc)
    if not current_paths:
        return None
    prev = read_doc_fn(db, uid)
    if not prev:
        return None
    prev_attrs = prev.get("attributes")
    prev_paths = prev_attrs.get("source_photos") if isinstance(prev_attrs, dict) else None
    if not isinstance(prev_paths, list) or not prev_paths:
        return None
    if set(prev_paths) != set(current_paths):
        return None
    return prev


def _owned_extra_images(
    db, uid: str, extra: list[tuple[bytes, str, str]]
) -> list[tuple[bytes, str, str]]:
    """Keep only the chat-shared images that are genuinely the user's OWN
    photos of THEMSELVES — drop any confirmed NOT to be the account holder.

    ``extra`` are chat attachments (``(bytes, mime, storage_path)``) folded in
    by the chat/voice ``run_appearance_report`` tool, the
    ``analyze_physical_attributes`` tool and ``POST /appearance[/report]``. A
    photo the user merely *shared* in chat (a profile they're browsing, a stock
    image) lives under their own ``uploads/`` tree but is NOT a photo of them,
    so the storage-path ownership check alone can't tell the two apart
    (§ R2-C8a). The authoritative same-person signal is the face-match verdict:
    the ``photo_notes`` ``is_user`` flag persisted when the photo was shared
    (``main._persist_shared_photo_verdict``), with a live face match
    (``deep_dive_images``) as the backstop when no verdict was stored. Only a
    CONFIRMED non-match (stored ``is_user == "no"`` / live ``"not_self"``) is
    excluded — a confirmed/plausible selfie and the "can't tell" band are kept,
    so a legitimate own photo is never dropped.

    Best-effort: any failure keeps the image (fail-open), never raising — the
    persisted verdict stays the reliable gate.
    """
    if not extra:
        return extra
    try:
        import photo_notes
        from public_profile import _photo_url
    except Exception:  # noqa: BLE001
        return extra
    refs = None  # fetched once, lazily, only if a live check is actually needed
    kept: list[tuple[bytes, str, str]] = []
    for data, mime, path in extra:
        verdict = ""
        if path:
            try:
                url = _photo_url(path)
                if url:
                    verdict = photo_notes.get_note(db, uid, url).get("is_user", "")
            except Exception:  # noqa: BLE001
                verdict = ""
        if verdict == "no":
            logger.info(
                "appearance: excluding not-self chat image %s for %s", path, uid
            )
            continue
        if verdict == "":
            # No stored same-person verdict — live face match as the backstop.
            try:
                import deep_dive_images

                if refs is None:
                    refs = deep_dive_images.reference_embeddings_for(db, uid)
                if refs:
                    emb = media_embed.embed_image_bytes(data, mime)
                    if deep_dive_images.classify_face_match(emb, refs) == "not_self":
                        logger.info(
                            "appearance: excluding not-self chat image %s for %s "
                            "(live match)", path, uid,
                        )
                        continue
            except Exception:  # noqa: BLE001
                logger.warning(
                    "appearance: own-photo check failed for %s", uid, exc_info=True
                )
        kept.append((data, mime, path))
    return kept


async def run_appearance(
    db,
    uid: str,
    *,
    extra_images: list[tuple[bytes, str, str]] | None = None,
    want_face: bool = True,
    want_body: bool = True,
    face_media_ids: list[str] | None = None,
    body_media_ids: list[str] | None = None,
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

    ``face_media_ids`` / ``body_media_ids`` — when the caller (the pre-run
    sheet) names an explicit, grid-based selection — restrict each axis to those
    grid photos, and ALL of the selected eligible photos for an axis are analysed
    together in ONE combined :func:`face_report.run` / :func:`body_report.run`
    read of the same person (capped at :data:`_MAX_PHOTOS`), not just the first
    (that first-photo-only read was the old "stale report" bug). ``None`` means
    "auto" (the single best eligible grid photo, or an ``extra_images``
    fallback), preserving the legacy/chat behaviour. A named selection is
    validated on the way in: only the caller's OWN current grid photos that are
    actually eligible for the axis survive — an id that isn't in the grid or
    isn't shot-type-eligible is dropped, so a mis-specified or stale id can never
    feed a bogus read.

    The returned/persisted report carries a ``category_status`` map
    (``{"face": ran|skipped|no_eligible_photo, "body": ...}``): ``skipped`` when
    the axis was gated off (``want_*=False``), ``no_eligible_photo`` when it was
    wanted but no eligible photo fed it (the axis stays
    :data:`NEEDS_FACE`/:data:`NEEDS_BODY` — never a 0-score section), ``ran``
    when it produced a real read.

    Founder's call: "if user rerun the Photo analysis without adding new
    photos just share the last aggregated one" — on the NO-SELECTION rerun path
    (``face_media_ids``/``body_media_ids`` both ``None`` — chat / auto
    reconcile), when every photo this run would analyse (grid + ``extra_images``,
    by storage path) is exactly the set already reflected on the persisted
    report, all three Gemini vision passes (:func:`physical_attributes.refresh`,
    :func:`face_report.run`, :func:`body_report.run`) are skipped entirely and
    the existing persisted report is returned unchanged (see
    :func:`_unchanged_since_last_run`). This dedup does NOT apply when the caller
    names an explicit grid selection: a deliberate "analyse THESE photos" pick
    always drives a fresh read (§ founder 2026-10-28), so selecting different
    already-in-grid photos yields a report reflecting them, never the prior one.
    Any addition or removal — or a photo that can't be reliably identified by
    storage path — also falls through to a normal run.
    """
    import appearance

    grid_photos_fn = getattr(appearance, "_grid_photos", _grid_photos)
    record_fn = getattr(appearance, "_record", _record)
    identified_paths_fn = getattr(appearance, "_identified_paths", _identified_paths)
    unchanged_fn = getattr(appearance, "_unchanged_since_last_run", _unchanged_since_last_run)
    cat_status_fn = getattr(appearance, "_category_status", _category_status)
    pa_mod = getattr(appearance, "physical_attributes", physical_attributes)
    attrs_payload_fn = getattr(appearance, "_attributes_payload", _attributes_payload)
    pick_all_fn = getattr(appearance, "_pick_all", _pick_all)
    face_mod = getattr(appearance, "face_report", face_report)
    body_mod = getattr(appearance, "body_report", body_report)
    memory_mod = getattr(appearance, "skill_memory", skill_memory)
    read_doc_fn = getattr(appearance, "_read_report_doc", _read_report_doc)
    axis_ran_fn = getattr(appearance, "_axis_ran", _axis_ran)
    persist_fn = getattr(appearance, "_persist_report", _persist_report)
    owned_extra_fn = getattr(appearance, "_owned_extra_images", _owned_extra_images)

    if not uid:
        return None
    # Only the user's OWN self-photos feed the appearance analysis. A chat-shared
    # image confirmed NOT to be the account holder (a browsed profile, a stock
    # photo) is dropped here before it can inflate the photo count or be analysed
    # as if it were them (§ R2-C8a).
    extra = owned_extra_fn(db, uid, list(extra_images or []))
    photos = grid_photos_fn(db, uid)
    if not photos and not extra:
        record_fn(db, uid, "skipped", source, "no_photo")
        return None

    # Whole-grid "nothing changed, re-share the last report" dedup applies ONLY
    # to the no-selection rerun path (chat / auto reconcile), where the caller
    # named no photos and the grid set is the sole input. An EXPLICIT grid
    # selection (``face_media_ids`` / ``body_media_ids`` from the pre-run sheet)
    # is a deliberate "analyse THESE photos" action: it must always drive a
    # fresh read, even when the overall grid set is unchanged — otherwise
    # picking different already-in-grid photos silently re-shows the prior
    # report (§ founder 2026-10-28: "Run analysis says updated but it's the SAME
    # old report"). A prior axis is then reused ONLY when that axis was genuinely
    # skipped (``want_*=False`` / nothing eligible) — see the per-axis merge
    # below, never because the grid set as a whole looked unchanged.
    explicit_selection = face_media_ids is not None or body_media_ids is not None
    current_paths = identified_paths_fn(photos, extra)
    prev = (
        None if explicit_selection
        else unchanged_fn(db, uid, current_paths)
    )
    if prev is not None:
        record_fn(db, uid, "skipped", source, "unchanged_photos")
        prev_face = prev.get("face") or dict(NEEDS_FACE)
        prev_body = prev.get("body") or dict(NEEDS_BODY)
        return {
            "id": REPORT_DOC_ID,
            "attributes": prev.get("attributes") or {},
            "face": prev_face,
            "body": prev_body,
            "photo_count": int(prev.get("photo_count") or 0),
            "model": str(prev.get("model") or ""),
            "source": prev.get("source") or source,
            "score": prev.get("score") or {"value": None, "basis": "none"},
            "finding_history": prev.get("finding_history") or {},
            "category_status": prev.get("category_status")
            or cat_status_fn(want_face, want_body, prev_face, prev_body),
        }

    face_sel = {m.strip() for m in face_media_ids if m.strip()} if face_media_ids is not None else None
    body_sel = {m.strip() for m in body_media_ids if m.strip()} if body_media_ids is not None else None

    # --- attributes: reuse physical_attributes (keeps the mirror + wiki fresh)
    attributes: dict
    try:
        pa_kwargs = {"extra_images": extra} if extra else {}
        pa_doc = await pa_mod.refresh(
            db, uid, persist_report=True, **pa_kwargs
        )
    except token_ledger.TokenCapExceeded:
        raise
    except Exception:  # noqa: BLE001 - a broken attrs pass shouldn't sink the report
        logger.exception("appearance: physical_attributes.refresh failed for %s", uid)
        pa_doc = None
    attributes = attrs_payload_fn(pa_doc)

    # --- face: ALL ticked face photos -> ONE combined read of the same person
    face: dict = dict(NEEDS_FACE)
    if want_face:
        picks = pick_all_fn(photos, extra, "usable_for_face", only_media_ids=face_sel)
        if picks:
            report = await face_mod.run(picks, uid=uid)
            if isinstance(report, dict) and report.get("usable", True):
                face = report
                memory_mod.save_face_analysis(db, uid, report)
                memory_mod.promote(db, uid, "face_analysis")

    # --- body: ALL ticked body photos -> ONE combined read of the same person
    body: dict = dict(NEEDS_BODY)
    if want_body:
        picks = pick_all_fn(photos, extra, "usable_for_body", only_media_ids=body_sel)
        if picks:
            report = await body_mod.run(picks, uid=uid)
            if isinstance(report, dict) and report.get("usable", True):
                body = report
                memory_mod.save_body_analysis(db, uid, report)
                memory_mod.promote(db, uid, "body_analysis")

    # Preserve any axis this run did not freshly produce. A rerun that runs
    # only one axis — the other skipped (``want_*=False``) or wanted but with
    # no eligible photo — must NOT wipe the previously-produced section back to
    # NEEDS_*: that drops the unified face+body score and makes the shareable
    # report card vanish (§ founder 2026-10-28: "after Ayma reran I don't see
    # the report card anymore"). Mirrors :func:`record_background_result`'s
    # reuse; the previous doc is read once here.
    prev_doc = read_doc_fn(db, uid)
    if not axis_ran_fn(face) and axis_ran_fn(prev_doc.get("face")):
        face = prev_doc["face"]
    if not axis_ran_fn(body) and axis_ran_fn(prev_doc.get("body")):
        body = prev_doc["body"]
    if isinstance(attributes, dict) and attributes.get("status"):
        prev_attrs = prev_doc.get("attributes")
        if isinstance(prev_attrs, dict) and not prev_attrs.get("status"):
            attributes = prev_attrs

    # A reused real read displays as a produced section, not an add-photo
    # prompt, so category_status is derived from the MERGED values.
    category_status = cat_status_fn(
        want_face or axis_ran_fn(face), want_body or axis_ran_fn(body), face, body
    )
    photo_count = len(photos) + len(extra)
    doc = persist_fn(
        db, uid,
        attributes=attributes, face=face, body=body,
        photo_count=photo_count, source=source,
        category_status=category_status,
    )

    produced = [
        k
        for k, v in (("face", face), ("body", body))
        if not (isinstance(v, dict) and v.get("status"))
    ]
    if not (isinstance(attributes, dict) and attributes.get("status")):
        produced.append("attributes")
    record_fn(
        db, uid, "ok", source,
        f"produced={'+'.join(produced) or 'none'} photos={photo_count}",
    )
    # Completion notification: a user-initiated run is fired unawaited by the
    # client (POST /appearance/report), so the open report screen can't learn
    # it landed once the user navigates away. Fire an in-app "report ready"
    # notification here — where the report is persisted — so it works even if
    # the client backgrounded/left (as long as the request completed). NOT for
    # the silent background reconcile (``source == "auto"``), which the user
    # never asked for and shouldn't be pinged about. Best-effort: never let a
    # notification failure sink the report the request returns.
    if source != "auto" and doc.get("id"):
        try:
            import notifications_triggers

            await notifications_triggers.notify_report_ready(
                db, uid, str(doc["id"]), body_only=(want_body and not want_face)
            )
        except Exception:  # noqa: BLE001
            logger.exception(
                "appearance: report-ready notification failed for %s", uid
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
    import appearance

    read_doc_fn = getattr(appearance, "_read_report_doc", _read_report_doc)
    pa_mod = getattr(appearance, "physical_attributes", physical_attributes)
    attrs_payload_fn = getattr(appearance, "_attributes_payload", _attributes_payload)
    cat_status_fn = getattr(appearance, "_category_status", _category_status)
    persist_fn = getattr(appearance, "_persist_report", _persist_report)

    if not uid or (face is None and body is None):
        return ""

    prev: dict = {}
    try:
        prev = read_doc_fn(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: previous-report read failed for %s", uid
        )

    try:
        pa_doc = pa_mod.current(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: physical_attributes.current failed for %s", uid
        )
        pa_doc = None

    if pa_doc:
        attributes: dict = attrs_payload_fn(pa_doc)
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

    # A background result only ever ran the axis/axes it carries fresh content
    # for; the other axis keeps whatever the previous report said, so its status
    # is derived from the merged value (ran when known, else no_eligible_photo).
    category_status = cat_status_fn(True, True, face_val, body_val)
    try:
        doc = persist_fn(
            db, uid,
            attributes=attributes, face=face_val, body=body_val,
            photo_count=photo_count, source=source,
            category_status=category_status,
        )
    except Exception:  # noqa: BLE001 - _persist_report already guards this; belt & suspenders
        logger.exception("appearance: background-result store failed for %s", uid)
        return ""
    return str(doc.get("id") or "")
