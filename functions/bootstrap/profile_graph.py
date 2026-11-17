"""Person-graph data for the clickable graph visualization (founder order
point 8: "the structure is a graph — sections → questions → answers →
visibility … a clickable graph that shows who the person is"; Nov 16 2026
founder direction via Astro: "show EVERYTHING in the graph … like a neural
network").

Transforms the graph store into a ``{center, sections, nodes, edges}`` graph:
the person at the centre, one hub node per non-empty section, and the leaf
nodes around each hub. Two sources are merged:

* **Story bullets** (``profile_bullets.get_bullets`` → ``_graph_from_sections``)
  — the per-bullet story content, coloured by visibility.
* **Every other node in the graph store** (``person_graph_store.effective`` →
  ``_augment_with_store_nodes``) — the report nodes (appearance, web findings),
  photo/image nodes, and the live-writer nodes (skill, assessment, taste,
  steering, interactions). These live in the overlay but were never bullets, so
  the graph used to hide them entirely. Each tappable node carries an ``open``
  target so the client can open its report or photo.

Owner view includes every node, all visibilities; a public view keeps only the
public bullets/nodes (``owner_only=False``), so the same shape renders another
person's graph without leaking private or Ayma-only content.
"""

from __future__ import annotations

import person_graph_render as render
import person_graph_store
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
                node["open"] = {
                    "type": "image",
                    "url": b["image_url"],
                    "read": b.get("text", ""),
                }
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


# --- every-other-node augmentation (NOT just story bullets) ----------------

# Reserved emergent id prefixes the live writers own (see
# ``person_graph_store._RESERVED_EMERGENT_PREFIXES``), mapped to the graph
# node ``kind`` the client renders. Order matters (most specific first).
_PREFIX_KIND: tuple[tuple[str, str], ...] = (
    ("emergent.appearance.", "report"),
    ("emergent.webfind.", "report"),
    ("emergent.skill.", "skill"),
    ("emergent.assess.", "assess"),
    ("emergent.taste.", "taste"),
    ("emergent.steering.", "steering"),
    ("emergent.interaction.", "interaction"),
)

# Friendly labels for the meta section hubs these nodes cluster under (the
# page_type ``person_graph_render.node_page_type`` maps them to).
_META_SECTION_LABELS = {
    "appearance": "Appearance",
    "web_findings": "Web findings",
    "steering": "Steering",
    "interactions": "Interactions",
    "assessment": "Ayma's assessment",
    "face_analysis": "Face analysis",
    "body_analysis": "Body analysis",
}

_KIND_DEFAULT_LABEL = {
    "report": "Report",
    "image": "Photo",
    "skill": "Report",
    "assess": "Ayma's read",
    "taste": "Taste",
    "steering": "Steering",
    "interaction": "Interaction",
}

_WEBFIND_REPORT_PREFIX = "emergent.webfind.report."
_APPEARANCE_PREFIX = "emergent.appearance."
_IMAGE_PREFIX = "emergent.image."


def _node_kind(nid: str, node) -> str | None:
    """The graph ``kind`` for a store node, or ``None`` when it is a plain
    story/seed node already covered by the bullet pass (so it is not drawn
    twice)."""
    if getattr(node, "answer_type", None) == "image" or nid.startswith(_IMAGE_PREFIX):
        return "image"
    for prefix, kind in _PREFIX_KIND:
        if nid.startswith(prefix):
            return kind
    return None


def _vis_str(node) -> str:
    v = getattr(node, "visibility", None)
    if v is None:
        return VIS_PRIVATE
    s = v.value if hasattr(v, "value") else str(v)
    # The graph store's Visibility enum spells Ayma-only "ayma_only"; the story
    # bullet path + the client's visibility colours use "ai_only". Normalise to
    # the story vocab so one payload is internally consistent.
    return VIS_AI_ONLY if s == "ayma_only" else s


def _node_text(node, kind: str) -> str:
    if kind == "image":
        return (getattr(node, "image_read", None) or "")[:600]
    ans = getattr(node, "answer", None)
    return ("" if ans is None else str(ans))[:600]


