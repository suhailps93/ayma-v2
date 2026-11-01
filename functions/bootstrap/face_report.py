"""Honest, data-driven facial-beauty report from one or more photos
(§ face report).

ONE vision call turns the photo(s) the user shared into a single structured
report — an overall 0-10 score and a verdict, a per-feature breakdown
(symmetry, proportions, skin, eyes, nose, …), quick facts, and concrete
strengths / improvements / recommendations. When several photos are given they
are all of the SAME person (different angles/lighting/moments) and are
reconciled into ONE combined read — never treated as different people. The
engine is candid by design: the prompt asks for specific, unflattering
observations, not compliments.

Two callers:

* the ``face_report`` skill — the user asks Ayma in chat to rate a face in a
  photo they just sent; the digest is rendered back into the transcript.
* ``POST /face-report`` — the Profile-tab entry point; runs on the user's
  primary profile photo (or an attachment) and returns the full dict for the
  in-app report view.
* the Appearance report (:mod:`appearance`) — passes ALL the face photos the
  user ticked in the pre-run sheet for one combined read.

Prompts live in ``prompts/face_report.md`` (``## system`` / ``## instruction``
sections), loaded dynamically — never inline (AGENTS.md).

The engine skeleton (vision call, normalization, render, teaser) is shared
with :mod:`body_report` via :mod:`photo_report`; this module is the face
spec plus its own docstrings.
"""

from __future__ import annotations

import photo_report
import token_ledger

SPEC = photo_report.Spec(
    key="face",
    prompt_file="face_report.md",
    feature_names=(
        "symmetry | proportions | bone_structure | skin_quality | eyes | "
        "brows | nose | lips | facial_hair | hair"
    ),
    reco_categories=(
        "skincare | under_eye | beard_grooming | hair_styling | lifestyle"
    ),
    quick_fact_keys=(
        "face_shape",
        "age_estimate",
        "facial_hair_density",
        "hair_thickness",
        "skin_undertone",
        "best_feature",
        "worst_feature",
    ),
    ledger_feature=token_ledger.FEATURE_FACE_REPORT,
    not_usable=(
        "I can't get a clean read on that photo — send a clearer, "
        "front-facing shot with your whole face in frame and I'll take "
        "a proper look."
    ),
    teaser_fallback="Here's your facial-beauty report.",
)

_SCHEMA = photo_report.schema_for(SPEC)

_QUICK_FACT_KEYS = SPEC.quick_fact_keys

_NOT_USABLE = SPEC.not_usable


async def run(
    image_or_images,
    mime_type: str | None = None,
    *,
    uid: str | None = None,
    source_path: str | None = None,
) -> dict:
    """Analyse one or more photos OF THE SAME PERSON in ONE combined vision
    call and return the structured report dict (``usable``, ``overall_score``,
    ``verdict``, ``features``, ``quick_facts``, ``strengths``, ``improvements``,
    ``recommendations``, ``source_photos``).

    Two call forms:

    * single image (legacy/chat/auto path):
      ``run(image_bytes, mime_type, uid=…, source_path=…)``;
    * multi image (the Appearance pre-run sheet's ticked set):
      ``run([(bytes, mime, path), …], uid=…)`` — every photo is the same
      person; they are reconciled into ONE report, not treated as different
      people.

    Every analysed photo's Storage path (the ``path`` of each entry, or
    ``source_path`` in the single form) is echoed back as ``source_photos`` so
    every reader can tell which photos produced the report without threading a
    second value alongside it. An entry with no path contributes nothing to
    that list; no identifiable photo at all -> an empty list.

    Raises ``ValueError`` when no usable image bytes are given. Metered to
    ``uid`` under the ``face_report`` feature; a cap hit propagates
    ``TokenCapExceeded``.
    """
    return await photo_report.run(
        SPEC, image_or_images, mime_type, uid=uid, source_path=source_path
    )


def render(report: dict) -> str:
    """A short markdown summary of a :func:`run` result for the chat
    transcript. If the photo was unusable, ask for a better one."""
    return photo_report.render(SPEC, report)


def teaser(report: dict) -> str:
    """A one-line chat pointer at a stored report — never the score, verdict,
    or findings themselves (those live in the report view; a chat message
    announcing a finished report should be a teaser + link, not the report's
    contents dumped inline).

    The "is this usable" check is :func:`report_blocks.scored_result_blocks`'s
    — the same one ``report_adapters``'s Appearance adapter uses for this
    exact result shape — rather than a second, independently-maintained copy
    of it living here (§ founder: converge the drifted face/body/deep-dive
    ``teaser()`` functions)."""
    return photo_report.teaser(SPEC, report)
