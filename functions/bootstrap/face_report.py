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
"""

from __future__ import annotations

import logging
import re
from functools import lru_cache
from pathlib import Path

import gemini
import report_blocks as rb
import token_ledger
from llm_provider import get_vision_provider

logger = logging.getLogger("ayma.facereport")

_PROMPTS_PATH = Path(__file__).with_name("prompts") / "face_report.md"


@lru_cache(maxsize=1)
def _prompt_sections() -> dict[str, str]:
    """The ``## name`` sections of ``prompts/face_report.md``."""
    text = _PROMPTS_PATH.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    key: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^##\s+([\w-]+)\s*$", line)
        if m:
            if key is not None:
                out[key] = "\n".join(buf).strip()
            key, buf = m.group(1), []
        elif key is not None:
            buf.append(line)
    if key is not None:
        out[key] = "\n".join(buf).strip()
    return out


def _system() -> str:
    return _prompt_sections()["system"]


def _instruction() -> str:
    return _prompt_sections()["instruction"]

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


def _normalize_images(
    image_or_images, mime_type: str | None, source_path: str | None
) -> list[tuple[bytes, str, str]]:
    """Coerce either call form into a ``[(bytes, mime, path), …]`` list:

    * single image (legacy): ``run(image_bytes, mime_type, source_path=…)``;
    * multi image: ``run([(bytes, mime, path), …])`` — all the SAME person.

    Drops any entry with empty bytes; defaults a blank mime to ``image/jpeg``.
    """
    if isinstance(image_or_images, (bytes, bytearray)):
        if not image_or_images:
            return []
        mime = (mime_type or "image/jpeg").strip() or "image/jpeg"
        return [(bytes(image_or_images), mime, source_path or "")]
    out: list[tuple[bytes, str, str]] = []
    for item in image_or_images or []:
        data = item[0]
        if not data:
            continue
        mime = (item[1] if len(item) > 1 else None) or "image/jpeg"
        mime = str(mime).strip() or "image/jpeg"
        path = str(item[2]).strip() if len(item) > 2 and item[2] else ""
        out.append((bytes(data), mime, path))
    return out


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
    images = _normalize_images(image_or_images, mime_type, source_path)
    if not images:
        raise ValueError("an image is required")

    report = await get_vision_provider("reports").generate_json(
        _instruction(),
        system_prompt=_system(),
        response_schema=_SCHEMA,
        images=[(data, mime) for data, mime, _p in images],
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
        "source_photos": [p for _d, _m, p in images if p],
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
