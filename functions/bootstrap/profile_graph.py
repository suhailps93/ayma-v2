"""Person-graph data for the clickable graph visualization (founder order
point 8: "the structure is a graph — sections → questions → answers →
visibility … a clickable graph that shows who the person is").

Transforms the section → bullets model into a ``{center, sections, nodes,
edges}`` graph: the person at the centre, one node per non-empty section, and
one leaf node per bullet carrying its visibility. Empty sections are hidden
from the graph (a view), matching the public/private views (point 3); they
only appear in the editor.

Owner view includes every bullet; a public view is built from the public
bullets only (``owner_only=False``), so the same shape renders another
person's graph without leaking private or Ayma-only content.
"""

from __future__ import annotations

import profile_bullets
import question_tree
from story_common import VIS_AI_ONLY, VIS_PRIVATE, VIS_PUBLIC


def _graph_from_sections(sections: list[dict], *, owner_only: bool, center_label: str) -> dict:
    nodes: list[dict] = [{"id": "me", "kind": "person", "label": center_label}]
    edges: list[dict] = []
    out_sections: list[dict] = []
    for s in sections:
        bullets = s.get("bullets", [])
        if not owner_only:
            bullets = [b for b in bullets if b.get("visibility") == VIS_PUBLIC]
        if not bullets:
            continue  # empty section hidden from the graph view (point 3)
        pt = s["page_type"]
        sec_id = f"sec:{pt}"
        counts = {VIS_PUBLIC: 0, VIS_PRIVATE: 0, VIS_AI_ONLY: 0}
        for b in bullets:
            counts[b.get("visibility", VIS_PUBLIC)] = counts.get(b.get("visibility", VIS_PUBLIC), 0) + 1
        nodes.append(
            {
                "id": sec_id,
                "kind": "section",
                "page_type": pt,
                "label": s.get("title", pt),
                "subtitle": s.get("subtitle", ""),
            }
        )
        edges.append({"from": "me", "to": sec_id})
        for b in bullets:
            bid = f"b:{b['id']}"
            node = {
                "id": bid,
                "kind": "bullet",
                "page_type": pt,
                "text": b["text"],
                "visibility": b["visibility"],
            }
            # An image node carries its Storage link so the graph view can show
            # the photo and open it (founder: each photo sits with its fact).
            if b.get("image_url"):
                node["kind"] = "image"
                node["image_url"] = b["image_url"]
            nodes.append(node)
            edges.append({"from": sec_id, "to": bid})
        out_sections.append(
            {
                "page_type": pt,
                "title": s.get("title", pt),
                "subtitle": s.get("subtitle", ""),
                "order": s.get("order", question_tree.section_order(pt)),
                "total": len(bullets),
                "public": counts[VIS_PUBLIC],
                "private": counts[VIS_PRIVATE],
                "ai_only": counts[VIS_AI_ONLY],
            }
        )
    return {
        "center": {"id": "me", "label": center_label},
        "sections": out_sections,
        "nodes": nodes,
        "edges": edges,
    }


def get_graph(db, uid: str, *, center_label: str = "You") -> dict:
    """The owner's full person-graph (every bullet, all visibilities)."""
    sections = profile_bullets.get_bullets(db, uid).get("sections", [])
    return _graph_from_sections(sections, owner_only=True, center_label=center_label)


def public_graph(db, uid: str, *, center_label: str = "") -> dict:
    """Another person's graph — public bullets only, nothing private/Ayma-only.
    The same shape as :func:`get_graph` so one renderer handles both."""
    sections = profile_bullets.get_bullets(db, uid).get("sections", [])
    return _graph_from_sections(
        sections, owner_only=False, center_label=center_label or "Them"
    )
