"""Honest, data-driven physique report from a single photo (§ body report).

The body-photo counterpart to :mod:`face_report`. One Gemini **vision** call
turns a full- or upper-body photo the user shared into a structured report — an
overall 0-10 score and a verdict, a per-feature breakdown (frame, proportions,
posture, muscularity, leanness, …), quick facts, and concrete strengths /
improvements / recommendations. Candid by design: the prompt asks for specific,
unflattering observations, not compliments.

Two callers:

* the ``body_report`` skill — the user asks Ayma in chat to rate a physique in
  a photo they just sent; the digest is rendered back into the transcript.
* ``POST /body-report`` — the Profile-tab entry point; runs on the user's
  primary profile photo (or an attachment) and returns the full dict for the
  in-app report view.
"""

from __future__ import annotations

import logging

import gemini
import token_ledger

logger = logging.getLogger("ayma.bodyreport")

_SYSTEM = (
    "You are a physique-analysis reviewer producing an honest, data-driven "
    "body report from a single photo. Be candid and specific — not "
    "flattering. Base every observation on what is visible in the image. Score "
    "on a 0-10 scale where 5 is average; reserve 8+ for a genuinely "
    "exceptional physique. Name concrete things (rounded shoulders, a soft "
    "midsection, underdeveloped calves, a narrow clavicle frame) rather than "
    "vague praise. If the photo is unusable — no clear full or upper body, "
    "heavy occlusion, baggy clothing that hides the figure, extreme angle or "
    "blur — set `usable` to false and leave the analysis fields minimal."
)

_INSTRUCTION = (
    "Analyse the physique in this photo and return the structured report. "
    "Give an `overall_score` (0-10, one decimal is fine) and a short "
    "`verdict` such as \"Above average\" with a one-sentence `verdict_note`. "
    "Score each visible feature (frame, proportions, posture, muscularity, "
    "leanness, symmetry, v_taper, skin_and_grooming, presence) with a 0-10 "
    "`score` and a specific `note`. Fill `quick_facts` (body_type, "
    "est_height_impression, build, estimated_body_fat_range, "
    "dominant_strength, weakest_area, frame_size). List honest `strengths` and "
    "`improvements`, and concrete `recommendations` tagged by category "
    "(training, nutrition, posture, styling, recovery). Do not be kind for its "
    "own sake — a useful report is an accurate one."
)

_FEATURE_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {
            "type": "string",
            "description": "frame | proportions | posture | muscularity | "
            "leanness | symmetry | v_taper | skin_and_grooming | presence",
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
            "description": "training | nutrition | posture | styling | "
            "recovery",
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
                "body_type": {"type": "string"},
                "est_height_impression": {"type": "string"},
                "build": {"type": "string"},
                "estimated_body_fat_range": {"type": "string"},
                "dominant_strength": {"type": "string"},
                "weakest_area": {"type": "string"},
                "frame_size": {"type": "string"},
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
    "body_type",
    "est_height_impression",
    "build",
    "estimated_body_fat_range",
    "dominant_strength",
    "weakest_area",
    "frame_size",
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
) -> dict:
    """Analyse ``image_bytes`` and return the structured report dict
    (``usable``, ``overall_score``, ``verdict``, ``features``, ``quick_facts``,
    ``strengths``, ``improvements``, ``recommendations``).

    Raises ``ValueError`` for empty bytes. Metered to ``uid`` under the
    ``body_report`` feature; a cap hit propagates ``TokenCapExceeded``.
    """
    if not image_bytes:
        raise ValueError("an image is required")
    mime_type = (mime_type or "image/jpeg").strip() or "image/jpeg"

    report = await gemini.generate_json(
        _INSTRUCTION,
        system_prompt=_SYSTEM,
        response_schema=_SCHEMA,
        image=(image_bytes, mime_type),
        uid=uid,
        feature=token_ledger.FEATURE_BODY_REPORT,
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
    }


def render(report: dict) -> str:
    """A short markdown summary of a :func:`run` result for the chat
    transcript. If the photo was unusable, ask for a better one."""
    if not report.get("usable", True):
        return (
            "I can't get a clean read on that photo — send a clearer, "
            "full-length shot in fitted clothing and I'll take a proper look."
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
