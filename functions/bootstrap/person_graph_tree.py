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

import node_gist
import node_visual
import person_graph_index as index_mod
import person_graph_render as render
import question_tree
from person_graph import HEADER_FIELD_IDS, GraphNode, Visibility

# Surfaces the one visualiser renders (parallels the client's NodeVisualiserSurface).
SURFACE_STORY = "story"
SURFACE_PUBLIC = "publicProfile"
SURFACE_REPORT = "report"
SURFACE_GRAPH_DETAIL = "graphDetail"

_OWNER_SURFACES = {SURFACE_STORY, SURFACE_REPORT, SURFACE_GRAPH_DETAIL}

# The standard identity fields the public profile already renders in its PHOTO
# HEADER (name / age / location, from ``GET /explore/profile/{uid}``). On the
# public surface the header sits directly above the Node-Visualiser body, so
# re-rendering these as About Me rows would show each twice (founder build 2509:
# the header shows name/33/San Jose, About Me repeated 33/San Jose). They are
# skipped from the public tree so each appears exactly ONCE, in the header — a
# render-placement rule, not a data/visibility change: the nodes are untouched
# and still render on every owner surface (Your Story has no photo header, so it
# keeps these rows). Restatement suppression is unaffected: these facts stay in
# ``_standard_facts_by_section`` so a prose/editor bullet restating them is still
# collapsed, and the single surviving copy is the header. The set is defined once
# in ``person_graph.HEADER_FIELD_IDS`` and shared with the public Living Report
# render (``person_graph_render.public_sections``) so the two public surfaces can
# never drift apart (NOTE 261 follow-on).
_HEADER_FIELD_IDS = HEADER_FIELD_IDS

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
#  3. CONTENT-TOKEN restatement (zero-duplicates leg 28, NOTE 252) — a node whose
#     content-token SET (stopwords dropped, order-insensitive) already rendered in
#     the SAME section is suppressed. This collapses two distinct restatement
#     nodes of one fact on an UNMERGED graph — where neither is a standard row and
#     their normalized text DIFFERS by a stopword/punctuation/word-order ("Ethnic
#     & cultural origin: South Asian" vs "ethnic and cultural origin south asian")
#     so rule 2 misses them — at the same precision bar as the standard matcher's
#     token-set form. Section-scoped, so a fact legitimately shared across two
#     sections is untouched.
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
    """The date a node carries, if any — the node-level ``dated`` (founder Nov 18:
    "set the node's dated field so the timeline renders"; written by the LinkedIn
    work-history import), else the first typed-link ``dated`` (``Link.dated``) for
    older dated nodes. Surfaced read-only so the Career view renders a date where
    one exists; a node without one gets ``""`` and lists with no date. Never
    invents a date."""
    own = (getattr(node, "dated", None) or "").strip()
    if own:
        return own
    for link in getattr(node, "links", None) or []:
        dated = (getattr(link, "dated", None) or "").strip()
        if dated:
            return dated
    return ""


def _order_timeline_siblings(nodes: list[dict]) -> list[dict]:
    """Order the DATED timeline entries in a sibling list by date, most recent
    first (the CV / LinkedIn convention — the founder's Career section reads as
    a timeline), leaving every non-dated sibling in its existing position.

    A built node carries a date (``dated``) only where the node already does
    (``Link.dated``); nothing is invented. With fewer than two dated siblings
    this is a no-op, so an undated graph renders byte-for-byte as before and the
    Career timeline orders itself the MOMENT dated role/company nodes exist — no
    backfill, no parallel widget, no schema change."""
    slots = [i for i, n in enumerate(nodes) if (n.get("dated") or "").strip()]
    if len(slots) < 2:
        return nodes
    ordered = sorted(
        (nodes[i] for i in slots),
        key=lambda n: (n.get("dated") or ""),
        reverse=True,
    )
    out = list(nodes)
    for slot, built in zip(slots, ordered):
        out[slot] = built
    return out


