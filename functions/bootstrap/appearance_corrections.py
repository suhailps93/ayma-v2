"""Appearance corrections: free-text corrections and clearing attribute overrides.

Mirrors story.edit_section's pattern (§ appearance corrections) for one
structured finding instead of narrative prose, committed immediately.

Split out of ``appearance.py`` (Tier-2 sweep item #10).
"""

from __future__ import annotations

import logging
import time

import gemini
import media_embed
import physical_attributes
import token_ledger
from appearance_storage import (
    NEEDS_BODY,
    NEEDS_FACE,
    _persist_report,
    _push_finding_history,
    _read_report_doc,
    _report_ref,
    _stamp_current,
)

logger = logging.getLogger("ayma.appearance")

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
    import appearance

    read_doc_fn = getattr(appearance, "_read_report_doc", _read_report_doc)
    pa_mod = getattr(appearance, "physical_attributes", physical_attributes)
    gemini_mod = getattr(appearance, "gemini", gemini)
    attrs_payload_fn = getattr(appearance, "_attributes_payload", None)
    if attrs_payload_fn is None:
        from appearance_engine import _attributes_payload
        attrs_payload_fn = _attributes_payload
    persist_fn = getattr(appearance, "_persist_report", _persist_report)
    push_history_fn = getattr(appearance, "_push_finding_history", _push_finding_history)
    ref_fn = getattr(appearance, "_report_ref", _report_ref)
    stamp_fn = getattr(appearance, "_stamp_current", _stamp_current)

    text = (message or "").strip()
    if not text:
        raise ValueError("message is required")

    report = read_doc_fn(db, uid)
    if not report:
        raise KeyError("no appearance report yet")

    is_attribute = finding_id in pa_mod.fields()
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
        allowed = pa_mod._enum_values().get(finding_id)
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
        result = await gemini_mod.generate_json(
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
        coerced = pa_mod._coerce(finding_id, raw_value)
        if not pa_mod._is_known(finding_id, coerced):
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
            pa_doc = await pa_mod.refresh(db, uid)
        except token_ledger.TokenCapExceeded:
            pa_doc = None
        except Exception:  # noqa: BLE001
            logger.exception(
                "appearance: correction refresh failed for %s/%s", uid, finding_id
            )
            pa_doc = None
        attributes = attrs_payload_fn(pa_doc) if pa_doc else (
            report.get("attributes") or {"status": "needs_photo"}
        )
        persist_fn(
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
        push_history_fn(
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
        ref_fn(db, uid).set(payload)
        stored = True
        stamp_fn(db, uid)
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
    import appearance

    read_doc_fn = getattr(appearance, "_read_report_doc", _read_report_doc)
    pa_mod = getattr(appearance, "physical_attributes", physical_attributes)
    attrs_payload_fn = getattr(appearance, "_attributes_payload", None)
    if attrs_payload_fn is None:
        from appearance_engine import _attributes_payload
        attrs_payload_fn = _attributes_payload
    persist_fn = getattr(appearance, "_persist_report", _persist_report)

    report = read_doc_fn(db, uid)
    if not report:
        raise KeyError("no appearance report yet")
    if finding_id not in pa_mod.fields():
        raise KeyError(finding_id)

    from firebase_admin import firestore

    db.collection("users").document(uid).collection("profile").document(
        "main"
    ).set({finding_id: firestore.DELETE_FIELD}, merge=True)

    try:
        pa_doc = await pa_mod.refresh(db, uid)
    except token_ledger.TokenCapExceeded:
        pa_doc = None
    except Exception:  # noqa: BLE001
        logger.exception(
            "appearance: clear-finding refresh failed for %s/%s", uid, finding_id
        )
        pa_doc = None
    attributes = attrs_payload_fn(pa_doc) if pa_doc else (
        report.get("attributes") or {"status": "needs_photo"}
    )
    persist_fn(
        db, uid,
        attributes=attributes,
        face=report.get("face") or dict(NEEDS_FACE),
        body=report.get("body") or dict(NEEDS_BODY),
        photo_count=int((pa_doc or {}).get("photo_count") or report.get("photo_count") or 0),
        source="correction",
    )
    return {"ok": True, "finding_id": finding_id}
