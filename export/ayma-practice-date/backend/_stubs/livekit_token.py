"""Test-only stand-in for Ayma's voice-room seed builder (``livekit_token.py``).

Reproduces ONLY :func:`build_room_seed`: the JSON the agent worker reads from
LiveKit room metadata. The extraction test uses it to prove the voice path's
context-starvation guarantee — that the exact JSON seeded onto a practice voice
room carries no never-load needle and does carry the ``practice`` gate flag. The
real module also mints LiveKit access tokens and attaches metadata to a live
room (LiveKit credentials, not part of this public repo).

NOT the production module. Added to ``sys.path`` only by ``tests/conftest.py``.
"""

from __future__ import annotations

import json


def build_room_seed(
    system_prompt: str,
    recent_turns,
    uid: str,
    session_id: str,
    voice_name: str = "",
    voice_language: str = "",
    greeting_instructions: str = "",
    practice: bool = False,
    persona_name: str = "",
    target_uid: str = "",
) -> str:
    """The room-metadata JSON. For a practice room (``practice=True``),
    ``system_prompt`` is the persona prompt built from the viewer-visible,
    never-load-filtered facts, so this seed never carries a needle."""
    return json.dumps(
        {
            "system_prompt": system_prompt,
            "recent_turns": [
                {"role": getattr(t, "role", t.get("role")),
                 "text": getattr(t, "text", t.get("text"))}
                for t in (recent_turns or [])
            ],
            "uid": uid,
            "session_id": session_id,
            "voice_name": voice_name,
            "voice_language": voice_language,
            "greeting_instructions": greeting_instructions,
            "practice": practice,
            "persona_name": persona_name,
            "target_uid": target_uid,
        }
    )
