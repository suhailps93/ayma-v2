"""The generic, shared block-content model every report type (Appearance,
deep-dive/web-search, Story) is adapted into (§ generic reports).

A report is ``{title, sections: [{heading, blocks: [...]}]}``. Every block
carries a stable ``block_id`` — unique within its report, chosen by each
adapter (see ``report_adapters.py``) so it can be parsed back into whatever
the producer needs to route a correction (a ``physical_attributes`` field
name, a deep-dive ``fact:<id>`` target, a Story ``page:<id>:sent:<n>``
locator, ...). This module knows nothing about any specific report type —
it's pure shape + a couple of small, deliberately unclever helpers (sentence
splitting, teaser extraction) that every adapter can reuse.

Block types are small and fixed:

* ``text``       — one paragraph/sentence of prose. Sentence-level, so a
  client can let someone tap ONE sentence rather than a whole blob.
* ``fact``       — a bullet/claim, optionally tagged with a category and a
  confidence (mirrors deep-dive's existing ``facts``).
* ``attribute``  — a key/value pair, optionally sourced (``stated`` /
  ``inferred``/``photo``) and confidence-scored (mirrors Appearance's
  structured fields).
* ``photo``      — one image.
* ``photo_grid`` — several images shown together.
* ``link``       — a social profile / citation URL.
* ``stat``       — a score/number with an optional label and basis
  (Appearance's overall score, a face/body verdict, ...).
* ``section_head`` — a plain heading/status line with no other payload
  (e.g. "needs a face photo yet") — content, not a correction target.

Every block dict also carries ``editable: bool`` — whether tapping it and
asking Ayma to change something is expected to resolve to a real mutation
(``report_hub.py`` still enforces ownership server-side regardless; this is
purely a client-side hint so a non-correctable block, e.g. a raw citation
link, doesn't invite a tap that can only ever fail).
"""

from __future__ import annotations

import re
from typing import Any

# --- block types --------------------------------------------------------

TEXT = "text"
FACT = "fact"
ATTRIBUTE = "attribute"
PHOTO = "photo"
PHOTO_GRID = "photo_grid"
LINK = "link"
STAT = "stat"
SECTION_HEAD = "section_head"

ALL_TYPES = (TEXT, FACT, ATTRIBUTE, PHOTO, PHOTO_GRID, LINK, STAT, SECTION_HEAD)


def _block(block_id: str, type_: str, *, editable: bool, **fields: Any) -> dict:
    out = {"block_id": str(block_id), "type": type_, "editable": bool(editable)}
    out.update({k: v for k, v in fields.items() if v is not None})
    return out


def text_block(block_id: str, text: str, *, editable: bool = True) -> dict:
    return _block(block_id, TEXT, editable=editable, text=str(text or ""))


def fact_block(
    block_id: str,
    text: str,
    *,
    tag: str = "",
    confidence: str = "",
    editable: bool = True,
) -> dict:
    return _block(
        block_id, FACT, editable=editable,
        text=str(text or ""), tag=str(tag or ""), confidence=str(confidence or ""),
    )


def attribute_block(
    block_id: str,
    label: str,
    value: Any,
    *,
    source: str = "",
    confidence: str = "",
    editable: bool = True,
) -> dict:
    return _block(
        block_id, ATTRIBUTE, editable=editable,
        label=str(label or ""), value=value,
        source=str(source or ""), confidence=str(confidence or ""),
    )


def photo_block(
    block_id: str,
    url: str,
    *,
    caption: str = "",
    verified: bool | None = None,
    editable: bool = False,
) -> dict:
    return _block(
        block_id, PHOTO, editable=editable,
        url=str(url or ""), caption=str(caption or ""), verified=verified,
    )


def photo_grid_block(
    block_id: str, photos: list[dict], *, editable: bool = False
) -> dict:
    return _block(block_id, PHOTO_GRID, editable=editable, photos=list(photos or []))


def link_block(
    block_id: str,
    url: str,
    *,
    label: str = "",
    tag: str = "",
    editable: bool = True,
) -> dict:
    return _block(
        block_id, LINK, editable=editable,
        url=str(url or ""), label=str(label or ""), tag=str(tag or ""),
    )


