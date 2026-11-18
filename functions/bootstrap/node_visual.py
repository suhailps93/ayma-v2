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

# The default visual for a plain TEXT (prose) node is ALWAYS a BULLET
# (``gist_row``) — regardless of section. We never shape a single prose sentence
# into a chip, card, timeline or bar; that read a plain interests fact as a grey
# card/chip bubble (founder build 2495: "I would rather have bullet points").
#
# A real diagram comes ONLY from a writer that GENUINELY carries the structure
# and stores the visual explicitly — never fabricated from prose:
#  - ``chip_set``        — the node has DISCRETE items (``params.items``)
#  - ``timeline_entry``  — the node carries a DATE (derived only where a real
#                          date exists; see ``person_graph_tree._default_visual``)
#  - ``bar_meter`` / ``gauge`` — a numeric value on a scale
#  - ``card``            — a structured finding with a title AND a body (a report
#                          judgment); Ayma NEVER picks ``card`` for a plain fact
#  - ``photo_carousel``  — an image node (derived from its own image fields)


def make(vtype: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    """A versioned visual descriptor. An unknown ``vtype`` falls back to the
    universal ``gist_row`` so a bad pick is never a hard error."""
    t = vtype if vtype in PALETTE else GIST_ROW
    return {"type": t, "params": dict(params or {}), "v": V}


def for_section(section: str | None) -> dict[str, Any]:
    """The default visual for a plain text node: a BULLET (``gist_row``). Prose
    is never auto-shaped into a chip/card/timeline (founder build 2495); genuine
    structure comes only from an explicit writer pick that carries it."""
    return make(GIST_ROW)


def default_for(section: str | None, answer_type: str | None = None) -> dict[str, Any]:
    """The deterministic default visual for a newly-minted node: an image node
    renders as a photo_carousel (the renderer derives ``image_refs`` from the
    node's own image fields); every other (prose) node is a ``gist_row`` bullet."""
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
