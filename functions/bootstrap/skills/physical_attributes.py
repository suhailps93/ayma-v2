"""``analyze_physical_attributes`` — build / refresh the caller's structured
physical-profile record (§ physical attributes).

One multi-image vision pass over the user's whole profile photo set (plus any
photo they attached to this chat turn), merged with anything they've explicitly
self-reported. The full ``{value, source, confidence}`` record is written to
``users/{uid}/physical_attributes/current`` and a flat value-only mirror to
``profile/main.physical_attrs``; this returns a short summary for Ayma to relay.

Callable in text chat and voice. Also runs automatically after any profile-photo
change (see ``main.py``), so an explicit call is really just a manual refresh.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and livekit
``function_tool`` awaits it in voice.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import media_embed
import physical_attributes as engine

from ._base import Skill

DESCRIPTION = (
    "Build or refresh the user's structured physical-attributes profile — a "
    "filterable record of apparent race/ethnicity, skin tone, eye and hair "
    "colour/length/type, rough height/weight and build, facial hair, glasses, "
    "visible tattoos/piercings and distinguishing features. Reads all of their "
    "profile photos (and any photo they just attached) and merges in anything "
    "they've stated themselves, which always wins. Call it when the user asks "
    "you to analyse / summarise what they look like or to refresh this profile."
)

DECLARATION = {
    "name": "analyze_physical_attributes",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_PHOTO = (
    "add at least one profile photo and I'll put together your physical profile"
)


def _bind(db, uid: str, *, image_path: str = "") -> Callable[..., Awaitable[str]]:
    async def analyze_physical_attributes() -> str:
        extra: list[tuple[bytes, str]] = []
        if image_path:
            try:
                data, mime = media_embed.download_bytes(image_path)
                if data:
                    extra.append((data, mime or "image/jpeg"))
            except Exception:  # noqa: BLE001 - a bad attachment just isn't used
                extra = []
        record = await engine.refresh(
            db, uid, extra_images=extra or None, persist_report=True
        )
        if not record:
            return _NO_PHOTO
        line = engine.summary(record.get("fields") or {})
        rid = str(record.get("report_id") or "")
        # A trailing [physical:<id>] marker turns the chat turn into a tappable
        # report card (mirrors [deep_dive:<id>] / [face_report:<id>]).
        return f"{line}\n\n[physical:{rid}]" if rid else line

    return analyze_physical_attributes


SKILL = Skill(declaration=DECLARATION, bind=_bind)