def stat_block(
    block_id: str,
    label: str,
    value: Any,
    *,
    basis: str = "",
    editable: bool = True,
) -> dict:
    return _block(
        block_id, STAT, editable=editable,
        label=str(label or ""), value=value, basis=str(basis or ""),
    )


def section_head_block(block_id: str, text: str) -> dict:
    return _block(block_id, SECTION_HEAD, editable=False, text=str(text or ""))


# --- envelope ------------------------------------------------------------


def make_section(heading: str, blocks: list[dict]) -> dict:
    return {"heading": str(heading or ""), "blocks": list(blocks or [])}


def make_report(title: str, sections: list[dict]) -> dict:
    return {"title": str(title or ""), "sections": list(sections or [])}


# --- lookups ---------------------------------------------------------------


def all_block_ids(report: dict) -> list[str]:
    return [
        b["block_id"]
        for sec in report.get("sections") or []
        for b in sec.get("blocks") or []
    ]


def find_block(report: dict, block_id: str) -> dict | None:
    for sec in report.get("sections") or []:
        for b in sec.get("blocks") or []:
            if b.get("block_id") == block_id:
                return b
    return None


def section_for_block(report: dict, block_id: str) -> dict | None:
    """The section dict containing ``block_id``, or ``None``."""
    for sec in report.get("sections") or []:
        for b in sec.get("blocks") or []:
            if b.get("block_id") == block_id:
                return sec
    return None


def block_ids_in_sections(report: dict, headings: set[str]) -> list[str]:
    """Every block id belonging to a section whose heading is in
    ``headings``."""
    out: list[str] = []
    for sec in report.get("sections") or []:
        if sec.get("heading") in headings:
            out.extend(b["block_id"] for b in sec.get("blocks") or [])
    return out


# --- sentence splitting -----------------------------------------------------

# Deliberately simple: split on blank-line paragraphs, then lines (so a
# bullet list keeps one item per line), then sentence-ending punctuation
# followed by whitespace and a capital/digit/quote — the common case for
# tidy, model-written prose. Doesn't try to special-case abbreviations
# ("Dr.", "U.S.") — an occasional over-split sentence is a minor cosmetic
# issue, not a correctness one, since every resulting piece is still a
# faithful, findable substring of the original body.
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z0-9\"'(‘’])")


def split_sentences(text: str) -> list[str]:
    """``text`` broken into sentence-ish pieces, each a verbatim substring
    (trimmed) of the input — never reworded, never reflowed beyond
    whitespace trimming, so a caller can always ``body.find(piece)`` it
    back. Blank input -> ``[]``."""
    text = (text or "").strip()
    if not text:
        return []
    out: list[str] = []
    for para in re.split(r"\n{2,}", text):
        para = para.strip("\n")
        if not para.strip():
            continue
        for line in para.split("\n"):
            line = line.strip()
            if not line:
                continue
            for piece in _SENTENCE_END.split(line):
                piece = piece.strip()
                if piece:
                    out.append(piece)
    return out


# --- generic teaser ----------------------------------------------------

_MAX_TEASER = 220


def teaser_from_blocks(report: dict) -> str:
    """A short chat-ready pointer at a block report: the title plus the
    first section's gist (its first ``text``/``fact`` block, or its
    heading when it has none) — never the full contents. A thin, generic
    stand-in for a producer's own hand-written ``teaser()``; producers with
    one already (deep-dive, appearance-via-chat markers) keep using it —
    this exists for report types that don't."""
    title = str(report.get("title") or "Report").strip()
    sections = report.get("sections") or []
    if not sections:
        return title
    first = sections[0]
    gist = ""
    for b in first.get("blocks") or []:
        if b.get("type") in (TEXT, FACT) and str(b.get("text") or "").strip():
            gist = str(b["text"]).strip()
            break
    if not gist:
        gist = str(first.get("heading") or "").strip()
    if not gist:
        return title
    line = f"{title} — {gist}"
    if len(line) > _MAX_TEASER:
        line = line[: _MAX_TEASER - 1].rstrip() + "…"
    return line
