"""The person-graph store and write tools.

Owns the per-user overlay document ``users/{uid}/graph/main`` and the five
graph operations Ayma calls to write it (design §8.2), plus the global
relationship-type registry (design §2.4). Every write is validated through
:mod:`person_graph` at the boundary, so a malformed node can never be stored.

The overlay holds only divergences from the seed (answers, changed
weights/visibility, state, history, children, links, and emergent nodes). The
effective graph a reader sees is ``seed ⊕ overlay`` — built by
:func:`person_graph.effective_graph`; this module never duplicates seed nodes
into a user's document.

Nothing here is wired into the live LLM tool dispatch yet — these are the
validated primitives the consumer-switch phase will bind as tools.
"""

from __future__ import annotations

import secrets
from typing import Any, Optional

import person_graph as pg
import question_tree
from person_graph import NodeState, OverlayNode, Provenance, Visibility

_GRAPH_COLLECTION = "graph"
_GRAPH_DOC = "main"

# The relationship-type registry is GLOBAL (shared across every user's graph,
# like the seed): one top-level document.
_REGISTRY_COLLECTION = "graph_registry"
_REGISTRY_DOC = "relationship_types"


# --- document refs ---------------------------------------------------------


def _graph_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(_GRAPH_COLLECTION)
        .document(_GRAPH_DOC)
    )


def _registry_ref(db):
    return db.collection(_REGISTRY_COLLECTION).document(_REGISTRY_DOC)


# --- overlay load / save ---------------------------------------------------


def load_overlay(db, uid: str) -> dict[str, dict]:
    """The user's raw overlay (node_id → overlay dict). Empty if none."""
    snap = _graph_ref(db, uid).get()
    data = snap.to_dict() if snap and snap.exists else None
    return dict((data or {}).get("nodes") or {})


def _save_overlay(db, uid: str, overlay: dict[str, dict]) -> None:
    """Validate the whole overlay, then persist it. Validation at the boundary
    means a malformed node is rejected before any write (design §7.3)."""
    pg.validate_overlay(overlay)  # raises on any malformed node
    _graph_ref(db, uid).set(
        {"nodes": overlay, "updated_at": pg.now_iso()}, merge=True
    )


def replace_overlay(db, uid: str, overlay: dict[str, dict]) -> None:
    """Persist ``overlay`` as the WHOLE node set, dropping any node not in it.

    ``_save_overlay`` uses ``merge=True`` — on Firestore that deep-merges the
    ``nodes`` map, so a node removed from the dict would survive. A re-migration
    changes the node id scheme (e.g. the dedupe fix re-keyed emergent ids), so
    stale nodes must be dropped: this writes the document whole (``merge=False``)
    so the stored ``nodes`` becomes exactly ``overlay``."""
    pg.validate_overlay(overlay)
    _graph_ref(db, uid).set(
        {"nodes": overlay, "updated_at": pg.now_iso()}, merge=False
    )


def effective(db, uid: str, *, intent: str | None = None) -> dict[str, pg.GraphNode]:
    """The user's effective graph (seed ⊕ overlay) for their branch. ``intent``
    defaults to the user's stored ``relationship_intent``."""
    if intent is None:
        intent = _stored_intent(db, uid)
    return pg.effective_graph(load_overlay(db, uid), intent=intent)


def _stored_intent(db, uid: str) -> str | None:
    try:
        snap = (
            db.collection("users").document(uid)
            .collection("profile").document("main").get()
        )
        return (snap.to_dict() or {}).get("relationship_intent") if snap and snap.exists else None
    except Exception:  # noqa: BLE001
        return None


def _entry(overlay: dict[str, dict], node_id: str) -> dict:
    e = overlay.get(node_id)
    return dict(e) if isinstance(e, dict) else {}


# --- the five tools (design §8.2) -----------------------------------------


