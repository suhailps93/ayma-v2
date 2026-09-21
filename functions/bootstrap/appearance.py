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

import asyncio
import logging
import time

import body_report
import face_report
import gemini
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

# How many past values a single finding's `finding_history` keeps — a
# rolling window, not a full audit log.
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
                {
                    "bytes": data,
                    "mime": mime or "image/jpeg",
                    "attrs": attrs,
                    "path": sp,
                }
            )
    return out


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


# --- score -------------------------------------------------------------------


def _compute_score(face: dict | None, body: dict | None) -> dict:
    """``{value, basis}`` — the single headline number the report screen shows
    up top. Simply the average of whichever of the face / body
    ``overall_score`` reads are actually available (both honest 0-10 vision
    reads already); ``value`` is ``None`` with an explanatory ``basis`` when
    neither is."""
    parts: list[tuple[str, float]] = []
    for kind, section in (("face", face), ("body", body)):
        if not isinstance(section, dict) or not section.get("usable", True):
            continue
        v = section.get("overall_score")
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            parts.append((kind, float(v)))
    if not parts:
        return {
            "value": None,
            "basis": "Add a face or full-length photo for a score.",
        }
    avg = round(sum(v for _, v in parts) / len(parts), 1)
    label = " + ".join(k for k, _ in parts)
    n = len(parts)
    basis = f"Average of your {label} read{'s' if n != 1 else ''}."
    return {"value": avg, "basis": basis}


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
            "source_photos": list(pa_doc.get("photo_paths") or []),
        }
    else:
        attributes = {"status": "needs_photo"}

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
    doc = {
        "attributes": attributes,
        "face": face,
        "body": body,
        "score": _compute_score(face, body),
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
            "source_photos": list(pa_doc.get("photo_paths") or []),
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
        "score": _compute_score(face_val, body_val),
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
    face = data.get("face") or {}
    body = data.get("body") or {}
    return {
        "id": rid,
        "created_at": _iso(data.get("created_at")),
        "attributes": data.get("attributes") or {},
        "face": face,
        "body": body,
        # `score` is normally stored at write time; a report persisted before
        # this field existed still gets one computed on the fly rather than
        # showing nothing.
        "score": data.get("score") or _compute_score(face, body),
        # Per-finding correction history, keyed by finding id (a
        # `physical_attributes` field name, or `"face"` / `"body"`) — additive,
        # only ever written by `correct_finding`. Safe to ignore.
        "finding_history": data.get("finding_history") or {},
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


# --- finding corrections (§ appearance) --------------------------------------
#
# The free-text, tap-a-claim correction pattern Your Story's "Edit with Ayma"
# uses, applied to one Appearance finding at a time — a `physical_attributes`
# field, or the literal "face" / "body". Unlike Your Story (which edits raw
# wiki prose through the general chat/tool pipeline), a finding is a
# structured value, so this always goes through a small, schema-constrained
# Gemini call rather than free-form prose rewriting:
#
# * an attribute field's correction is coerced against the exact same
#   enum/numeric/free-text rules `POST /physical-attributes/correct` enforces,
#   then written through that same "stated always wins" path — so it survives
#   every future photo-derived re-run, not just this report.
# * a face/body correction can only ever revise the short `verdict_note` —
#   never the score or the feature breakdown — a deliberately narrow surface
#   so a casual correction can't silently rewrite an honest vision read.
#
# Both apply in place on the caller's *current* Appearance report doc (the one
# `appearance/current` points at), matching "one persistent, evolving report"
# — re-opening the same report id shows the correction, not a new run.

_ATTR_CORRECTION_SYSTEM = (
    "You are Ayma, a dating-app companion. The user is correcting one "
    "specific physical-attribute finding about themselves, in their own "
    "words. Decide whether their message states a clear new value for this "
    "field. If it does, set \"value\" to it, matching the allowed options "
    "exactly. If it doesn't — off-topic, a question, unclear, or just "
    'agreement — set "value" to "no_change". Always write a short, warm, '
    "first-person reply as Ayma (one sentence) confirming what you did, or "
    "explaining that you didn't catch a usable value."
)

_FACE_BODY_CORRECTION_SYSTEM = (
    "You are Ayma, a dating-app companion. The user is giving feedback on "
    "their {kind} analysis, in their own words. Decide whether their message "
    "asks you to change the short verdict note Ayma gives about this "
    "section. If it clearly does, write a revised one-sentence note "
    "reflecting their feedback — still honest, never just flattering. If it "
    "doesn't call for a change, leave the note exactly as given. Always "
    "write a short, warm, first-person reply as Ayma (one sentence) "
    "confirming what you did."
)


def _correction_value_schema(field: str) -> dict:
    """The response schema for one attribute-field correction call — mirrors
    :func:`physical_attributes._response_schema` per-field typing, plus the
    ``"no_change"`` escape hatch for a message that doesn't actually name a
    new value."""
    if field in physical_attributes._NUMERIC_FIELDS:
        value_schema = {
            "type": "string",
            "description": 'a whole number with no units, or "no_change"',
        }
    else:
        values = physical_attributes._enum_values().get(field)
        if values:
            value_schema = {
                "type": "string",
                "enum": [v for v in values if v != "unknown"] + ["no_change"],
            }
        else:
            value_schema = {
                "type": "string",
                "description": 'free text, or "no_change"',
            }
    return {
        "type": "object",
        "properties": {"value": value_schema, "reply": {"type": "string"}},
        "required": ["value", "reply"],
    }


async def _correct_attribute(
    uid: str, field: str, current_value, message: str
) -> dict:
    """``{value, reply, changed}`` for one attribute-field correction. Never
    raises on a bad/unclear message — ``changed`` is just ``False`` and
    ``value`` stays ``current_value``. Propagates
    ``token_ledger.TokenCapExceeded``."""
    label = physical_attributes._LABELS.get(field, field)
    prompt = (
        f"Field: {label}\n"
        f"Current value: {current_value!r}\n"
        f'The user says: "{message}"'
    )
    result = await gemini.generate_json(
        prompt,
        system_prompt=_ATTR_CORRECTION_SYSTEM,
        response_schema=_correction_value_schema(field),
        uid=uid,
        feature=token_ledger.FEATURE_PHYSICAL_ATTRS,
    )
    reply = str((result or {}).get("reply") or "").strip() or "Got it."
    raw = str((result or {}).get("value") or "").strip()
    if not raw or raw.lower() == "no_change":
        return {"value": current_value, "reply": reply, "changed": False}
    coerced = physical_attributes._coerce(field, raw)
    if not physical_attributes._is_known(field, coerced):
        return {"value": current_value, "reply": reply, "changed": False}
    return {"value": coerced, "reply": reply, "changed": coerced != current_value}


async def _correct_face_or_body(uid: str, kind: str, section: dict, message: str) -> dict:
    """``{value, reply, changed}`` for a face/body correction — ``value`` is
    the (possibly revised) ``verdict_note``. Propagates
    ``token_ledger.TokenCapExceeded``."""
    if not isinstance(section, dict) or section.get("status"):
        noun = "face" if kind == "face" else "full-length"
        return {
            "value": "",
            "reply": f"There's no {kind} read yet to correct — add a {noun} photo first.",
            "changed": False,
        }
    current_note = str(section.get("verdict_note", "")).strip()
    prompt = (
        f"Current verdict: {section.get('verdict', '')} "
        f"({section.get('overall_score', '')}/10)\n"
        f"Current note: {current_note!r}\n"
        f'The user says: "{message}"'
    )
    feature = (
        token_ledger.FEATURE_FACE_REPORT
        if kind == "face" else token_ledger.FEATURE_BODY_REPORT
    )
    result = await gemini.generate_json(
        prompt,
        system_prompt=_FACE_BODY_CORRECTION_SYSTEM.format(kind=kind),
        response_schema={
            "type": "object",
            "properties": {
                "changed": {"type": "boolean"},
                "verdict_note": {"type": "string"},
                "reply": {"type": "string"},
            },
            "required": ["changed", "verdict_note", "reply"],
        },
        uid=uid,
        feature=feature,
    )
    reply = str((result or {}).get("reply") or "").strip() or "Noted."
    if not isinstance(result, dict) or not result.get("changed"):
        return {"value": current_note, "reply": reply, "changed": False}
    new_note = str(result.get("verdict_note") or "").strip() or current_note
    return {"value": new_note, "reply": reply, "changed": new_note != current_note}


def _push_history(existing: list | None, entry: dict) -> list:
    entry = dict(entry)
    entry["changed_at_ms"] = int(time.time() * 1000)
    out = list(existing or []) + [entry]
    return out[-_MAX_FINDING_HISTORY:]


async def correct_finding(db, uid: str, finding_id: str, message: str) -> dict | None:
    """Interpret free-text ``message`` as a correction to one Appearance
    finding — a ``physical_attributes`` field name, or the literal ``"face"``
    / ``"body"`` — on the caller's *current* report, apply it in place, and
    return ``{finding_id, value, reply}``.

    Returns ``None`` when the caller has no current report to correct (→ the
    endpoint 404s). Raises ``ValueError`` for an unknown ``finding_id`` (→
    404). Propagates ``token_ledger.TokenCapExceeded`` on a credit-cap hit (→
    the endpoint returns ``{"usage_capped": true}``)."""
    finding_id = (finding_id or "").strip()
    message = (message or "").strip()
    if not message:
        raise ValueError("message must not be blank")
    known = set(physical_attributes.fields()) | {"face", "body"}
    if finding_id not in known:
        raise ValueError(f"Unknown finding: {finding_id!r}")

    ptr = current(db, uid) or {}
    report_id = str(ptr.get("report_id") or "").strip()
    if not report_id:
        return None
    ref = (
        db.collection("users")
        .document(uid)
        .collection(REPORTS_COLLECTION)
        .document(report_id)
    )
    snap = ref.get()
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}

    if finding_id in ("face", "body"):
        section = data.get(finding_id) or {}
        result = await _correct_face_or_body(uid, finding_id, section, message)
        if result.get("changed"):
            history = _push_history(
                ((data.get("finding_history") or {}).get(finding_id)),
                {
                    "value": result["value"],
                    "source": "stated",
                    "confidence": "high",
                    "photo_ids": list(section.get("source_photos") or []),
                    "reason": message[:200],
                },
            )

            def _write() -> None:
                ref.set(
                    {
                        finding_id: {"verdict_note": result["value"]},
                        "finding_history": {finding_id: history},
                    },
                    merge=True,
                )

            await asyncio.to_thread(_write)
        return {
            "finding_id": finding_id,
            "value": result["value"],
            "reply": result["reply"],
        }

    # An attribute field.
    record = (data.get("attributes") or {}).get("record") or {}
    current_rec = record.get(finding_id) or {}
    current_value = current_rec.get("value")
    result = await _correct_attribute(uid, finding_id, current_value, message)
    if result.get("changed"):
        coerced = result["value"]
        new_rec = {
            "value": coerced,
            "source": "stated",
            "confidence": "high",
            "note": physical_attributes._STATED_NOTE,
        }
        photo_ids = list(
            (data.get("attributes") or {}).get("source_photos") or []
        )
        history = _push_history(
            (data.get("finding_history") or {}).get(finding_id),
            {
                "value": coerced,
                "source": "stated",
                "confidence": "high",
                "photo_ids": photo_ids,
                "reason": message[:200],
            },
        )

        def _write() -> None:
            db.collection("users").document(uid).collection("profile").document(
                "main"
            ).set({finding_id: coerced}, merge=True)
            db.collection("users").document(uid).collection(
                physical_attributes.COLLECTION
            ).document(physical_attributes.DOC_ID).set(
                {"fields": {finding_id: new_rec}}, merge=True
            )
            ref.set(
                {
                    "attributes": {"record": {finding_id: new_rec}},
                    "finding_history": {finding_id: history},
                },
                merge=True,
            )

        await asyncio.to_thread(_write)
    return {
        "finding_id": finding_id,
        "value": result["value"],
        "reply": result["reply"],
    }


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
