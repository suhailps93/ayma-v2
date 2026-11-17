"""The Node Visualiser tree render (Contract 3 payload, backend side).

One renderer for one data model: the client's ``NodeVisualiser`` widget takes a
node and renders it plus all its children recursively. This module walks the
effective person graph and emits that recursive tree — the single payload every
surface (Your Story, public profile, every report, the image carousel, the
person-graph tap-detail) consumes, so there is exactly one rendering of a node
everywhere (the parallel-renderer defect class the chunk removes structurally).

A node-tree node is::

    {
      "id", "section", "label", "text", "answer_type", "level",
      "visibility",                 # public | private | ayma_only
      "subtree_visibility",         # public | private | ayma_only | mixed
      "standard", "standard_label", "standard_order",
      "editable",                   # False for ayma_only (read-only) nodes
      "image_url", "image_read",    # image nodes (Contract 1)
      "is_you", "source_kind", "source_ref", "source_created_at", "provenance",
      "children": [ <node-tree>, ... ]
    }

Fixed order (founder Nov 16, folded into this chunk): within any node, the
standard (known structured) children render FIRST in their canonical
``standard_order``, then the conversational children in their existing order.

Visibility (settled):
  - story / report / graph_detail (owner surfaces): public + private, and
    ayma_only only when the AI-only dev flag is on (founder: keep it ON).
  - public profile: public only, never private or ayma_only.
"""

from __future__ import annotations

from typing import Optional

import person_graph_index as index_mod
import person_graph_render as render
import question_tree
from person_graph import GraphNode, Visibility

# Surfaces the one visualiser renders (parallels the client's NodeVisualiserSurface).
SURFACE_STORY = "story"
SURFACE_PUBLIC = "publicProfile"
SURFACE_REPORT = "report"
SURFACE_GRAPH_DETAIL = "graphDetail"

_OWNER_SURFACES = {SURFACE_STORY, SURFACE_REPORT, SURFACE_GRAPH_DETAIL}

_VIS_STR = {
    Visibility.PUBLIC: "public",
    Visibility.PRIVATE: "private",
    Visibility.AYMA_ONLY: "ayma_only",
}


def _vis(node: GraphNode) -> str:
    return _VIS_STR.get(node.visibility, "private")


def _keep_set(surface: str, *, include_ayma_only: bool) -> set[str]:
    """Which node visibilities this surface renders."""
    if surface == SURFACE_PUBLIC:
        return {"public"}
    keep = {"public", "private"}
    if include_ayma_only and surface in _OWNER_SURFACES:
        keep.add("ayma_only")
    return keep


# --- zero-duplicates render guarantee (founder build 2488) -----------------
#
# A section must NEVER show the same fact twice. Two suppression rules, applied
# as the tree is built, so the guarantee holds even if a write path once minted
# a restating node:
#
#  1. STANDARD restatement — when a standard fact renders as its labelled row,
#     any OTHER node in the same section whose text restates that fact (the bare
#     value, or "<label>: <value>") is suppressed; the standard row survives.
#  2. EXACT duplicate — a node (or child bullet) whose normalized text was
#     already emitted earlier in the walk is suppressed.
#
# Both are SURFACE-AWARE: a standard fact only suppresses a restatement on a
# surface where that standard row itself renders (its visibility is in ``keep``),
# so suppressing a bullet can never make the only copy of a fact disappear — and
# a private value is never pulled onto the public surface, nor vice-versa.


def _standard_facts_by_section(
    graph: dict[str, GraphNode], keep: set[str]
) -> dict[str, list[tuple[str, frozenset[str]]]]:
    """``{section: [(value_norm, labelvalue_tokens), ...]}`` for the STANDARD
    nodes that actually render on this surface (visibility in ``keep`` and a
    non-empty value) — the facts whose restatements get suppressed."""
    out: dict[str, list[tuple[str, frozenset[str]]]] = {}
    for n in graph.values():
        if not n.standard or _vis(n) not in keep:
            continue
        value_norm, lv_tokens = render.standard_fact_forms(n)
        if not value_norm and not lv_tokens:
            continue
        out.setdefault(n.section, []).append((value_norm, lv_tokens))
    return out


def _restates_standard(
    text: str, section: str, std_by_section: dict[str, list[tuple[str, frozenset[str]]]]
) -> bool:
    """True when ``text`` restates any rendering standard fact in ``section``."""
    forms = std_by_section.get(section)
    if not forms or not text:
        return False
    for value_norm, lv_tokens in forms:
        if render.text_restates_standard_fact(value_norm, lv_tokens, text):
            return True
    return False


