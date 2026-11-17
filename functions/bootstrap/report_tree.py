"""Report → Node-Visualiser tree adapter (2o P0 foundation).

Turns a report from one opaque ``report_doc`` node (scores/findings buried in a
block payload only ``LivingReportView`` could read) into a NODE TREE the shared
``NodeVisualiser`` renders — the structural prerequisite for migrating the
appearance / deep-dive / match / shared report screens off the block renderer
(plan P2/P3/P5).

It does NOT re-derive any report: it reuses ``report_hub.get_report`` (the exact
``{title, sections, meta}`` block model the ``GET /report/{type}/{id}`` endpoint
serves, with its owner/permission checks) and converts each block to a node,
introducing the node kinds the founder named — SCORE/STAT, CONFIDENCE, CANDIDATE
and LINK — alongside the existing text / attribute / image nodes. Because it goes
through ``report_hub``, it works for EVERY report type, including ``match``,
which has no node in any person graph at all.
"""

from __future__ import annotations

import re
from typing import Any

import report_blocks as rb
import report_hub

SURFACE_REPORT = "report"


def _slug(heading: str) -> str:
    """A stable page_type slug for a section heading (node-tree section key)."""
    s = re.sub(r"[^a-z0-9]+", "_", (heading or "").strip().lower()).strip("_")
    return s or "section"


def _is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


_PERCENT_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*%\s*$")


def _percent_value(v: Any) -> float | None:
    """The numeric value of a percent-formatted score string (``"52%"`` →
    ``52.0``), or ``None`` when it isn't one.

    A match report's top-line "Match score" is stored as a percent STRING
    (``report_adapters.match_blocks`` — ``f"{round(score*100)}%"``), so without
    this it would fall through to the non-numeric branch and render as a flat
    CONFIDENCE band pill instead of the banded 0..100 ScoreBar its sub-dimension
    scores (plain numbers) already get — the founder's "the match report lost
    its graphics" complaint. A genuinely non-numeric value (a CONFIDENCE word
    like "High"/"Medium"/"Low") doesn't match and still renders as a band pill.
    """
    if not isinstance(v, str):
        return None
    m = _PERCENT_RE.match(v)
    if not m:
        return None
    try:
        return float(m.group(1))
    except ValueError:
        return None


def _block_to_nodes(block: dict, section_slug: str, index: int) -> list[dict]:
    """Convert ONE report block to one (or, for a photo grid, several) node
    dict(s) in the Node-Visualiser tree shape (``models/story_node.dart``).

    Report nodes are display-only: visibility is always ``public`` (the whole
    point of a report surface is that everything on it shows), and ``editable``
    carries the block's own flag so the node chat window can gate its actions.
    """
    btype = str(block.get("type") or "")
    bid = str(block.get("block_id") or f"{section_slug}:{index}")
    base: dict[str, Any] = {
        "id": bid,
        "section": section_slug,
        "label": "",
        "text": "",
        "answer_type": "text",
        "level": 1,
        "visibility": "public",
        "subtree_visibility": "public",
        "editable": bool(block.get("editable", False)),
    }

    if btype in (rb.TEXT, rb.FACT, rb.SECTION_HEAD):
        base["text"] = str(block.get("text") or "")
        return [base]

    if btype == rb.ATTRIBUTE:
        # A labelled field ("Eyes: Brown"), like a standard graph field.
        base["standard"] = True
        base["standard_label"] = str(block.get("label") or "")
        base["label"] = str(block.get("label") or "")
        base["text"] = str(block.get("value") if block.get("value") is not None else "")
        return [base]

    if btype == rb.STAT:
        # SCORE / STAT (numeric → score bar) or CONFIDENCE (non-numeric → band).
        base["answer_type"] = "stat"
        base["label"] = str(block.get("label") or "")
        val = block.get("value")
        if _is_number(val):
            base["stat_value"] = float(val)
        else:
            # A percent-formatted score string ("52%") is a numeric score too —
            # give it the banded ScoreBar, not the band pill reserved for
            # non-numeric CONFIDENCE words (see :func:`_percent_value`).
            pct = _percent_value(val)
            if pct is not None:
                base["stat_value"] = pct
        base["stat_text"] = "" if val is None else str(val)
        base["stat_basis"] = str(block.get("basis") or "")
        base["text"] = base["label"]
        return [base]

    if btype == rb.LINK:
        base["answer_type"] = "link"
        url = str(block.get("url") or "")
        base["link_url"] = url
        base["link_platform"] = str(block.get("tag") or "")
        base["label"] = str(block.get("label") or "") or url
        base["text"] = base["label"]
        return [base]

    if btype == rb.PHOTO:
        url = str(block.get("url") or "")
        caption = str(block.get("caption") or "")
        if bid.startswith("candidate:"):
            # A pending reverse-image-search candidate: is-me / not-me actions.
            base["answer_type"] = "candidate"
            base["image_url"] = url
            base["image_read"] = caption
            base["text"] = caption
            base["candidate_id"] = bid.split(":", 1)[1]
        else:
            base["answer_type"] = "image"
            base["image_url"] = url
            base["image_read"] = caption
            base["text"] = caption
            if block.get("verified") is not None:
                base["is_you"] = "yes" if block.get("verified") else "unknown"
        return [base]

    if btype == rb.PHOTO_GRID:
        out: list[dict] = []
        for i, p in enumerate(block.get("photos") or []):
            if not isinstance(p, dict):
                continue
            out.append(
                {
                    **base,
                    "id": f"{bid}:{i}",
                    "answer_type": "image",
                    "image_url": str(p.get("url") or ""),
                    "image_read": str(p.get("caption") or ""),
                    "text": str(p.get("caption") or ""),
                }
            )
        return out

    # Unknown block type: degrade to a plain text node rather than drop it.
    base["text"] = str(block.get("text") or block.get("label") or "")
    return [base]


def report_node_tree(
    db, report_type: str, report_id: str, viewer_uid: str
) -> dict:
    """The whole report as a Node-Visualiser tree: ``{surface:"report", title,
    sections:[{page_type,title,order,nodes:[...]}], meta}``.

    Reuses :func:`report_hub.get_report` (owner/permission checks included), so
    it raises the same ``ValueError`` (unknown type) / ``KeyError`` (nothing to
    report → 404) / ``PermissionError`` (owner-only → 403) the block endpoint
    does. ``meta`` is carried through unchanged (``viewer_can_edit``,
    ``card_hidden_photos`` …) for the report screens that consume this tree.
    """
    report = report_hub.get_report(db, report_type, report_id, viewer_uid)
    sections_out: list[dict] = []
    for order, section in enumerate(report.get("sections") or []):
        heading = str(section.get("heading") or "")
        slug = _slug(heading)
        nodes: list[dict] = []
        for index, block in enumerate(section.get("blocks") or []):
            if isinstance(block, dict):
                nodes.extend(_block_to_nodes(block, slug, index))
        sections_out.append(
            {
                "page_type": slug,
                "title": heading,
                "order": order,
                "nodes": nodes,
            }
        )
    return {
        "surface": SURFACE_REPORT,
        "title": report.get("title") or "",
        "sections": sections_out,
        "meta": report.get("meta") or {},
    }