def set_answer(
    db,
    uid: str,
    node_id: str,
    answer: Any,
    *,
    provenance: Provenance | str = Provenance.STATED,
    confidence: float | None = None,
) -> OverlayNode:
    """Record an answer; set state answered and provenance. If the node already
    has a different live answer, the old one retires to an Ayma-only history
    record on the same node (design §2.5) — the new answer is the only one that
    renders or is scored."""
    if pg.seed_node(node_id) is None and node_id not in load_overlay(db, uid):
        raise ValueError(
            f"set_answer on unknown node {node_id!r}; use add_node for emergent facts"
        )
    overlay = load_overlay(db, uid)
    e = _entry(overlay, node_id)

    prov = provenance.value if isinstance(provenance, Provenance) else str(provenance)
    prev = e.get("answer")
    if prev is not None and prev != answer:
        history = list(e.get("history") or [])
        history.append(
            {
                "answer": prev,
                "date": pg.now_iso(),
                "provenance": e.get("provenance") or Provenance.STATED.value,
            }
        )
        e["history"] = history

    e["answer"] = answer
    e["state"] = NodeState.ANSWERED.value
    e["provenance"] = prov
    if confidence is not None:
        e["confidence"] = confidence
    e["updated_at"] = pg.now_iso()

    model = OverlayNode.model_validate(e)  # per-node validation
    overlay[node_id] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return model


def set_weight(db, uid: str, node_id: str, weight: float) -> OverlayNode:
    """Set a personal weight on a node. (Relative normalization across the
    user's budget is a matching concern, applied at score time — this stores
    the raw stated/inferred weight.)"""
    if pg.seed_node(node_id) is None and node_id not in load_overlay(db, uid):
        raise ValueError(f"set_weight on unknown node {node_id!r}")
    overlay = load_overlay(db, uid)
    e = _entry(overlay, node_id)
    e["weight"] = float(weight)
    e["updated_at"] = pg.now_iso()
    model = OverlayNode.model_validate(e)
    overlay[node_id] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return model


def set_visibility(
    db, uid: str, node_id: str, visibility: Visibility | str
) -> OverlayNode:
    """Set a node's visibility (public / private / ayma_only) — the user's call
    per node (design §3). Overrides the common-sense default."""
    vis = visibility.value if isinstance(visibility, Visibility) else str(visibility)
    if vis not in {v.value for v in Visibility}:
        raise ValueError(f"invalid visibility {vis!r}")
    if pg.seed_node(node_id) is None and node_id not in load_overlay(db, uid):
        raise ValueError(f"set_visibility on unknown node {node_id!r}")
    overlay = load_overlay(db, uid)
    e = _entry(overlay, node_id)
    e["visibility"] = vis
    e["updated_at"] = pg.now_iso()
    model = OverlayNode.model_validate(e)
    overlay[node_id] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return model


def add_node(
    db,
    uid: str,
    parent_id: str,
    label: str,
    *,
    answer: Any = None,
    section: str | None = None,
    answer_type: str | None = None,
    provenance: Provenance | str = Provenance.STATED,
    node_id: str | None = None,
) -> str:
    """Create an emergent node under ``parent_id`` (design §2.3): level =
    parent level + 1, homed in the parent's section unless ``section`` is given,
    private by default. Off-script facts still land in the graph. Returns the
    new node's id."""
    overlay = load_overlay(db, uid)
    parent = pg.seed_node(parent_id)
    if parent is not None:
        parent_section, parent_level = parent.section, parent.level
    else:
        pe = overlay.get(parent_id)
        if not isinstance(pe, dict):
            raise ValueError(f"add_node parent {parent_id!r} not found")
        parent_section = pe.get("section")
        parent_level = pe.get("level")
        if not parent_section or not parent_level:
            raise ValueError(f"emergent parent {parent_id!r} missing section/level")

    sec = section or parent_section
    if sec not in question_tree.section_meta():
        raise ValueError(f"unknown section {sec!r} for emergent node")

    nid = node_id or f"emergent.{secrets.token_hex(4)}"
    if nid in overlay or pg.seed_node(nid) is not None:
        raise ValueError(f"node id {nid!r} already exists")

    prov = provenance.value if isinstance(provenance, Provenance) else str(provenance)
    e: dict[str, Any] = {
        "prompt": label,
        "section": sec,
        "level": int(parent_level) + 1,
        "parent": parent_id,
        "visibility": Visibility.PRIVATE.value,
        "provenance": prov,
        "updated_at": pg.now_iso(),
    }
    if answer_type is not None:
        e["answer_type"] = answer_type
    if answer is not None:
        e["answer"] = answer
        e["state"] = NodeState.ANSWERED.value

    model = OverlayNode.model_validate(e)
    overlay[nid] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return nid