def _children_of(graph: dict[str, GraphNode]) -> dict[str, list[str]]:
    """Adjacency: parent id -> child node ids, in a stable order."""
    adj: dict[str, list[str]] = {}
    for nid in sorted(graph):
        parent = getattr(graph[nid], "parent", None)
        if parent and parent in graph:
            adj.setdefault(parent, []).append(nid)
    return adj


def _order_key(node: GraphNode) -> tuple:
    """Fixed order: standard fields first (by canonical order), then
    conversational nodes by (level, id)."""
    if node.standard and node.standard_field_order is not None:
        return (0, node.standard_field_order, node.id)
    return (1, node.level, node.id)


def _source_out(node: GraphNode) -> dict:
    """SOURCE provenance for ANY node (founder Nov 17: every node has a source).
    Emitted on every node, not just images, so tapping a node's source works for
    a chat-created fact (session + message id) or a web node (its link)."""
    return {
        "source_kind": getattr(node, "source_kind", None) or "",
        "source_ref": getattr(node, "source_ref", None) or "",
        "source_message_id": getattr(node, "source_message_id", None) or "",
        "source_created_at": getattr(node, "source_created_at", None) or "",
    }


def _node_dated(node: GraphNode) -> str:
    """The date a node ALREADY carries, if any — the first typed-link ``dated``
    on it (``Link.dated``, the only user-facing date on the node model). Surfaced
    read-only so the dedicated Career view can render a date where one already
    exists; a node without one gets ``""`` and lists with no date. Never
    invents a date, never adds start/end fields (founder Nov 17: no schema
    change)."""
    for link in getattr(node, "links", None) or []:
        dated = (getattr(link, "dated", None) or "").strip()
        if dated:
            return dated
    return ""


def _image_fields(node: GraphNode) -> dict:
    """Contract 1 image-node fields (image-only), read defensively."""
    if node.answer_type != "image":
        return {}
    return {
        "image_url": node.answer if isinstance(node.answer, str) else "",
        "image_read": getattr(node, "image_read", None) or "",
        "is_you": getattr(node, "is_you", None) or "unknown",
    }


def _build_node(
    node: GraphNode,
    graph: dict[str, GraphNode],
    adj: dict[str, list[str]],
    keep: set[str],
    seen: set[str],
    std_by_section: dict[str, list[tuple[str, frozenset[str]]]],
    seen_texts: set[str],
) -> Optional[dict]:
    """Render one node + its descendants, filtered to ``keep``. Returns None when
    neither the node nor any descendant survives the visibility filter.

    ``std_by_section`` / ``seen_texts`` drive the zero-duplicates guarantee: a
    non-standard node whose text restates a rendering standard fact, or whose
    normalized text already appeared earlier in the walk, has its OWN line
    suppressed (its distinct children, if any, still render)."""
    if node.id in seen:
        return None
    seen.add(node.id)

    own_vis = _vis(node)
    text = render.node_display_text(node)
    is_image = node.answer_type == "image"
    norm = index_mod.normalize_text(text)

    own_renderable = bool(text) or is_image
    own_kept = own_vis in keep and own_renderable
    # Zero-duplicates: never suppress a standard labelled row (it is the keeper);
    # suppress a non-standard node that restates a standard fact rendering in the
    # same section, or whose text was already emitted (exact duplicate).
    if own_kept and not node.standard and not is_image:
        if _restates_standard(text, node.section, std_by_section) or (
            norm and norm in seen_texts
        ):
            own_kept = False
    if own_kept and norm:
        seen_texts.add(norm)  # register BEFORE children, so the row wins over its restatements

    # child NODES (parent links) rendered recursively, in fixed order
    child_nodes = sorted(
        (graph[c] for c in adj.get(node.id, []) if c not in seen),
        key=_order_key,
    )
    children: list[dict] = []
    for c in child_nodes:
        built = _build_node(c, graph, adj, keep, seen, std_by_section, seen_texts)
        if built is not None:
            children.append(built)

    # child BULLETS (ChildBullet text leaves) carry their own visibility
    for i, cb in enumerate(node.children):
        cb_vis = _VIS_STR.get(cb.visibility, "private")
        cb_text = cb.text.strip()
        if not cb_text or cb_vis not in keep:
            continue
        cb_norm = index_mod.normalize_text(cb_text)
        if _restates_standard(cb_text, node.section, std_by_section) or (
            cb_norm and cb_norm in seen_texts
        ):
            continue  # a child bullet that restates a standard fact / exact dup
        if cb_norm:
            seen_texts.add(cb_norm)
        children.append(
            {
                "id": f"{node.id}#c{i}",
                "section": node.section,
                "label": "",
                "text": cb_text,
                "answer_type": "text",
                "level": node.level + 1,
                "visibility": cb_vis,
                "subtree_visibility": cb_vis,
                "standard": False,
                "standard_label": None,
                "standard_order": None,
                "editable": cb_vis != "ayma_only",
                "children": [],
            }
        )

    if not own_kept and not children:
        return None

    out = {
        "id": node.id,
        "section": node.section,
        "label": node.standard_field_label or (node.prompt if node.emergent else node.prompt),
        "text": text if own_kept else "",  # a suppressed line shows nothing, children remain
        "answer_type": node.answer_type or "text",
        "level": node.level,
        "visibility": own_vis,
        "subtree_visibility": _subtree_visibility(own_vis if own_kept else None, children),
        "standard": bool(node.standard),
        "standard_label": node.standard_field_label,
        "standard_order": node.standard_field_order,
        "editable": own_vis != "ayma_only",
        "dated": _node_dated(node),  # a date only where the node already has one
        "children": children,
    }
    out.update(_source_out(node))  # source on every node, not just images
    out.update(_image_fields(node))
    return out


