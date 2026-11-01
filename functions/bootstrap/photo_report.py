"""Shared base for the scored photo-report engines (sweep finding BE-#2).

:mod:`face_report` and :mod:`body_report` were ~320-line clones — the same
``_num`` / ``_normalize_images`` / ``run`` / ``render`` / ``teaser`` skeleton
with different prompt files, response schemas, credit-ledger features and
user-facing strings, so every fix had to land twice. The skeleton lives here,
parameterized by :class:`Spec`; the two engines are thin specs plus their own
docstrings.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import report_blocks as rb
from llm_provider import get_vision_provider
from prompt import load_prompt_sections

_PROMPTS_DIR = Path(__file__).with_name("prompts")

_VISION_GROUP = "reports"


@dataclass(frozen=True)
class Spec:
    """Everything that differs between the face and body engines."""

    key: str  # "face" | "body" — report_blocks id_prefix
    prompt_file: str  # "face_report.md" under prompts/
    feature_names: str  # "symmetry | proportions | ..." (schema description)
    reco_categories: str  # "skincare | ..." (schema description)
    quick_fact_keys: tuple[str, ...]
    ledger_feature: str  # token_ledger feature id the run is metered under
    not_usable: str  # full-length "send a clearer photo" text
    teaser_fallback: str  # "Here's your facial-beauty report."


def _sections(spec: Spec) -> dict[str, str]:
    return load_prompt_sections(_PROMPTS_DIR / spec.prompt_file)


def schema_for(spec: Spec) -> dict:
    """The vision-call response schema for ``spec``.

    Built fresh per spec (the engines each hold theirs as module-level
    ``_SCHEMA``, exactly as before the merge); the skeleton is shared, the
    feature names, recommendation categories and quick-fact keys come from
    the spec.
    """
    feature_schema = {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
                "description": spec.feature_names,
            },
            "score": {"type": "number", "description": "0-10"},
            "note": {"type": "string", "description": "one specific observation"},
        },
        "required": ["name", "score", "note"],
    }
    reco_schema = {
        "type": "object",
        "properties": {
            "category": {
                "type": "string",
                "description": spec.reco_categories,
            },
            "text": {"type": "string"},
        },
        "required": ["category", "text"],
    }
    return {
        "type": "object",
        "properties": {
            "usable": {"type": "boolean"},
            "overall_score": {"type": "number", "description": "0-10"},
            "verdict": {"type": "string", "description": 'e.g. "Above average"'},
            "verdict_note": {"type": "string", "description": "one sentence"},
            "features": {"type": "array", "items": feature_schema},
            "quick_facts": {
                "type": "object",
                "properties": {k: {"type": "string"} for k in spec.quick_fact_keys},
            },
            "strengths": {"type": "array", "items": {"type": "string"}},
            "improvements": {"type": "array", "items": {"type": "string"}},
            "recommendations": {"type": "array", "items": reco_schema},
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
    spec: Spec,
    image_or_images,
    mime_type: str | None = None,
    *,
    uid: str | None = None,
    source_path: str | None = None,
) -> dict:
    """Analyse one or more photos OF THE SAME PERSON in ONE combined vision
    call and return the structured report dict (``usable``, ``overall_score``,
    ``verdict``, ``features``, ``quick_facts``, ``strengths``,
    ``improvements``, ``recommendations``, ``source_photos``).

    Two call forms (see the engines' own ``run`` docstrings for the
    per-engine detail): single image
    ``run(image_bytes, mime_type, uid=…, source_path=…)`` and multi image
    ``run([(bytes, mime, path), …], uid=…)``.

    Every analysed photo's Storage path is echoed back as ``source_photos``
    so every reader can tell which photos produced the report. An entry with
    no path contributes nothing to that list; no identifiable photo at all
    -> an empty list.

    Raises ``ValueError`` when no usable image bytes are given. Metered to
    ``uid`` under the spec's ledger feature; a cap hit propagates
    ``TokenCapExceeded``.
    """
    images = _normalize_images(image_or_images, mime_type, source_path)
    if not images:
        raise ValueError("an image is required")

    sections = _sections(spec)
    report = await get_vision_provider(_VISION_GROUP).generate_json(
        sections["instruction"],
        system_prompt=sections["system"],
        response_schema=schema_for(spec),
        images=[(data, mime) for data, mime, _p in images],
        uid=uid,
        feature=spec.ledger_feature,
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
            k: str(quick.get(k, "")).strip() for k in spec.quick_fact_keys
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


def render(spec: Spec, report: dict) -> str:
    """A short markdown summary of a :func:`run` result for the chat
    transcript. If the photo was unusable, ask for a better one."""
    if not report.get("usable", True):
        return spec.not_usable

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


def teaser(spec: Spec, report: dict) -> str:
    """A one-line chat pointer at a stored report — never the score, verdict,
    or findings themselves (those live in the report view; a chat message
    announcing a finished report should be a teaser + link, not the report's
    contents dumped inline).

    The "is this usable" check is :func:`report_blocks.scored_result_blocks`'s
    — the same one ``report_adapters``'s Appearance adapter uses for this
    exact result shape — rather than a second, independently-maintained copy
    of it living here (§ founder: converge the drifted face/body/deep-dive
    ``teaser()`` functions)."""
    blocks = rb.scored_result_blocks(
        report, id_prefix=spec.key, not_usable_text=spec.not_usable
    )
    if blocks and blocks[0]["type"] == rb.SECTION_HEAD:
        return blocks[0]["text"]
    return spec.teaser_fallback
