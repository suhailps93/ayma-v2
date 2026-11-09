"""Face matching via main-LLM vision pairwise check (ARCHITECTURE.md §2.5).

Replaces stored face embeddings with an on-demand LiveKit-brain vision check
holding two pictures: the user's reference photo and a candidate photo.
LiveKit-only inference: calls gemini.generate_json with images=[...],
running through the same LiveKit gateway route as photo moderation.
No direct Vertex, no new provider, no spend.
"""

from __future__ import annotations

import logging
from pathlib import Path

import biometric_consent
import gemini
import media_embed
import schema
import token_ledger
from prompt import load_prompt_file

logger = logging.getLogger("ayma.face_match")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "face_match_check.md"

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {
            "type": "string",
            "enum": ["self", "not_self", "unknown"],
        },
        "confidence": {
            "type": "string",
            "enum": ["high", "medium", "low"],
        },
        "face_visible": {"type": "boolean"},
        "reason": {"type": "string"},
    },
    "required": ["verdict", "confidence", "face_visible", "reason"],
}

# Pair-verdict cache keyed by the two storage paths: store the verdict, never a vector.
_pair_cache: dict[tuple[str, str], dict] = {}


def clear_cache() -> None:
    """Clear in-memory pair-verdict cache (used in testing)."""
    _pair_cache.clear()


def _cache_key(path_a: str, path_b: str) -> tuple[str, str] | None:
    pa = (path_a or "").strip()
    pb = (path_b or "").strip()
    if pa and pb:
        return (min(pa, pb), max(pa, pb))
    return None


def get_reference_photos(db, uid: str) -> list[str]:
    """The comparison set on the SAME account: verified selfie storage path
    (authoritative) plus the pictures already uploaded on that account as
    additional references; never another account's pictures.

    Returns [] when the account has no biometric consent (biometric_consent.py)
    or no photos exist yet.
    """
    if not (db and uid):
        return []
    try:
        if not biometric_consent.has_consent_fresh(db, uid):
            return []
    except Exception:  # noqa: BLE001
        return []

    refs: list[str] = []
    seen: set[str] = set()

    # 1. Authoritative reference: verified selfie path if present
    try:
        user_snap = db.collection("users").document(uid).get()
        if getattr(user_snap, "exists", False):
            data = user_snap.to_dict() or {}
            fv = data.get(schema.FIELD_FACE_VERIFICATION) or {}
            selfie_path = str(
                fv.get(schema.FACE_VERIFICATION_STORAGE_PATH) or ""
            ).strip()
            if selfie_path and selfie_path not in seen:
                refs.append(selfie_path)
                seen.add(selfie_path)
    except Exception:  # noqa: BLE001
        logger.warning(
            "face_match: selfie reference lookup failed for %s", uid, exc_info=True
        )

    # 2. Additional references: pictures already uploaded on that account
    try:
        media_snaps = (
            db.collection("users")
            .document(uid)
            .collection("user_media")
            .stream()
        )
        for doc in media_snaps:
            d = doc.to_dict() or {}
            sp = str(d.get("storage_path") or "").strip()
            # Only include approved/valid uploaded photos
            status = d.get(schema.MEDIA_MODERATION_STATUS, schema.MEDIA_STATUS_APPROVED)
            if sp and sp not in seen and status != schema.MEDIA_STATUS_FLAGGED:
                refs.append(sp)
                seen.add(sp)
    except Exception:  # noqa: BLE001
        logger.warning(
            "face_match: user_media reference lookup failed for %s", uid, exc_info=True
        )

    return refs


def _resolve_image(img: str | tuple[bytes, str]) -> tuple[bytes, str, str]:
    """Return (bytes, mime, storage_path)."""
    if isinstance(img, str):
        path = img.strip()
        data, mime = media_embed.download_bytes(path)
        return data, mime, path
    if isinstance(img, (tuple, list)) and len(img) >= 2:
        path = str(img[2]) if len(img) > 2 else ""
        return img[0], img[1], path
    return b"", "", ""


