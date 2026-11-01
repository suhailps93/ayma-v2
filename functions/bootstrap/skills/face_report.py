"""``face_report`` — an honest facial-beauty analysis of a photo the user
shared in this chat (§ face report).

Runs only when the user explicitly asks Ayma to analyse / rate / review a face
in a photo they have sent. It grabs the most recent chat image, runs the
:mod:`face_report` engine, stores the full report under
``users/{uid}/face_reports/{id}``, and returns a short summary plus a
``[face_report:<id>]`` sentinel line the client can detect to open the full
in-app report view.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and livekit
``function_tool`` awaits it in voice.

The turn flow is shared with :mod:`skills.body_report` via
:mod:`skills._photo`; this module is the face declaration, copy and spec.
"""

from __future__ import annotations

import face_report as engine
import skill_memory
import skill_runs
import token_ledger

from ._base import Skill
from ._base import latest_chat_image as _latest_chat_image  # noqa: F401
from ._photo import PhotoSkillSpec, bind_photo_skill

# ``_latest_chat_image`` is re-exported: ``generate_image`` + its tests use
# ``face_report._latest_chat_image`` (the single implementation lives in
# ``skills._base``).


DESCRIPTION = (
    "Honest facial-beauty analysis of the photo the user shared in this chat "
    "— only on an explicit ask for a face rating/review."
)

DECLARATION = {
    "name": "face_report",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_IMAGE = "share a clear photo of the face first and I'll take a look"

SPEC = PhotoSkillSpec(
    engine=engine,
    no_image=_NO_IMAGE,
    out_of_credits_context=token_ledger.CONTEXT_FACE_REPORT,
    save_analysis=skill_memory.save_face_analysis,
    skill_run_kind=skill_runs.FACE_REPORT,
    collection="face_reports",
    name="face_report",
)

SKILL = Skill(declaration=DECLARATION, bind=bind_photo_skill(SPEC))
