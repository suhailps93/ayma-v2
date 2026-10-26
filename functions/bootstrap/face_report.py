"""Honest, data-driven facial-beauty report from a single photo (§ face report).

One Gemini **vision** call turns a photo the user shared into a structured
report — an overall 0-10 score and a verdict, a per-feature breakdown
(symmetry, proportions, skin, eyes, nose, …), quick facts, and concrete
strengths / improvements / recommendations. The engine is candid by design:
the prompt asks for specific, unflattering observations, not compliments.

Two callers:

* the ``face_report`` skill — the user asks Ayma in chat to rate a face in a
  photo they just sent; the digest is rendered back into the transcript.
* ``POST /face-report`` — the Profile-tab entry point; runs on the user's
  primary profile photo (or an attachment) and returns the full dict for the
  in-app report view.
"""

from __future__ import annotations

import logging

import gemini
import report_blocks as rb
import token_ledger
from llm_provider import get_llm_provider

logger = logging.getLogger("ayma.facereport")

_SYSTEM = (
    "You are a facial-analysis reviewer producing an honest, data-driven "
    "facial beauty report from a single photo. Be candid and specific — not "
    "flattering. Base every observation on what is visible in the image. Score "
    "on a 0-10 scale where 5 is average; reserve 8+ for genuinely exceptional "
    "features. Name concrete things (a slight chin asymmetry, under-eye "
    "shadowing, uneven brow density) rather than vague praise. If the photo is "
    "unusable — no clear face, heavy occlusion, extreme angle or blur — set "
    "`usable` to false and leave the analysis fields minimal."
)

_INSTRUCTION = (
    "Analyse the face in this photo and return the structured report. Give an "
    "`overall_score` (0-10, one decimal is fine) and a short `verdict` such as "
    "\"Above average\" with a one-sentence `verdict_note`. Score each visible "
    "feature (symmetry, proportions, bone_structure, skin_quality, eyes, "
    "brows, nose, lips, facial_hair, hair) with a 0-10 `score` and a specific "
    "`note`; skip `facial_hair` if there is none. Fill `quick_facts` "
    "(face_shape, age_estimate, facial_hair_density, hair_thickness, "
    "skin_undertone, best_feature, worst_feature). List honest `strengths` and "
    "`improvements`, and concrete `recommendations` tagged by category "
    "(skincare, under_eye, beard_grooming, hair_styling, lifestyle). Do not be "
    "kind for its own sake — a useful report is an accurate one."
)

_FEATURE_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {
            "type": "string",
            "description": "symmetry | proportions | bone_structure | "
            "skin_quality | eyes | brows | nose | lips | facial_hair | hair",
        },
        "score": {"type": "number", "description": "0-10"},
        "note": {"type": "string", "description": "one specific observation"},
    },
    "required": ["name", "score", "note"],
}

_RECO_SCHEMA = {
    "type": "object",
    "properties": {
        "category": {
            "type": "string",
            "description": "skincare | under_eye | beard_grooming | "
            "hair_styling | lifestyle",
        },
        "text": {"type": "string"},
    },
    "required": ["category", "text"],
}

_SCHEMA = {
    "type": "object",
    "properties": {
        "usable": {"type": "boolean"},
        "overall_score": {"type": "number", "description": "0-10"},
        "verdict": {"type": "string", "description": 'e.g. "Above average"'},
        "verdict_note": {"type": "string", "description": "one sentence"},
        "features": {"type": "array", "items": _FEATURE_SCHEMA},
        "quick_facts": {
            "type": "object",
            "properties": {
                "face_shape": {"type": "string"},
                "age_estimate": {"type": "string"},
                "facial_hair_density": {"type": "string"},
                "hair_thickness": {"type": "string"},
                "skin_undertone": {"type": "string"},
                "best_feature": {"type": "string"},
                "worst_feature": {"type": "string"},
            },
        },
        "strengths": {"type": "array", "items": {"type": "string"}},
        "improvements": {"type": "array", "items": {"type": "string"}},
        "recommendations": {"type": "array", "items": _RECO_SCHEMA},
    },
    "required": [
        "usable",
        "overall_score",
        "verdict",
        "features",
        "strengths",
        "improvements",
        "recommendations",
    ],
}

_QUICK_FACT_KEYS = (
    "face_shape",
    "age_estimate",
    "facial_hair_density",
    "hair_thickness",
    "skin_undertone",
    "best_feature",
    "worst_feature",
)