async def check_same_person(
    reference: str | tuple[bytes, str],
    candidate: str | tuple[bytes, str],
    *,
    uid: str | None = None,
    feature: str = token_ledger.FEATURE_PHOTO_MODERATION,
    ref_path: str = "",
    cand_path: str = "",
) -> dict:
    """Pairwise two-picture check via LiveKit Gemini vision call.

    Returns:
        {
            "verdict": "self" | "not_self" | "unknown",
            "confidence": "high" | "medium" | "low",
            "face_visible": bool,
            "reason": str,
        }
    """
    try:
        ref_bytes, ref_mime, ref_sp = _resolve_image(reference)
        ref_path = ref_path or ref_sp
    except Exception:  # noqa: BLE001
        logger.warning("face_match: could not resolve reference image", exc_info=True)
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": False,
            "reason": "Could not read reference image",
        }

    try:
        cand_bytes, cand_mime, cand_sp = _resolve_image(candidate)
        cand_path = cand_path or cand_sp
    except Exception:  # noqa: BLE001
        logger.warning("face_match: could not resolve candidate image", exc_info=True)
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": False,
            "reason": "Could not read candidate image",
        }

    if not ref_bytes or not cand_bytes:
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": False,
            "reason": "Empty image bytes",
        }

    # Check pair-verdict cache
    key = _cache_key(ref_path, cand_path)
    if key and key in _pair_cache:
        return dict(_pair_cache[key])

    try:
        raw_result = await gemini.generate_json(
            "Compare Image 1 (reference) and Image 2 (candidate).",
            system_prompt=load_prompt_file(_PROMPT_PATH),
            response_schema=RESPONSE_SCHEMA,
            images=[(ref_bytes, ref_mime), (cand_bytes, cand_mime)],
            uid=uid,
            feature=feature,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001
        logger.exception("face_match: vision comparison call failed")
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": False,
            "reason": "Vision model call failed",
        }

    if not isinstance(raw_result, dict):
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": False,
            "reason": "Invalid response from model",
        }

    verdict = str(raw_result.get("verdict") or "").strip().lower()
    if verdict not in ("self", "not_self", "unknown"):
        verdict = "unknown"

    confidence = str(raw_result.get("confidence") or "").strip().lower()
    if confidence not in ("high", "medium", "low"):
        confidence = "low"

    face_visible = bool(raw_result.get("face_visible", True))
    if not face_visible and verdict == "self":
        verdict = "not_self"

    reason = str(raw_result.get("reason", "")).strip()

    verdict_record = {
        "verdict": verdict,
        "confidence": confidence,
        "face_visible": face_visible,
        "reason": reason,
    }

    if key:
        _pair_cache[key] = verdict_record

    return verdict_record


async def classify_photo(
    db,
    uid: str,
    candidate: str | tuple[bytes, str],
    *,
    cand_path: str = "",
    feature: str = token_ledger.FEATURE_PHOTO_MODERATION,
) -> dict:
    """Compare a candidate photo against the account's own comparison set
    (verification selfie authoritative + existing uploaded pictures).
    """
    refs = get_reference_photos(db, uid)
    if not refs:
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": True,
            "reason": "No reference photos for this account",
        }

    last_not_self: dict | None = None
    for ref_path in refs:
        if cand_path and ref_path == cand_path:
            continue
        res = await check_same_person(
            ref_path,
            candidate,
            uid=uid,
            feature=feature,
            ref_path=ref_path,
            cand_path=cand_path,
        )
        if res.get("verdict") == "self":
            return res
        if res.get("verdict") == "not_self":
            last_not_self = res

    if last_not_self is not None:
        return last_not_self

    return {
        "verdict": "unknown",
        "confidence": "low",
        "face_visible": True,
        "reason": "Could not conclusively verify candidate against references",
    }
