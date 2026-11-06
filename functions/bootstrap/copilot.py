"""Screen co-pilot — Ayma watches a user-shared screen and points.

The user shares their screen from inside Ayma (Android MediaProjection,
per-session system consent), asks what to tap for a goal, and this endpoint
runs ONE vision pass over the latest shared frame: it locates the target
element and returns normalized screen coordinates. The app draws a
pass-through highlight ring over that spot (TYPE_APPLICATION_OVERLAY,
FLAG_NOT_TOUCHABLE) and the USER taps — Ayma never taps, types, or controls
another app. That split is deliberate: Google Play prohibits autonomous
control via Accessibility, and this feature is vision + overlay + voice
guidance only.

Inference routing (founder rule, PERMANENT): the vision pass goes through
:func:`gemini.generate_json` with an image, which is the existing backend
vision path — it resolves through the LiveKit Inference gateway routing
(``llm_routing.route_for("vision")``; production defaults route vision to
``inference`` and the Google fallback flag is denylisted off). This module
makes NO direct call to any model provider of its own.

Frames are never stored: the image arrives in the request body, is passed
to the vision call in memory, and is gone when the request ends. Secure
screens (FLAG_SECURE — banking / passwords) never reach here at all: the
native capture pauses on black frames before any frame leaves the device.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import logging

from fastapi import APIRouter, Depends, HTTPException
from firebase_admin import storage
from pydantic import BaseModel, Field

import age_gate
import gemini
from auth import require_uid
from config import CONFIG
from db import get_db

logger = logging.getLogger("ayma.copilot")

# A shared frame is downscaled on-device to <=720px wide before upload; a
# JPEG of that size is well under this cap. Anything larger is not a frame
# this feature produced — refuse it instead of paying vision tokens on it.
MAX_FRAME_BYTES = 1_500_000
ALLOWED_MIMES = {"image/jpeg", "image/png", "image/webp"}
MAX_GOAL_CHARS = 500


def _bucket():
    return storage.bucket(CONFIG.storage_bucket)


async def require_not_underage_uid(uid: str = Depends(require_uid)) -> str:
    """18+ gate (same contract as main's gate): refuses minors, lets a
    not-yet-birthdated onboarding user through. Defined locally so this
    router carries no import cycle back into ``main`` (same pattern as
    ``practice_date``)."""
    try:
        await asyncio.to_thread(
            age_gate.enforce, get_db(), _bucket, uid, require_birthdate=False
        )
    except age_gate.AgeGateError as exc:
        raise HTTPException(
            status_code=403, detail={"code": exc.code, "message": exc.message}
        ) from exc
    return uid


router = APIRouter(prefix="/copilot", tags=["copilot"])

_SYSTEM_PROMPT = """You are Ayma's screen co-pilot vision pass. The user has shared a screenshot of their phone screen and told you their goal. Find the ONE on-screen element the user should tap next to make progress on that goal.

Rules:
- Coordinates are normalized to the image: x and y are the CENTER of the target element as fractions of image width/height (0.0 = left/top edge, 1.0 = right/bottom edge). w and h are the element's size as fractions of image width/height.
- If no element on this screen advances the goal, set found=false and use "say" to tell the user in one short sentence what to do instead (e.g. scroll, go back, open a named app). Never guess a location for something that is not visible.
- Prefer the exact control matching the goal over a merely related one. If several match, pick the most prominent.
- kind is "text_field" when the target is an editable text input, "button" for buttons, "link" for text links, "tab" for navigation tabs, otherwise "other".
- When kind is "text_field" AND the goal tells you what the user wants to say or enter, write that text in draft_text, ready for the user to review and paste. Otherwise draft_text is empty. Never invent personal data (names, addresses, payment details) for draft_text.
- "say" is one short, friendly spoken sentence naming the highlighted element and what tapping it does, e.g. "Tap the blue Send button at the bottom right."
- "label" is the element's visible text or a 2-4 word description.
- confidence is your honest 0.0-1.0 certainty that this is the right element."""

_RESPONSE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "found": {"type": "boolean"},
        "x": {"type": "number"},
        "y": {"type": "number"},
        "w": {"type": "number"},
        "h": {"type": "number"},
        "label": {"type": "string"},
        "kind": {"type": "string"},
        "confidence": {"type": "number"},
        "draft_text": {"type": "string"},
        "say": {"type": "string"},
    },
    "required": ["found", "say"],
}

_KINDS = {"button", "text_field", "link", "tab", "other"}


def _clamp01(value: object, default: float) -> float:
    try:
        v = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default
    if v != v:  # NaN
        return default
    return min(1.0, max(0.0, v))


def normalize_locate_result(raw: object) -> dict[str, object]:
    """Validate + clamp one raw vision result into the wire shape the app
    consumes. Pure and total: any malformed model output becomes a clean
    ``found: false`` (or a clamped hit) rather than an exception, because a
    bad coordinate drawn on someone's screen is worse than no highlight."""
    if not isinstance(raw, dict):
        return {
            "found": False,
            "say": "I could not read that screen. Try asking again.",
        }
    say = str(raw.get("say") or "").strip()[:300]
    if raw.get("found") is not True:
        return {
            "found": False,
            "say": say or "I do not see that on this screen.",
        }
    kind = str(raw.get("kind") or "other").strip().lower()
    if kind not in _KINDS:
        kind = "other"
    confidence = _clamp01(raw.get("confidence"), 0.0)
    result: dict[str, object] = {
        "found": True,
        # Center must stay inside the screen; a hit at the very edge is a
        # misread, but clamping keeps the ring visible and tappable.
        "x": min(0.995, max(0.005, _clamp01(raw.get("x"), 0.5))),
        "y": min(0.995, max(0.005, _clamp01(raw.get("y"), 0.5))),
        # A target smaller than a fingertip is implausible; a target bigger
        # than the whole screen is a misread. Clamp to a sane ring size.
        "w": min(0.9, max(0.02, _clamp01(raw.get("w"), 0.12))),
        "h": min(0.9, max(0.02, _clamp01(raw.get("h"), 0.08))),
        "label": str(raw.get("label") or "").strip()[:80],
        "kind": kind,
        "confidence": confidence,
        "say": say or "Tap the highlighted spot.",
    }
    draft = str(raw.get("draft_text") or "").strip()[:2000]
    if kind == "text_field" and draft:
        result["draft_text"] = draft
    return result


class LocateRequest(BaseModel):
    # One downscaled JPEG/PNG/WebP frame from the live share, base64-encoded.
    # Never persisted server-side (see module docstring).
    image_base64: str = Field(min_length=1, max_length=2_100_000)
    mime: str = Field(default="image/jpeg", max_length=32)
    # What the user wants to do, in their words ("reply to this message",
    # "where do I tap to pay", ...). Voice asks are transcribed on-device /
    # in the voice session before they reach here.
    goal: str = Field(min_length=1, max_length=MAX_GOAL_CHARS)


@router.post("/locate", dependencies=[Depends(require_not_underage_uid)])
async def locate_endpoint(
    req: LocateRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Locate the element the user should tap next for ``goal``.

    Returns normalized coordinates (see :func:`normalize_locate_result`).
    A vision failure is an honest 502 — the app shows "Ayma can't see right
    now" rather than drawing a guessed ring."""
    mime = req.mime.strip().lower()
    if mime not in ALLOWED_MIMES:
        raise HTTPException(status_code=400, detail="Unsupported frame type.")
    try:
        frame = base64.b64decode(req.image_base64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(status_code=400, detail="Bad frame encoding.") from exc
    if not frame or len(frame) > MAX_FRAME_BYTES:
        raise HTTPException(status_code=400, detail="Frame missing or too large.")

    contents = (
        f"The user's goal: {req.goal.strip()}\n\n"
        "Locate the single element they should tap next on this screen."
    )
    try:
        raw = await gemini.generate_json(
            contents,
            _SYSTEM_PROMPT,
            response_schema=_RESPONSE_SCHEMA,
            image=(frame, mime),
            uid=uid,
            feature="copilot_locate",
            temperature=0.1,
        )
    except Exception as exc:  # noqa: BLE001 - surfaced as an honest 502
        logger.warning("copilot vision pass failed: %s: %s", type(exc).__name__, exc)
        raise HTTPException(
            status_code=502, detail="Ayma could not see that screen just now."
        ) from exc
    return normalize_locate_result(raw)
