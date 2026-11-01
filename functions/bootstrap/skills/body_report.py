"""``body_report`` — an honest physique analysis of a body photo the user
shared in this chat (§ body report).

The body-photo counterpart to :mod:`skills.face_report`. Runs only when the
user explicitly asks Ayma to analyse / rate / review a physique in a photo they
have sent. It grabs the most recent chat image, runs the :mod:`body_report`
engine, stores the full report under ``users/{uid}/body_reports/{id}``, and
returns a short summary plus a ``[body_report:<id>]`` sentinel line the client
can detect to open the full in-app report view.

The turn flow is shared with :mod:`skills.face_report` via
:mod:`skills._photo`; this module is the body declaration, copy and spec.
"""

from __future__ import annotations

import body_report as engine
import skill_memory
import skill_runs
import token_ledger

from ._base import Skill
from ._photo import PhotoSkillSpec, bind_photo_skill

DESCRIPTION = (
    "Honest physique analysis of the body photo the user shared in this chat "
    "— only on an explicit ask for a body/physique rating/review."
)

DECLARATION = {
    "name": "body_report",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_IMAGE = "share a clear photo with your upper body or more first and I'll take a look"

SPEC = PhotoSkillSpec(
    engine=engine,
    no_image=_NO_IMAGE,
    out_of_credits_context=token_ledger.CONTEXT_BODY_REPORT,
    save_analysis=skill_memory.save_body_analysis,
    skill_run_kind=skill_runs.BODY_REPORT,
    collection="body_reports",
    name="body_report",
)

SKILL = Skill(declaration=DECLARATION, bind=bind_photo_skill(SPEC))