def _num(value, default: float = 0.0) -> float:
    try:
        return round(float(value), 1)
    except (TypeError, ValueError):
        return default


async def run(
    image_bytes: bytes,
    mime_type: str,
    *,
    uid: str | None = None,
    source_path: str | None = None,
) -> dict:
    """Analyse ``image_bytes`` and return the structured report dict
    (``usable``, ``overall_score``, ``verdict``, ``features``, ``quick_facts``,
    ``strengths``, ``improvements``, ``recommendations``, ``source_photos``).

    ``source_path`` — the Storage path the caller read ``image_bytes`` from, if
    any — is echoed back as ``source_photos`` (a one-item list, kept a list for
    shape-consistency with the multi-photo reports) so every reader of the
    returned dict can tell which photo produced it without threading a second
    value alongside it. ``None``/``""`` when the caller has no path (e.g. bytes
    that never touched Storage) -> an empty list.

    Raises ``ValueError`` for empty bytes. Metered to ``uid`` under the
    ``face_report`` feature; a cap hit propagates ``TokenCapExceeded``.
    """
    if not image_bytes:
        raise ValueError("an image is required")
    mime_type = (mime_type or "image/jpeg").strip() or "image/jpeg"

    report = await get_llm_provider("reports").generate_json(
        _INSTRUCTION,
        system_prompt=_SYSTEM,
        response_schema=_SCHEMA,
        image=(image_bytes, mime_type),
        uid=uid,
        feature=token_ledger.FEATURE_FACE_REPORT,
    )
    if not isinstance(report, dict):
        report = {}

    quick = report.get("quick_facts")
    quick = quick if isinstance(quick, dict) else {}

    return {
        "usable": bool(report.get("usable", True)),
        "overall_score": _num(report.get("overall_score")),
        "verdict": str(report.get("verdict", "")).strip(),
        "verdict_note": str(report.get("verdict_note", "")).strip(),
        "features": [
            {
                "name": str(f.get("name", "")).strip(),
                "score": _num(f.get("score")),
                "note": str(f.get("note", "")).strip(),
            }
            for f in (report.get("features") or [])
            if isinstance(f, dict) and f.get("name")
        ],
        "quick_facts": {
            k: str(quick.get(k, "")).strip() for k in _QUICK_FACT_KEYS
        },
        "strengths": [
            str(s).strip()
            for s in (report.get("strengths") or [])
            if str(s).strip()
        ],
        "improvements": [
            str(s).strip()
            for s in (report.get("improvements") or [])
            if str(s).strip()
        ],
        "recommendations": [
            {
                "category": str(r.get("category", "")).strip(),
                "text": str(r.get("text", "")).strip(),
            }
            for r in (report.get("recommendations") or [])
            if isinstance(r, dict) and r.get("text")
        ],
        "source_photos": [source_path] if source_path else [],
    }


def render(report: dict) -> str:
    """A short markdown summary of a :func:`run` result for the chat
    transcript. If the photo was unusable, ask for a better one."""
    if not report.get("usable", True):
        return (
            "I can't get a clean read on that photo — send a clearer, "
            "front-facing shot with your whole face in frame and I'll take "
            "a proper look."
        )

    score = report.get("overall_score", 0)
    verdict = report.get("verdict", "").strip()
    head = f"**{score}/10**" + (f" — {verdict}" if verdict else "")
    lines = [head]
    if report.get("verdict_note"):
        lines.append(report["verdict_note"].strip())

    strengths = [s for s in (report.get("strengths") or []) if s][:3]
    if strengths:
        lines.append("")
        lines.append("**Working for you**")
        lines.extend(f"- {s}" for s in strengths)

    improvements = [s for s in (report.get("improvements") or []) if s][:3]
    if improvements:
        lines.append("")
        lines.append("**Worth working on**")
        lines.extend(f"- {s}" for s in improvements)

    return "\n".join(lines).strip()


_NOT_USABLE = (
    "I can't get a clean read on that photo — send a clearer, "
    "front-facing shot with your whole face in frame and I'll take "
    "a proper look."
)


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
    blocks = rb.scored_result_blocks(report, id_prefix="face", not_usable_text=_NOT_USABLE)
    if blocks and blocks[0]["type"] == rb.SECTION_HEAD:
        return blocks[0]["text"]
    return "Here's your facial-beauty report."
