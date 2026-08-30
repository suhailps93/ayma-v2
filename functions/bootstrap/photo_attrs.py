"""Photo-derived attribute extraction (ARCHITECTURE.md §6.3, §6.11 step 3).

At profile-photo upload, alongside the face embedding (§2.5), a vision pass
pulls observable attributes and stores them as structured, filterable fields on
``users/{uid}/profile/main`` under ``photo_attrs``. Low-confidence by design:
"unknown" is a first-class value.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

import gemini

logger = logging.getLogger("ayma.media")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "photo_attributes.md"
_SCHEMA_PATH = Path(__file__).with_name("explore_filter_schema.json")


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def _response_schema() -> dict:
    fields = json.loads(_SCHEMA_PATH.read_text())["photo_attributes"]
    props = {}
    for f in fields:
        if f["type"] == "enum":
            props[f["field"]] = {"type": "string", "enum": f["values"]}
        else:
            props[f["field"]] = {"type": "string"}
    return {
        "type": "object",
        "properties": props,
        "required": list(props),
    }


@lru_cache(maxsize=1)
def attribute_fields() -> tuple[str, ...]:
    return tuple(
        f["field"]
        for f in json.loads(_SCHEMA_PATH.read_text())["photo_attributes"]
    )


async def extract_attributes(image_bytes: bytes, mime_type: str) -> dict:
    """Return the §6.3 attribute map for a photo. On any failure returns all
    ``"unknown"`` so callers stay best-effort."""
    unknown = {f: "unknown" for f in attribute_fields()}
    try:
        result = await gemini.generate_json(
            "Extract the profile-photo attributes.",
            system_prompt=_prompt(),
            response_schema=_response_schema(),
            image=(image_bytes, mime_type),
        )
    except Exception:  # noqa: BLE001
        logger.exception("photo attribute extraction failed")
        return unknown
    if not isinstance(result, dict):
        return unknown
    return {f: str(result.get(f, "unknown")) or "unknown" for f in attribute_fields()}