def _default_visual(
    section: str | None, answer_type: str | None, gist_val: str, dated: str
) -> dict:
    """The READ-TIME default visual for a node that carries no stored ``visual``
    (every existing node — there is NO backfill).

    A plain PROSE fact is a BULLET (``gist_row``) — never a chip, card or
    timeline fabricated from a single sentence (founder build 2495: "I would
    rather have bullet points"). Genuine structure only:
      - an image node → a ``photo_carousel`` (the renderer derives the photo
        from the node's own image fields);
      - a node that ALREADY carries a DATE → a ``timeline_entry`` (a real date is
        genuine structure — rule: timeline only with dates);
      - everything else → ``gist_row``.
    A writer that genuinely has discrete items / a scale stores that visual
    explicitly and it is preserved upstream (``_node_visual``)."""
    if answer_type == "image":
        return node_visual.default_for(section, answer_type)
    if dated and gist_val:
        return node_visual.timeline_entry(gist_val, dated)
    return node_visual.make(node_visual.GIST_ROW)


def _node_visual(node: GraphNode, gist_val: str) -> dict:
    """The visual descriptor surfaced for a node: the STORED write-time visual
    when the writer picked one, else the read-time default. A stored visual with
    an unknown/newer ``type`` is passed through untouched — the client falls back
    to ``gist_row`` for a type its palette doesn't know."""
    stored = getattr(node, "visual", None)
    if isinstance(stored, dict) and stored.get("type"):
        return stored
    return _default_visual(node.section, node.answer_type, gist_val, _node_dated(node))


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
    seen_tokens: dict[str, set[frozenset[str]]],
    hide_ayma_only_images: bool,
) -> Optional[dict]:
    """Render one node + its descendants, filtered to ``keep``. Returns None when
    neither the node nor any descendant survives the visibility filter.

    ``std_by_section`` / ``seen_texts`` / ``seen_tokens`` drive the
    zero-duplicates guarantee: a non-standard node whose text restates a rendering
    standard fact, whose normalized text already appeared earlier in the walk, or
    whose content-token set already rendered in the same section, has its OWN line
    suppressed (its distinct children, if any, still render).

    ``hide_ayma_only_images`` drops a RETAINED Ayma-only IMAGE node from the
    story / public body even when the dev flag keeps ayma_only nodes (text
    inferences) visible there — a deleted-but-retained photo belongs ONLY in the
    owner's Ayma-only Photos view, never on the story body or any shared surface
    (Scout NOTE 256; founder retention rule, Privacy P0)."""
    if node.id in seen:
        return None
    seen.add(node.id)

    own_vis = _vis(node)
    text = render.node_display_text(node)
    is_image = node.answer_type == "image"
    norm = index_mod.normalize_text(text)
    toks = index_mod.token_set(text)
    sec_tokens = seen_tokens.setdefault(node.section, set())

    own_renderable = bool(text) or is_image
    own_kept = own_vis in keep and own_renderable
    # Privacy P0 (Scout NOTE 256): a retained Ayma-only IMAGE never renders on the
    # story / public body, even with the dev flag on (which keeps ayma_only text
    # inferences visible) — a deleted-but-retained photo lives only in the owner's
    # Ayma-only Photos view. Non-image ayma_only nodes still follow ``keep``.
    if is_image and own_vis == "ayma_only" and hide_ayma_only_images:
        own_kept = False
    # Zero-duplicates: never suppress a standard labelled row (it is the keeper);
    # suppress a non-standard node that restates a standard fact rendering in the
    # same section, whose text was already emitted (exact duplicate), or whose
    # content-token set already rendered in this section (restatement on an
    # unmerged graph — rule 3).
    if own_kept and not node.standard and not is_image:
        if (
            _restates_standard(text, node.section, std_by_section)
            or (norm and norm in seen_texts)
            or (toks and toks in sec_tokens)
        ):
            own_kept = False
    # register BEFORE children, so the row wins over its restatements
    if own_kept and norm:
        seen_texts.add(norm)
    if own_kept and not is_image and toks:
        sec_tokens.add(toks)

    # child NODES (parent links) rendered recursively, in fixed order
    child_nodes = sorted(
        (graph[c] for c in adj.get(node.id, []) if c not in seen),
        key=_order_key,
    )
    children: list[dict] = []
    for c in child_nodes:
        built = _build_node(
            c, graph, adj, keep, seen, std_by_section, seen_texts, seen_tokens,
            hide_ayma_only_images,
        )
        if built is not None:
            children.append(built)

    # child BULLETS (ChildBullet text leaves) carry their own visibility
    for i, cb in enumerate(node.children):
        cb_vis = _VIS_STR.get(cb.visibility, "private")
        cb_text = cb.text.strip()
        if not cb_text or cb_vis not in keep:
            continue
        cb_norm = index_mod.normalize_text(cb_text)
        cb_toks = index_mod.token_set(cb_text)
        if (
            _restates_standard(cb_text, node.section, std_by_section)
            or (cb_norm and cb_norm in seen_texts)
            or (cb_toks and cb_toks in sec_tokens)
        ):
            continue  # a child bullet that restates a standard fact / exact dup / token dup
        if cb_norm:
            seen_texts.add(cb_norm)
        if cb_toks:
            sec_tokens.add(cb_toks)
        children.append(
            {
                "id": f"{node.id}#c{i}",
                "section": node.section,
                "label": "",
                "text": cb_text,
                "gist": node_gist.derive_gist(cb_text),
                "visual": _default_visual(
                    node.section, "text", node_gist.derive_gist(cb_text), ""
                ),
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

    # A dated child set (a nested career timeline) renders date-ordered.
    children = _order_timeline_siblings(children)

    gist_val = node_gist.derive_gist(
        text if own_kept else "", stored=getattr(node, "gist", None)
    )
    out = {
        "id": node.id,
        "section": node.section,
        "label": node.standard_field_label or (node.prompt if node.emergent else node.prompt),
        "text": text if own_kept else "",  # a suppressed line shows nothing, children remain
        # Gist-first (less-text-heavy Part 1): the short headline rendered by
        # default; the stored writer gist wins, else a derived fallback.
        "gist": gist_val,
        # Write-time VISUAL pick (less-text-heavy Part 2): how the client's thin
        # palette renderer draws this node (chip / timeline / bar / card / …).
        # The stored pick wins; else a read-time default derived from the node.
        "visual": _node_visual(node, gist_val),
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
    # A retained Ayma-only IMAGE is kept out of the story/public body regardless
    # of the dev flag (Scout NOTE 256, Privacy P0) — it lives only in the owner's
    # Ayma-only Photos view. Non-story owner surfaces (graphDetail) still show it.
    hide_ayma_only_images = surface in (SURFACE_STORY, SURFACE_PUBLIC)
    adj = _children_of(graph)
    child_ids = {c for cs in adj.values() for c in cs}
    std_by_section = _standard_facts_by_section(graph, keep)

    seen: set[str] = set()
    seen_texts: set[str] = set()  # zero-duplicates: normalized texts already emitted
    # zero-duplicates leg 28: content-token sets already rendered, per section
    seen_tokens: dict[str, set[frozenset[str]]] = {}
    by_section: dict[str, list[dict]] = {}
    roots = sorted(
        (n for nid, n in graph.items() if nid not in child_ids),
        key=lambda n: (question_tree.section_order(n.section), *_order_key(n)),
    )
    for n in roots:
        if drop_report and render.node_page_type(n) in render._REPORT_PAGE_TYPES:
            continue
        # Public profile: the photo header already shows name/age/location, so
        # skip those standard rows here (founder 2509) — they stay in
        # ``std_by_section`` above, so restatements remain suppressed.
        if surface == SURFACE_PUBLIC and n.id in _HEADER_FIELD_IDS:
            continue
        built = _build_node(
            n, graph, adj, keep, seen, std_by_section, seen_texts, seen_tokens,
            hide_ayma_only_images,
        )
        if built is not None:
            by_section.setdefault(n.section, []).append(built)

    sections = []
    for pt in question_tree.ordered_page_types():
        nodes = _order_timeline_siblings(by_section.get(pt, []))
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
                        "nodes": _order_timeline_siblings(nodes),
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
