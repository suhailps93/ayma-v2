"""Write-time VISUAL pick for person-graph nodes (less-text-heavy program).

Every node written going forward carries a sibling ``visual`` descriptor —
``{"type": <palette type>, "params": {...}, "v": 1}`` — that Part 2's renderers
read to decide HOW to draw the node (a chip set, a timeline row, a gauge, …)
instead of defaulting everything to a text row. The founder's mechanism: "the
visual lives on the node", picked deterministically at write time so a bad pick
is rare. Picking a visual NEVER changes a node's visibility and NEVER blocks a
write — where the data for the params isn't readily available, store just
``{type, v}`` and let the renderer derive/fallback.

PALETTE v1 is fixed and versioned (``v``); unknown/absent types fall back to
``gist_row`` in the reader. The ``params`` shapes are the contract documented in
``docs/PERSON_GRAPH.md § Write-time visual``.
"""

from __future__ import annotations

from typing import Any

# PALETTE v1 — fixed, versioned type strings (do not rename; bump ``V`` to evolve).
V = 1

GIST_ROW = "gist_row"  # universal fallback — renders node.gist
CHIP_SET = "chip_set"
TIMELINE_ENTRY = "timeline_entry"
BAR_METER = "bar_meter"
GAUGE = "gauge"
CARD = "card"
PHOTO_CAROUSEL = "photo_carousel"
SMALL_TABLE = "small_table"

PALETTE = frozenset(
    {
        GIST_ROW,
        CHIP_SET,
        TIMELINE_ENTRY,
        BAR_METER,
        GAUGE,
        CARD,
        PHOTO_CAROUSEL,
        SMALL_TABLE,
    }
)

# Per-kind default by home section (founder rule). An unlisted section → gist_row.
#  - list-like facts (interests / values / lifestyle / taste / social circle) → chip_set
#  - dated items (career / education / life events) → timeline_entry
# Scores, reports, images and comparisons are unambiguous in their writers, which
# set the visual explicitly (gauge / bar_meter / card / photo_carousel / small_table).
_SECTION_DEFAULT = {
    "interests": CHIP_SET,
    "values": CHIP_SET,
    "lifestyle": CHIP_SET,
    "taste": CHIP_SET,
    "social_circle": CHIP_SET,
    "career": TIMELINE_ENTRY,
}


def make(vtype: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """A versioned visual descriptor. An unknown ``vtype`` falls back to the
    universal ``gist_row`` so a bad pick is never a hard error."""
    t = vtype if vtype in PALETTE else GIST_ROW
    return {"type": t, "params": dict(params or {}), "v": V}


def for_section(section: str | None) -> dict[str, Any]:
    """The deterministic per-section default visual for a text node."""
    return make(_SECTION_DEFAULT.get(section or "", GIST_ROW))


def default_for(section: str | None, answer_type: str | None = None) -> dict[str, Any]:
    """The deterministic default visual for a newly-minted node: an image node
    renders as a photo_carousel (the renderer derives ``image_refs`` from the
    node's own image fields); otherwise the per-section default."""
    if answer_type == "image":
        return make(PHOTO_CAROUSEL)
    return for_section(section)


# --- convenience builders for the writers that pick a visual explicitly -----


def card(title: str = "", body: str = "") -> dict[str, Any]:
    """A report finding / judgment. ``body`` is the brief detail."""
    return make(CARD, {"title": title or "", "body": body or ""})


def gauge(value: float, lo: float, hi: float, label: str = "") -> dict[str, Any]:
    return make(GAUGE, {"value": value, "min": lo, "max": hi, "label": label or ""})


def bar_meter(value: float, lo: float, hi: float, label: str = "") -> dict[str, Any]:
    return make(BAR_METER, {"value": value, "min": lo, "max": hi, "label": label or ""})


def chip_set(items: list[str]) -> dict[str, Any]:
    return make(CHIP_SET, {"items": [str(x) for x in (items or []) if str(x).strip()]})


def timeline_entry(title: str, date: str | None = None) -> dict[str, Any]:
    return make(TIMELINE_ENTRY, {"date": date, "title": title or ""})


def photo_carousel(image_refs: list[Any]) -> dict[str, Any]:
    return make(PHOTO_CAROUSEL, {"image_refs": list(image_refs or [])})


def small_table(columns: list[str], rows: list[list[str]]) -> dict[str, Any]:
    return make(
        SMALL_TABLE,
        {"columns": [str(c) for c in (columns or [])], "rows": rows or []},
    )