def _subtree_visibility(own: Optional[str], children: list[dict]) -> str:
    """The bullet colour for a node: its own visibility, unless its subtree holds
    BOTH public and private (ignoring ayma_only) — then "mixed" (the split
    yin-yang bullet). ayma_only alone stays ayma_only."""
    vis_seen: set[str] = set()
    if own:
        vis_seen.add(own)
    stack = list(children)
    while stack:
        c = stack.pop()
        vis_seen.add(c.get("visibility", ""))
        stack.extend(c.get("children", []))
    non_ai = {v for v in vis_seen if v in ("public", "private")}
    if "public" in non_ai and "private" in non_ai:
        return "mixed"
    if non_ai:
        return next(iter(non_ai))
    return own or "ayma_only"


def node_tree(
    graph: dict[str, GraphNode],
    *,
    surface: str = SURFACE_STORY,
    include_ayma_only: bool = True,
) -> dict:
    """The whole person as a Node-Visualiser tree: one section group per
    non-empty canonical section, each with its ROOT node-trees (a root = a node
    with no in-graph parent), in fixed order (standard first). ``drop_report``
    excludes the report-linked sections from Your Story / public (they have their
    own report surface), matching the existing story render."""
    keep = _keep_set(surface, include_ayma_only=include_ayma_only)
    drop_report = surface in (SURFACE_STORY, SURFACE_PUBLIC)
    adj = _children_of(graph)
    child_ids = {c for cs in adj.values() for c in cs}
    std_by_section = _standard_facts_by_section(graph, keep)

    seen: set[str] = set()
    seen_texts: set[str] = set()  # zero-duplicates: normalized texts already emitted
    by_section: dict[str, list[dict]] = {}
    roots = sorted(
        (n for nid, n in graph.items() if nid not in child_ids),
        key=lambda n: (question_tree.section_order(n.section), *_order_key(n)),
    )
    for n in roots:
        if drop_report and render.node_page_type(n) in render._REPORT_PAGE_TYPES:
            continue
        built = _build_node(n, graph, adj, keep, seen, std_by_section, seen_texts)
        if built is not None:
            by_section.setdefault(n.section, []).append(built)

    sections = []
    for pt in question_tree.ordered_page_types():
        nodes = by_section.get(pt, [])
        if surface == SURFACE_PUBLIC and not nodes:
            continue
        sections.append(
            {
                "page_type": pt,
                "title": question_tree.section_title(pt),
                "order": question_tree.section_order(pt),
                "nodes": nodes,
            }
        )
    # meta sections (report/appearance/etc.) that have content on a report surface
    if not drop_report:
        for pt, nodes in by_section.items():
            if pt not in {s["page_type"] for s in sections}:
                sections.append(
                    {
                        "page_type": pt,
                        "title": render._grounding_label(pt),
                        "order": 900,
                        "nodes": nodes,
                    }
                )
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"surface": surface, "sections": sections}


def descendant_ids(graph: dict[str, GraphNode], node_id: str) -> list[str]:
    """Every descendant node id of ``node_id`` (child nodes via parent links,
    recursively) — NOT including ``node_id`` itself. Used by the visibility
    cascade and the delete-with-children-count confirmation."""
    adj = _children_of(graph)
    out: list[str] = []
    stack = list(adj.get(node_id, []))
    while stack:
        nid = stack.pop()
        if nid in out:
            continue
        out.append(nid)
        stack.extend(adj.get(nid, []))
    return out