def query_nodes(
    db,
    uid: str,
    *,
    intent: str | None = None,
    section: str | None = None,
    level: int | None = None,
    state: NodeState | str | None = None,
    min_weight: float | None = None,
    emergent: bool | None = None,
) -> list[pg.GraphNode]:
    """Pull a subgraph (one section, one level, unanswered level-2 nodes, …)
    instead of loading the whole person. Reads the effective graph then filters.
    Results are in section-then-level order."""
    graph = effective(db, uid, intent=intent)
    want_state = (
        state.value if isinstance(state, NodeState) else (str(state) if state else None)
    )

    out: list[pg.GraphNode] = []
    for n in graph.values():
        if section is not None and n.section != section:
            continue
        if level is not None and n.level != level:
            continue
        if want_state is not None and n.state.value != want_state:
            continue
        if min_weight is not None and n.weight < min_weight:
            continue
        if emergent is not None and n.emergent is not emergent:
            continue
        out.append(n)

    out.sort(key=lambda n: (question_tree.section_order(n.section), n.level, n.id))
    return out


# --- relationship-type registry (design §2.4) ------------------------------

# Strict types are always present; free-form types are added here and reused
# (the condition on §2.4 — Ayma checks the registry before minting, to stop
# synonym drift).
_STRICT_REGISTRY = {
    t.value: {"name": t.value, "definition": d, "strict": True}
    for t, d in {
        pg.StrictLinkType.ELABORATES: "this node expands on that one",
        pg.StrictLinkType.DEPENDS_ON: "this node's answer only makes sense alongside that one",
        pg.StrictLinkType.SAME_TOPIC: "same subject, different home",
        pg.StrictLinkType.SAME_PERSON: "about the same person",
        pg.StrictLinkType.CONTRADICTS: "the two nodes conflict",
    }.items()
}


def get_link_types(db) -> dict[str, dict]:
    """The full relationship-type registry: the strict set plus every free-form
    type ever minted (canonical name + definition)."""
    snap = _registry_ref(db).get()
    stored = (snap.to_dict() if snap and snap.exists else None) or {}
    out = dict(_STRICT_REGISTRY)
    for name, meta in (stored.get("types") or {}).items():
        if name not in out:  # strict types are canonical, never overridden
            out[name] = meta
    return out


def register_link_type(db, name: str, definition: str) -> dict:
    """Mint (or reuse) a free-form relationship type. Ayma must check the
    registry for a fitting existing type first (synonym-drift guard, §2.4); this
    enforces the mechanical side: a strict name can't be redefined, and an
    existing free-form name returns its canonical definition unchanged."""
    name = (name or "").strip()
    if not name:
        raise ValueError("relationship type needs a name")
    if name in _STRICT_REGISTRY:
        return _STRICT_REGISTRY[name]
    existing = get_link_types(db)
    if name in existing:
        return existing[name]
    if not (definition or "").strip():
        raise ValueError(f"new relationship type {name!r} needs a definition")
    entry = {"name": name, "definition": definition.strip(), "strict": False}
    snap = _registry_ref(db).get()
    stored = (snap.to_dict() if snap and snap.exists else None) or {}
    types = dict(stored.get("types") or {})
    types[name] = entry
    _registry_ref(db).set({"types": types}, merge=True)
    return entry
