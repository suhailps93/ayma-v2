"""Loader for ``wiki_schema.json`` (ARCHITECTURE.md §2.7, §2.8 step 2).

The schema — page types, id conventions, visibility defaults, update rules —
lives as static JSON config in the repo and is read here rather than hardcoded
inline. Step 20 only exposes it; the ingest pipeline that consumes it is
Step 21.
"""

from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path

_SCHEMA_PATH = Path(__file__).with_name("wiki_schema.json")


@lru_cache(maxsize=1)
def load_wiki_schema() -> dict:
    return json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def page_types() -> tuple[str, ...]:
    return tuple(pt["type"] for pt in load_wiki_schema()["page_types"])


@lru_cache(maxsize=1)
def _page_id_re() -> re.Pattern[str]:
    return re.compile(load_wiki_schema()["page_id"]["pattern"])


def visibility_values() -> tuple[str, ...]:
    return tuple(load_wiki_schema()["visibility"]["values"])


def default_visibility_for(page_type: str) -> str:
    for pt in load_wiki_schema()["page_types"]:
        if pt["type"] == page_type:
            return pt["default_visibility"]
    return load_wiki_schema()["visibility"]["default"]


def is_valid_page_id(page_id: str) -> bool:
    schema = load_wiki_schema()
    return (
        0 < len(page_id) <= schema["page_id"]["max_length"]
        and bool(_page_id_re().fullmatch(page_id))
    )