def _open_target(nid: str, node, kind: str) -> dict | None:
    if kind == "image":
        # The node-driven photo viewer renders all of this straight from the
        # node (founder Nov 16): the is-you verdict, where it came from, and
        # Ayma's read.
        return {
            "type": "image",
            "url": getattr(node, "answer", None) or "",
            "read": getattr(node, "image_read", None) or "",
            "is_you": getattr(node, "is_you", None) or "unknown",
            "source_kind": getattr(node, "source_kind", None) or "",
            "source_ref": getattr(node, "source_ref", None) or "",
            "source_created_at": getattr(node, "source_created_at", None) or "",
        }
    if nid.startswith(_APPEARANCE_PREFIX):
        # The Appearance report is a single current node; the client opens the
        # latest via /appearance/current.
        return {"type": "appearance_report", "id": "current"}
    if nid.startswith(_WEBFIND_REPORT_PREFIX):
        rid = nid[len(_WEBFIND_REPORT_PREFIX):].split(".")[0]
        if rid:
            return {"type": "webfind_report", "id": rid}
    return None


def _meta_section_label(pt: str) -> str:
    if pt in _META_SECTION_LABELS:
        return _META_SECTION_LABELS[pt]
    try:
        if pt in question_tree.section_meta():
            return question_tree.section_title(pt)
    except Exception:  # noqa: BLE001
        pass
    return pt.replace("_", " ").title()


def _augment_with_store_nodes(graph: dict, db, uid: str, *, owner_only: bool) -> dict:
    """Append every graph-store node that is NOT a plain story bullet — the
    report, photo, skill, assessment, taste, steering and interaction nodes —
    grouped under their section hub, each tappable node carrying an ``open``
    target. Visibility-filtered: owner sees all, public sees public only.

    Best-effort: a store read failure leaves the bullet graph untouched rather
    than breaking the whole view."""
    try:
        eff = person_graph_store.effective(db, uid)
    except Exception:  # noqa: BLE001
        return graph

    nodes = graph["nodes"]
    edges = graph["edges"]
    existing = {n["id"] for n in nodes}
    sec_ids = {n["id"] for n in nodes if n["kind"] == "section"}
    summary = {s["page_type"]: s for s in graph["sections"]}

    # Stable order so the render is deterministic across requests.
    for nid in sorted(eff):
        if nid in existing:
            continue
        node = eff[nid]
        kind = _node_kind(nid, node)
        if kind is None:
            continue
        vis = _vis_str(node)
        if not owner_only and vis != VIS_PUBLIC:
            continue
        pt = render.node_page_type(node)
        sec_id = f"sec:{pt}"
        if sec_id not in sec_ids:
            nodes.append(
                {
                    "id": sec_id,
                    "kind": "section",
                    "page_type": pt,
                    "label": _meta_section_label(pt),
                    "subtitle": "",
                }
            )
            edges.append({"from": "me", "to": sec_id})
            sec_ids.add(sec_id)

        gnode = {
            "id": nid,
            "kind": kind,
            "page_type": pt,
            "label": (getattr(node, "prompt", "") or _KIND_DEFAULT_LABEL.get(kind, kind))[:80],
            "text": _node_text(node, kind),
            "visibility": vis,
        }
        ot = _open_target(nid, node, kind)
        if ot:
            gnode["open"] = ot
            if kind == "image":
                gnode["image_url"] = ot["url"]
        nodes.append(gnode)
        existing.add(nid)
        edges.append({"from": sec_id, "to": nid})

        s = summary.get(pt)
        if s is None:
            s = {
                "page_type": pt,
                "title": _meta_section_label(pt),
                "subtitle": "",
                "order": 900 + len(summary),
                "total": 0,
                "public": 0,
                "private": 0,
                "ai_only": 0,
            }
            graph["sections"].append(s)
            summary[pt] = s
        s["total"] += 1
        if vis in (VIS_PUBLIC, VIS_PRIVATE, VIS_AI_ONLY):
            s[vis] += 1
    return graph


def get_graph(db, uid: str, *, center_label: str = "You") -> dict:
    """The owner's full person-graph: every story bullet AND every other
    store node (reports, photos, skills, assessment, …), all visibilities."""
    sections = profile_bullets.get_bullets(db, uid).get("sections", [])
    g = _graph_from_sections(sections, owner_only=True, center_label=center_label)
    return _augment_with_store_nodes(g, db, uid, owner_only=True)


def public_graph(db, uid: str, *, center_label: str = "") -> dict:
    """Another person's graph — public bullets + public nodes only, nothing
    private/Ayma-only. The same shape as :func:`get_graph` so one renderer
    handles both."""
    sections = profile_bullets.get_bullets(db, uid).get("sections", [])
    g = _graph_from_sections(
        sections, owner_only=False, center_label=center_label or "Them"
    )
    return _augment_with_store_nodes(g, db, uid, owner_only=False)
