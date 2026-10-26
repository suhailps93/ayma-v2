"""Region blocking for ``deepdive_blocked_regions``.

The flag lists region keys (default ``illinois,texas,eu``). Each key maps, in
``region_data.json``, to place names (state/country, major cities, alternate
spellings) and two-letter codes. A free-text location such as ``"Chicago"``,
``"Paris, France"`` or ``"Austin TX"`` is normalised (case, accents,
punctuation) and matched on whole words, so ``"Chicago"`` blocks ``illinois``
and ``"Paris, France"`` blocks ``eu`` without the person typing the region.

A flag token that is not a key in the mapping still works as a plain
whole-word phrase. An empty or unrecognised location is allowed (the member's
biometric consent is already required upstream) but is logged, without the
location text.
"""

from __future__ import annotations

import json
import logging
import re
import unicodedata
from functools import lru_cache
from pathlib import Path

logger = logging.getLogger("ayma.region_block")

_DATA_PATH = Path(__file__).with_name("region_data.json")
_SEGMENT_SPLIT_RE = re.compile(r"[,;/|\n]+")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")


def normalise(text: str) -> str:
    """Lower-cased, accent-stripped, punctuation-free, single-spaced text."""
    folded = unicodedata.normalize("NFKD", text or "")
    ascii_text = "".join(c for c in folded if not unicodedata.combining(c))
    return _NON_ALNUM_RE.sub(" ", ascii_text.lower()).strip()


@lru_cache(maxsize=1)
def _regions() -> dict[str, dict]:
    raw = json.loads(_DATA_PATH.read_text(encoding="utf-8"))
    return {k: v for k, v in raw.items() if isinstance(v, dict)}


def _has_phrase(padded: str, phrase: str) -> bool:
    return f" {normalise(phrase)} " in padded


def _code_hit(location: str, codes: list[str]) -> bool:
    """A code only counts as the trailing part of a multi-part location
    ("Chicago, IL", "Austin TX"), never as a stray word."""
    wanted = {c.lower() for c in codes}
    segments = [normalise(s) for s in _SEGMENT_SPLIT_RE.split(location or "")]
    segments = [s for s in segments if s]
    if len(segments) > 1 and segments[-1] in wanted:
        return True
    if len(segments) > 1 and any(s in wanted for s in segments[1:]):
        return True
    words = segments[-1].split() if segments else []
    return len(words) > 1 and words[-1] in wanted


def _matches(location: str, key: str) -> bool:
    spec = _regions().get(key)
    if spec is None:
        return _has_phrase(f" {normalise(location)} ", key)
    padded = f" {normalise(location)} "
    for phrase in spec.get("exclude", []):
        padded = padded.replace(f" {normalise(phrase)} ", " ")
    if any(_has_phrase(padded, name) for name in spec.get("names", [])):
        return True
    return _code_hit(location, spec.get("codes", []))


def is_blocked(location: str, blocked_regions) -> bool:
    """Whether ``location`` falls in any region key of ``blocked_regions``."""
    keys = [str(k).strip().lower() for k in blocked_regions if str(k).strip()]
    if not normalise(location):
        logger.info("region check: location empty; treated as allowed")
        return False
    if any(_matches(location, k) for k in keys):
        return True
    if not any(_matches(location, k) for k in _regions()):
        logger.info("region check: location not recognised; treated as allowed")
    return False
