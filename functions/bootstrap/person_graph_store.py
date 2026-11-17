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
from typing import Any, Iterable, Optional

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


def overlay_mtime(db, uid: str):
    """The overlay document's ``updated_at`` as a timezone-aware ``datetime``,
    or ``None`` if there is no overlay / no stamp / it can't be parsed. Every
    graph write (``set_answer``, profile/intent edits, etc.) bumps this stamp,
    so it is the graph-native replacement for the ``profile/main`` +
    ``questionnaire`` ``updated_at`` signals the match-staleness check reads."""
    from datetime import datetime

    try:
        snap = _graph_ref(db, uid).get()
        data = snap.to_dict() if snap and snap.exists else None
        raw = (data or {}).get("updated_at")
        if not raw:
            return None
        if hasattr(raw, "isoformat") and not isinstance(raw, str):
            return raw  # already a datetime (Firestore timestamp)
        return datetime.fromisoformat(str(raw))
    except Exception:  # noqa: BLE001 - a bad/absent stamp just yields no signal
        return None


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


def _dedupe_collapse_id(
    db, uid: str, text: str, *, section: str | None = None
) -> Optional[str]:
    """Write-time prevention (node-dedupe, founder Nov 17). When
    ``CONFIG.node_dedupe_prevention`` is on and ``text`` is an EXACT normalized
    match for an existing node's content, return that node's id so the caller
    reuses it instead of minting a duplicate. Exact-only = high precision, no
    silent fuzzy merge — near/semantic duplicates route to the user-confirmed
    cross-check resolution, never a silent write.

    Flag-off (the default) returns ``None`` so every creation path behaves
    exactly as before; best-effort — any failure returns ``None`` and never
    blocks a write. Kept here as a single localized hook (one call site per
    free-minting path) so Track A's image-node changes merge cleanly."""
    from config import CONFIG

    if not getattr(CONFIG, "node_dedupe_prevention", False):
        return None
    try:
        import person_graph_index as _index

        idx = _index.build_index(db, uid)
        return _index.find_exact_match(idx, text, section=section)
    except Exception:  # noqa: BLE001 - prevention is best-effort, never blocks
        return None


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

    # Write-time prevention: an off-script fact that exactly restates an
    # existing node reuses it instead of minting a duplicate (answer-bearing
    # nodes only — a bare structural label is never collapsed).
    if node_id is None and answer is not None:
        hit = _dedupe_collapse_id(db, uid, str(answer), section=sec)
        if hit is not None:
            return hit

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


def add_loose_node(
    db,
    uid: str,
    fact: str,
    *,
    label: str | None = None,
    section: str = "misc",
    provenance: Provenance | str = Provenance.STATED,
    node_id: str | None = None,
) -> str:
    """Record a free-form fact the user volunteered — the graph write path for
    the ``remember`` tool when the person-graph is authoritative (NOTE 228).

    Unlike :func:`add_node`, it needs NO parent: an off-script fact rarely has a
    seed node it grows out of, and the empty ``misc`` (Little Extras, design
    §9.3) section has no seed node to parent under. So this creates a STAND-ALONE
    emergent node — narrative, private, provenance STATED, homed in ``section``
    at level 1. Renders order nodes by section (not by a parent tree), so a
    parentless node shows under its section. Returns the new node's id."""
    fact = (fact or "").strip()
    if not fact:
        raise ValueError("add_loose_node needs a non-empty fact")
    if section not in question_tree.section_meta():
        raise ValueError(f"unknown section {section!r} for loose node")
    # Write-time prevention: an exact restatement reuses the existing node.
    if node_id is None:
        hit = _dedupe_collapse_id(db, uid, fact, section=section)
        if hit is not None:
            return hit
    overlay = load_overlay(db, uid)
    nid = node_id or f"emergent.{secrets.token_hex(4)}"
    if nid in overlay or pg.seed_node(nid) is not None:
        raise ValueError(f"node id {nid!r} already exists")
    prov = provenance.value if isinstance(provenance, Provenance) else str(provenance)
    e: dict[str, Any] = {
        "prompt": (label or fact)[:120],
        "section": section,
        "level": 1,
        "answer_type": "narrative",
        "answer": fact,
        "state": NodeState.ANSWERED.value,
        "visibility": Visibility.PRIVATE.value,
        "provenance": prov,
        "updated_at": pg.now_iso(),
    }
    model = OverlayNode.model_validate(e)
    overlay[nid] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return nid


def node_overlay_entry(db, uid: str, node_id: str) -> dict:
    """The raw overlay entry for ``node_id`` (``{}`` if the user has none) — a
    writer that appends to / promotes an existing emergent node reads its current
    ``answer`` / ``visibility`` from here instead of the wiki doc it replaced."""
    return _entry(load_overlay(db, uid), node_id)


def set_image_read(db, uid: str, node_id: str, image_read: str) -> bool:
    """Update just the ``image_read`` (Ayma's read) of an existing image node.
    Used by the second-person photo-read backfill (founder rule Nov 17). Returns
    False (no-op) if the node isn't an overlay image node."""
    overlay = load_overlay(db, uid)
    e = overlay.get(node_id)
    if not isinstance(e, dict) or e.get("answer_type") != "image":
        return False
    e = dict(e)
    e["image_read"] = (image_read or "").strip()
    e["updated_at"] = pg.now_iso()
    overlay[node_id] = OverlayNode.model_validate(e).model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return True


def upsert_fact_node(
    db,
    uid: str,
    node_id: str,
    text: str,
    *,
    section: str = "misc",
    visibility: Visibility | str = Visibility.PRIVATE,
    provenance: Provenance | str = Provenance.STATED,
    level: int = 2,
    label: str | None = None,
    answer_type: str = "narrative",
    confidence: float | None = None,
    children: list[dict] | None = None,
) -> str:
    """Create-or-overwrite a stand-alone emergent node at a **stable** id — the
    graph write path for the live content writers that used to upsert a single
    wiki page (skill reports, Ayma's assessment, steering, taste, and the Your
    Story editor). Unlike :func:`add_loose_node` / :func:`add_node`, which mint a
    fresh node and refuse an existing id, this is idempotent: re-writing the same
    ``node_id`` replaces that node's content in place (same semantics the wiki
    ``doc.set(merge=True)`` had), so a nightly re-run or a re-generated report
    never duplicates. ``node_id`` carries the content's kind as a prefix
    (``emergent.skill.web_findings``, ``emergent.steering.<h>``, …) so the
    grounding renderer can map it back to a wiki-style page_type for the
    context-diet filters. Returns ``node_id``."""
    text = (text or "").strip()
    if not text:
        raise ValueError("upsert_fact_node needs non-empty text")
    if section not in question_tree.section_meta():
        raise ValueError(f"unknown section {section!r} for fact node")
    if pg.seed_node(node_id) is not None:
        raise ValueError(f"{node_id!r} is a seed node; use set_answer")
    vis = visibility.value if isinstance(visibility, Visibility) else str(visibility)
    if vis not in {v.value for v in Visibility}:
        raise ValueError(f"invalid visibility {vis!r}")
    prov = provenance.value if isinstance(provenance, Provenance) else str(provenance)
    overlay = load_overlay(db, uid)
    e: dict[str, Any] = {
        "prompt": (label or text)[:120],
        "section": section,
        "level": int(level),
        "answer_type": answer_type,
        "answer": text,
        "state": NodeState.ANSWERED.value,
        "visibility": vis,
        "provenance": prov,
        "updated_at": pg.now_iso(),
    }
    if confidence is not None:
        e["confidence"] = confidence
    if children:
        e["children"] = children
    model = OverlayNode.model_validate(e)
    overlay[node_id] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return node_id


def upsert_report_node(
    db,
    uid: str,
    node_id: str,
    payload: dict,
    *,
    label: str = "report",
    section: str = "misc",
) -> str:
    """Create-or-overwrite the dedicated, Ayma-only REPORT node that carries a
    full report's structured payload (the appearance-report dict, or a web-dive
    digest+meta dict) as its ``answer`` — the graph home for the report screens
    now that the ``appearance_reports`` / ``deep_dives`` collections are deleted
    (reports-as-nodes, founder Nov 16). The report VIEW is rebuilt from this node
    (``report_adapters`` reads ``answer`` back and reshapes identically); the
    human findings also feed the per-section grounding nodes
    (``emergent.skill.*``) for the person model, which own the public/match leak.

    ``answer_type == "report_doc"`` marks it as non-rendering scaffolding — it is
    never a Your Story / public / grounding bullet (:mod:`person_graph_render`
    skips it). Ayma-only visibility + provenance ``inferred``: report-derived,
    unconfirmed until the user confirms it in conversation (settled Nov 15 rule).
    Idempotent by ``node_id`` (one report node per kind/key), so a re-run or a
    correction overwrites it in place. Returns ``node_id``."""
    if not isinstance(payload, dict):
        raise ValueError("upsert_report_node needs a dict payload")
    if pg.seed_node(node_id) is not None:
        raise ValueError(f"{node_id!r} is a seed node")
    if section not in question_tree.section_meta():
        raise ValueError(f"unknown section {section!r} for report node")
    overlay = load_overlay(db, uid)
    e: dict[str, Any] = {
        "prompt": (label or "report")[:120],
        "section": section,
        "level": 2,
        "answer_type": "report_doc",
        "answer": payload,
        "state": NodeState.ANSWERED.value,
        "visibility": Visibility.AYMA_ONLY.value,
        "provenance": Provenance.INFERRED.value,
        "updated_at": pg.now_iso(),
    }
    model = OverlayNode.model_validate(e)
    overlay[node_id] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return node_id


def report_node_payload(db, uid: str, node_id: str) -> dict:
    """The stored payload dict of a report node (:func:`upsert_report_node`), or
    ``{}`` when the user has no such node. The report adapters read a report view
    straight back from here with ``person_graph_reads`` on, so the report screen
    renders from the graph with the old collection gone."""
    e = node_overlay_entry(db, uid, node_id)
    ans = e.get("answer") if isinstance(e, dict) else None
    return dict(ans) if isinstance(ans, dict) else {}


def set_visibility_cascade(
    db, uid: str, node_id: str, visibility: Visibility | str
) -> int:
    """Set ``node_id`` AND every descendant to ``visibility`` (the Node Visualiser
    cascade rule, founder Nov 17): making a parent public/private makes its whole
    subtree the same — EXCEPT ayma_only nodes, which are exempt and keep their
    ayma_only visibility (read-only Ayma knowledge). Individual children can be
    changed afterwards (which is how a parent becomes mixed again). Only overlay
    nodes are written; a seed node gets a visibility override in the overlay like
    ``set_visibility`` does. Returns the count of nodes changed."""
    import person_graph_tree as tree

    vis = visibility.value if isinstance(visibility, Visibility) else str(visibility)
    if vis not in {v.value for v in Visibility}:
        raise ValueError(f"invalid visibility {vis!r}")
    if pg.seed_node(node_id) is None and node_id not in load_overlay(db, uid):
        raise ValueError(f"set_visibility_cascade on unknown node {node_id!r}")

    graph = effective(db, uid)
    targets = [node_id] + tree.descendant_ids(graph, node_id)
    overlay = load_overlay(db, uid)
    changed = 0
    for nid in targets:
        node = graph.get(nid)
        # ayma_only nodes are exempt — the cascade never touches Ayma's knowledge.
        if node is not None and node.visibility is Visibility.AYMA_ONLY:
            continue
        e = _entry(overlay, nid)
        if e.get("visibility") == vis:
            continue
        e["visibility"] = vis
        e["updated_at"] = pg.now_iso()
        overlay[nid] = OverlayNode.model_validate(e).model_dump(exclude_none=True)
        changed += 1
    if changed:
        _save_overlay(db, uid, overlay)
    return changed


def add_child_node(
    db,
    uid: str,
    parent_id: str,
    label: str,
    *,
    answer: Any = None,
    answer_type: str | None = None,
    visibility: Visibility | str | None = None,
    node_id: str | None = None,
) -> str:
    """Add a child node under ``parent_id`` inside the visualiser — the manual
    "add a line at any level" path (replaces per-section Add). Thin wrapper over
    :func:`add_node`; optionally sets the child's visibility after creation (a
    child defaults private like any emergent node). A manual line's TEXT is its
    content, so when no explicit ``answer`` is given the ``label`` becomes the
    answer (an emergent node renders its answer verbatim) — a bare label with no
    answer would otherwise not render. Returns the new node's id."""
    nid = add_node(
        db, uid, parent_id, label,
        answer=answer if answer is not None else label,
        answer_type=answer_type or "narrative",
        node_id=node_id,
    )
    if visibility is not None:
        set_visibility(db, uid, nid, visibility)
    return nid


def set_node_text(db, uid: str, node_id: str, text: str) -> str:
    """Edit one node's text manually (the "Edit manually" bubble). A seed node's
    answer goes through :func:`set_answer` (answer history preserved); an
    editor-owned emergent node has its ``answer`` (and ``prompt``, which an
    emergent node renders verbatim) replaced, superseded text retired to Ayma-only
    history. Returns ``node_id``. Raises on an unknown or non-editable node."""
    text = (text or "").strip()
    if not text:
        raise ValueError("set_node_text needs non-empty text")
    if pg.seed_node(node_id) is not None:
        set_answer(db, uid, node_id, text)
        return node_id
    overlay = load_overlay(db, uid)
    e = overlay.get(node_id)
    if not isinstance(e, dict):
        raise ValueError(f"set_node_text on unknown node {node_id!r}")
    if e.get("visibility") == Visibility.AYMA_ONLY.value:
        raise ValueError("ayma_only nodes are read-only")
    prev = e.get("answer")
    if prev is not None and str(prev) != text:
        history = list(e.get("history") or [])
        history.append(
            {
                "answer": prev,
                "date": pg.now_iso(),
                "provenance": e.get("provenance") or Provenance.STATED.value,
            }
        )
        e["history"] = history
    e = dict(e)
    e["answer"] = text
    e["prompt"] = text[:120]
    e["state"] = NodeState.ANSWERED.value
    e["updated_at"] = pg.now_iso()
    overlay[node_id] = OverlayNode.model_validate(e).model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return node_id


def descendant_count(db, uid: str, node_id: str) -> int:
    """How many descendant nodes go with ``node_id`` if it is deleted — the count
    the delete-confirmation names ("delete this and its N children?")."""
    import person_graph_tree as tree

    return len(tree.descendant_ids(effective(db, uid), node_id))


def delete_node_with_descendants(db, uid: str, node_id: str) -> int:
    """Delete ``node_id`` and its whole subtree. Only EDITOR-owned emergent nodes
    are actually removed (a seed node or a reserved live-writer node is left in
    place, as :func:`delete_nodes` already guards). Returns the count removed."""
    import person_graph_tree as tree

    ids = [node_id] + tree.descendant_ids(effective(db, uid), node_id)
    return delete_nodes(db, uid, ids)


def delete_nodes(db, uid: str, node_ids: Iterable[str]) -> int:
    """Remove emergent overlay nodes by id (no-op for a seed node or an id the
    user doesn't have). Returns the count removed. Used by the Your Story editor
    to drop a bullet, and to clear a section before re-writing it. Writes the
    overlay whole (``replace_overlay``) so the dropped keys are truly gone — a
    ``merge=True`` save would resurrect them."""
    ids = {str(n) for n in node_ids if n}
    if not ids:
        return 0
    overlay = load_overlay(db, uid)
    removed = 0
    for nid in list(ids):
        if nid in overlay and pg.seed_node(nid) is None:
            del overlay[nid]
            removed += 1
    if removed:
        replace_overlay(db, uid, overlay)
    return removed


# Emergent id prefixes a live writer owns — never editor (Your Story) content,
# so a section edit must leave them in place.
_RESERVED_EMERGENT_PREFIXES = (
    "emergent.skill.",
    "emergent.taste.",
    "emergent.steering.",
    "emergent.assess.",
    "emergent.webfind.",
    "emergent.appearance.",
    "emergent.image.",
    "emergent.interaction.",
)


def _is_editor_owned(node_id: str) -> bool:
    """True for a Your Story editor-owned emergent node — a migrated story
    bullet, a prior editor bullet, or a bare ``emergent.<hex>`` loose fact — but
    not a reserved-kind node a live writer owns (skill/taste/steering/…)."""
    if not node_id.startswith("emergent."):
        return False
    return not any(node_id.startswith(p) for p in _RESERVED_EMERGENT_PREFIXES)


def _free_editor_id(overlay: dict[str, dict], section: str) -> str:
    """The first unused ``emergent.editor.<section>.<n>`` id — so a new bullet
    never collides with a preserved node that kept that id."""
    i = 0
    while f"emergent.editor.{section}.{i}" in overlay:
        i += 1
    return f"emergent.editor.{section}.{i}"


def replace_section_bullets(
    db, uid: str, section: str, bullets: list[dict]
) -> list[str]:
    """The Your Story editor write-back (design §8.1): make ``bullets`` the
    section's editor-visible content in the graph, **preserving node identity**
    (the settled ANSWER HISTORY rule). The editor owns a section's
    **public/private emergent** nodes; **seed** nodes (structured questionnaire
    answers) and **ayma_only** emergent nodes (steering, assessment) are left
    untouched, so no structured fact or Ayma-only note is ever dropped by a
    story edit.

    Each bullet is ``{"id"?, "text", "visibility"}``. For every incoming bullet:

    * matched to an existing editor-owned node (by its ``id``, else by exact
      text for the id-less in-chat path) → that node is **kept**: its id and
      level are preserved, and if the text changed the **superseded text retires
      to the node's Ayma-only dated ``history``** (never rendered in Your Story
      or the public profile, never scored — a change of heart is itself a fact),
      with the new text as the live answer;
    * unmatched → a **new** ``emergent.editor.<section>.<n>`` node (new id).

    An existing editor-owned node that no incoming bullet matches is **deleted**
    (the user removed that bullet) — a delete owes no history entry. Returns the
    section's bullet ids in order. Closes the NOTE 230 write-back gap without the
    whole-section re-serialization Scout NOTE 232 Leg 3 flagged."""
    if section not in question_tree.section_meta():
        raise ValueError(f"unknown section {section!r}")
    overlay = load_overlay(db, uid)

    # The section's current editor-owned nodes (emergent, public/private): the
    # migrated story bullets (``emergent.story.*``), prior editor bullets
    # (``emergent.editor.*``) and free-form remembered facts (bare
    # ``emergent.<hex>`` loose nodes). Reserved-kind nodes (skill reports, the
    # Qloo taste node, steering, assessment, images, …) are NOT editor content
    # and are preserved even in the same section.
    editor_vis = {None, Visibility.PUBLIC.value, Visibility.PRIVATE.value}
    existing = {
        n: e for n, e in overlay.items()
        if isinstance(e, dict)
        and pg.seed_node(n) is None
        and e.get("section") == section
        and e.get("visibility") in editor_vis
        and _is_editor_owned(n)
    }
    # id-less bullets (the in-chat free-text path) match an unchanged node by its
    # exact current text, so a reorder / visibility flip keeps the node's id.
    by_text: dict[str, list[str]] = {}
    for nid, e in existing.items():
        by_text.setdefault(str(e.get("answer") or "").strip(), []).append(nid)

    consumed: set[str] = set()
    result_ids: list[str] = []

    for b in bullets or []:
        text = str(b.get("text") or "").strip()
        if not text:
            continue
        vis = str(b.get("visibility") or Visibility.PRIVATE.value)
        if vis not in {v.value for v in Visibility} or vis == Visibility.AYMA_ONLY.value:
            vis = Visibility.PRIVATE.value  # the editor never writes ayma_only

        bid = str(b.get("id") or "")
        match: str | None = None
        if bid and bid in existing and bid not in consumed:
            match = bid
        elif not bid:
            for cand in by_text.get(text, []):
                if cand not in consumed:
                    match = cand
                    break

        if match is not None:
            e = dict(existing[match])
            prev = e.get("answer")
            if prev is not None and str(prev) != text:
                # Retire the superseded text to Ayma-only dated history on the
                # SAME node (mirrors ``set_answer``). History is never rendered.
                history = list(e.get("history") or [])
                history.append(
                    {
                        "answer": prev,
                        "date": pg.now_iso(),
                        "provenance": e.get("provenance") or Provenance.STATED.value,
                    }
                )
                e["history"] = history
            e["answer"] = text
            e["prompt"] = text[:120]
            e["visibility"] = vis
            e["state"] = NodeState.ANSWERED.value
            e["updated_at"] = pg.now_iso()
            # level, section, answer_type, provenance preserved as-is.
            overlay[match] = OverlayNode.model_validate(e).model_dump(exclude_none=True)
            consumed.add(match)
            result_ids.append(match)
        else:
            nid = _free_editor_id(overlay, section)
            overlay[nid] = OverlayNode.model_validate(
                {
                    "prompt": text[:120],
                    "section": section,
                    "level": 2,
                    "answer_type": "narrative",
                    "answer": text,
                    "state": NodeState.ANSWERED.value,
                    "visibility": vis,
                    "provenance": Provenance.STATED.value,
                    "updated_at": pg.now_iso(),
                }
            ).model_dump(exclude_none=True)
            consumed.add(nid)
            result_ids.append(nid)

    # Any editor-owned node no incoming bullet matched was removed by the user.
    for nid in existing:
        if nid not in consumed:
            del overlay[nid]

    replace_overlay(db, uid, overlay)
    return result_ids


def set_section_visibility(db, uid: str, section: str, visibility: Visibility | str) -> int:
    """Set every editor-owned node in ``section`` to ``visibility`` — the graph
    equivalent of flipping a Your Story section's page visibility (the in-chat
    story edit path). Seed and reserved-kind nodes are untouched. Returns the
    count changed."""
    vis = visibility.value if isinstance(visibility, Visibility) else str(visibility)
    if vis not in {v.value for v in Visibility}:
        raise ValueError(f"invalid visibility {vis!r}")
    overlay = load_overlay(db, uid)
    editor_vis = {None, Visibility.PUBLIC.value, Visibility.PRIVATE.value}
    changed = 0
    for nid, e in overlay.items():
        if (
            isinstance(e, dict)
            and pg.seed_node(nid) is None
            and e.get("section") == section
            and e.get("visibility") in editor_vis
            and _is_editor_owned(nid)
        ):
            e["visibility"] = vis
            changed += 1
    if changed:
        _save_overlay(db, uid, overlay)
    return changed


def image_nodes_for_view(db, uid: str, *, public_only: bool = False) -> list[dict]:
    """Every graph IMAGE node for the photo view, newest first. Each row carries
    what the viewer renders straight from the node — the Storage ``url``, Ayma's
    ``read`` (``image_read``), the structured ``is_you`` verdict, and the SOURCE
    provenance (``source_kind``/``source_ref``/``source_created_at``) — plus the
    node ``id`` (content-hash keyed) and ``visibility`` for the owner actions.
    This is the node-driven replacement for the legacy ``photo_notes`` assembly
    (which keyed by URL hash and orphaned on token rotation). ``public_only``
    returns just the public images (the public profile)."""
    eff = effective(db, uid)
    rows: list[dict] = []
    for nid, node in eff.items():
        if getattr(node, "answer_type", None) != "image":
            continue
        url = str(getattr(node, "answer", "") or "")
        if not url:
            continue
        vis = getattr(node, "visibility", None)
        vis_s = vis.value if hasattr(vis, "value") else str(vis or "private")
        if public_only and vis_s != "public":
            continue
        rows.append(
            {
                "id": nid,
                "url": url,
                "read": str(getattr(node, "image_read", "") or ""),
                "is_you": str(getattr(node, "is_you", "") or "unknown") or "unknown",
                "source_kind": str(getattr(node, "source_kind", "") or ""),
                "source_ref": str(getattr(node, "source_ref", "") or ""),
                "source_created_at": str(getattr(node, "source_created_at", "") or ""),
                "visibility": vis_s,
            }
        )
    rows.sort(key=lambda r: r["source_created_at"], reverse=True)
    return rows


def is_you_from_verdict(verdict: str | None) -> str:
    """Map a face-match verdict (photo_pipeline ``face_verdict`` — "of user" /
    "other" / "unknown", or a bare "yes"/"no") to the structured image-node
    ``is_you`` field ("yes" / "no" / "unknown"). Unknown/blank → "unknown"."""
    v = (verdict or "").strip().lower()
    if not v or v in ("unknown", "unsure", "maybe"):
        return "unknown"
    if v in ("yes", "you", "self") or "user" in v or "of user" in v:
        return "yes"
    if v == "no" or "other" in v or "not you" in v or "someone else" in v:
        return "no"
    return "unknown"


def add_image_node(
    db,
    uid: str,
    parent_id: str,
    image_url: str,
    image_read: str,
    *,
    visibility: Visibility | str = Visibility.PRIVATE,
    section: str | None = None,
    links: list[dict] | None = None,
    node_id: str | None = None,
    is_you: str = "",
    source_kind: str = "",
    source_ref: str = "",
    source_created_at: str | None = None,
) -> str:
    """Create-or-update an emergent IMAGE node under ``parent_id`` (design §6,
    "images are nodes"): an ``answer_type == "image"`` node whose ``answer``
    holds the Firebase Storage ``image_url`` and ``image_read`` holds Ayma's
    read of the image. Also carries the structured face-match verdict
    (``is_you`` — "yes"/"no"/"unknown") and the SOURCE provenance
    (``source_kind`` ∈ chat|appearance_report|profile_grid|web, ``source_ref``
    the conversation/report id, ``source_created_at`` the first-ingest time) —
    distinct from the epistemic ``provenance``. Private by default; ``links``
    (typed related links, §2.4) connect it to the fact/report nodes it belongs
    to — a reference, never a copy.

    **UPSERT on ``node_id``** (which the callers key by image CONTENT hash, so a
    re-ingest of the same bytes lands on the same node): if that image node
    already exists it is UPDATED in place — never duplicated — preserving the
    user's own visibility choice, the original ``source_created_at``, prior
    links, and any good prior verdict/source the new call leaves blank. Raises
    only if ``node_id`` collides with a seed node or a non-image overlay node.
    Returns the node id."""
    overlay = load_overlay(db, uid)
    parent = pg.seed_node(parent_id)
    if parent is not None:
        parent_section, parent_level = parent.section, parent.level
    else:
        pe = overlay.get(parent_id)
        if not isinstance(pe, dict):
            raise ValueError(f"add_image_node parent {parent_id!r} not found")
        parent_section = pe.get("section")
        parent_level = pe.get("level")
        if not parent_section or not parent_level:
            raise ValueError(f"emergent parent {parent_id!r} missing section/level")

    if not (image_url or "").strip():
        raise ValueError("add_image_node needs an image_url")

    sec = section or parent_section
    if sec not in question_tree.section_meta():
        raise ValueError(f"unknown section {sec!r} for image node")

    vis = visibility.value if isinstance(visibility, Visibility) else str(visibility)
    if vis not in {v.value for v in Visibility}:
        raise ValueError(f"invalid visibility {vis!r}")

    nid = node_id or f"emergent.image.{secrets.token_hex(4)}"
    raw_existing = overlay.get(nid)
    prev = (
        raw_existing
        if isinstance(raw_existing, dict) and raw_existing.get("answer_type") == "image"
        else None
    )
    # Collision with a seed node, or a non-image overlay node, is a real error.
    if pg.seed_node(nid) is not None or (raw_existing is not None and prev is None):
        raise ValueError(f"node id {nid!r} already exists")

    now = pg.now_iso()
    base = prev or {}
    # A stored overlay value may be an enum (model_dump python mode) or a plain
    # string — normalise before reuse so an upsert doesn't re-serialize
    # "Visibility.PRIVATE".
    prev_vis_raw = base.get("visibility")
    prev_vis = (
        prev_vis_raw.value if hasattr(prev_vis_raw, "value")
        else (str(prev_vis_raw) if prev_vis_raw else "")
    )
    read = (image_read or "").strip() or str(base.get("image_read") or "")
    e: dict[str, Any] = {
        "prompt": (read or "image").strip()[:120] or "image",
        "section": sec,
        "level": int(parent_level) + 1,
        "parent": parent_id,
        "answer_type": "image",
        "answer": image_url,
        "image_read": read,
        "state": NodeState.ANSWERED.value,
        # Keep the user's own visibility choice on a re-ingest; use the passed
        # default only when the node is brand new.
        "visibility": prev_vis or vis,
        "provenance": Provenance.STATED.value,
        "updated_at": now,
        # First-ingest time is sticky; never reset on a later re-ingest.
        "source_created_at": source_created_at or str(base.get("source_created_at") or now),
    }
    # Prefer a fresh non-empty verdict/source; otherwise keep any prior value.
    is_you_v = (is_you or str(base.get("is_you") or "")).strip()
    if is_you_v:
        e["is_you"] = is_you_v
    source_kind_v = (source_kind or str(base.get("source_kind") or "")).strip()
    if source_kind_v:
        e["source_kind"] = source_kind_v
    source_ref_v = (source_ref or str(base.get("source_ref") or "")).strip()
    if source_ref_v:
        e["source_ref"] = source_ref_v
    # Merge links (preserve existing, add any new — a reference, never a copy).
    merged_links = [l for l in (base.get("links") or []) if isinstance(l, dict)]
    for l in links or []:
        if l not in merged_links:
            merged_links.append(l)
    if merged_links:
        e["links"] = merged_links

    model = OverlayNode.model_validate(e)
    overlay[nid] = model.model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return nid


def add_link(
    db, uid: str, node_id: str, target: str, link_type: str, *, label: str | None = None
) -> bool:
    """Add a typed link ``node_id → target`` (design §2.4 — a reference, never a
    copy). Only works on an overlay node (a seed node's links are fixed). No-op
    (returns False) if the node is missing or an identical link already exists,
    so it is safe to re-run. Returns True when a link was added."""
    overlay = load_overlay(db, uid)
    e = overlay.get(node_id)
    if not isinstance(e, dict):
        return False
    links = list(e.get("links") or [])
    if any(
        isinstance(l, dict) and l.get("target") == target and l.get("type") == link_type
        for l in links
    ):
        return False
    link = {"target": target, "type": link_type}
    if label:
        link["label"] = label
    links.append(link)
    e = dict(e)
    e["links"] = links
    overlay[node_id] = OverlayNode.model_validate(e).model_dump(exclude_none=True)
    _save_overlay(db, uid, overlay)
    return True


def add_photo_fact(
    db,
    uid: str,
    *,
    image_url: str,
    image_read: str,
    fact_text: str,
    visibility: Visibility | str = Visibility.PRIVATE,
    image_node_id: str | None = None,
    is_you: str = "",
    source_kind: str = "chat",
    source_ref: str = "",
    source_created_at: str | None = None,
) -> tuple[str, str] | None:
    """Home a chat-shared photo **with its fact** (founder decision Nov 16:
    "each photo sits with its fact", NOT a Photos section). Creates the fact
    node through the existing loose-node path and an image node under it, with a
    two-way typed link between them (a reference, never a copy):

    * ``fact_text`` → a loose fact node (:func:`add_loose_node`, Little Extras /
      ``misc``) — the fact the photo belongs to;
    * ``image_url`` + ``image_read`` → an image node homed under that fact
      (:func:`add_image_node`), ``elaborates`` → the fact; the fact links back
      ``same_topic`` → the image.

    The image node carries the face-match verdict (``is_you``) and SOURCE
    provenance (``source_kind``/``source_ref``/``source_created_at``).

    On ``image_node_id`` (content-hash keyed): if that image node already exists
    (same bytes re-shared), it is UPDATED in place — a fresher read/verdict is
    written, no duplicate fact is minted — and ``None`` is returned. Returns
    ``(fact_id, image_id)`` only on a fresh home. The image's visibility is the
    common-sense default (private); the user can change it like any node."""
    existing = (
        node_overlay_entry(db, uid, image_node_id) if image_node_id else None
    )
    if existing:
        # Re-share of the same bytes: refresh the image node in place under its
        # existing parent fact (don't mint a duplicate fact node).
        parent_id = str(existing.get("parent") or "")
        if parent_id:
            add_image_node(
                db, uid, parent_id, image_url, image_read,
                visibility=visibility, node_id=image_node_id,
                is_you=is_you, source_kind=source_kind, source_ref=source_ref,
                source_created_at=source_created_at,
                links=[{"target": parent_id, "type": pg.StrictLinkType.ELABORATES.value}],
            )
        return None
    fact = (fact_text or "").strip() or (image_read or "").strip() or "a photo I shared"
    fact_id = add_loose_node(db, uid, fact)
    image_id = add_image_node(
        db, uid, fact_id, image_url, image_read,
        visibility=visibility, node_id=image_node_id,
        is_you=is_you, source_kind=source_kind, source_ref=source_ref,
        source_created_at=source_created_at,
        links=[{"target": fact_id, "type": pg.StrictLinkType.ELABORATES.value}],
    )
    add_link(db, uid, fact_id, image_id, pg.StrictLinkType.SAME_TOPIC.value)
    return fact_id, image_id


def image_node_id_for_bytes(img_bytes: bytes) -> str:
    """The canonical, content-addressed image-node id (design §6, "images are
    nodes"): the SAME photo bytes always map to the SAME node, so a re-ingest of
    identical content on any path (chat / profile grid / appearance report)
    collapses onto one node instead of minting a duplicate. Web images have no
    stable bytes in hand and key on their URL instead (see
    :func:`image_node_id_for_url`)."""
    import hashlib

    return "emergent.image." + hashlib.sha1(img_bytes).hexdigest()[:8]


def image_node_id_for_url(url: str) -> str:
    """Content-free image-node id for a web image: keyed on its stable URL (the
    bytes aren't retained on the web-ingest path, and the URL is the asset's
    identity there). Distinct identity space from
    :func:`image_node_id_for_bytes` on purpose — a web photo and an uploaded
    photo of the same person are different assets."""
    import hashlib

    return "emergent.image." + hashlib.sha1(url.strip().encode("utf-8")).hexdigest()[:8]


def home_image(
    db,
    uid: str,
    *,
    image_url: str,
    image_read: str,
    node_id: str,
    source_kind: str,
    source_ref: str = "",
    is_you: str = "",
    fact_text: str | None = None,
    visibility: Visibility | str = Visibility.PRIVATE,
) -> tuple[str, str] | None:
    """The ONE idempotent entry point every ingest path uses to home an image
    in the person graph (2l — live image-node creation on the chat, profile
    grid, appearance report and web paths). Thin wrapper over
    :func:`add_photo_fact`: creates (or upserts, on ``node_id``) the image node
    under its fact, carrying the structured ``is_you`` verdict and the SOURCE
    provenance (``source_kind`` ∈ chat|profile_grid|appearance_report|web,
    ``source_ref`` the conversation / media / report id or source page).

    Returns ``(fact_id, image_id)`` on a fresh home, or ``None`` when the node
    already existed and was refreshed in place — so a caller can tell new from
    repeat without having to query. Never dedupes across identity spaces: the
    caller picks ``node_id`` via :func:`image_node_id_for_bytes` (local bytes)
    or :func:`image_node_id_for_url` (web)."""
    return add_photo_fact(
        db,
        uid,
        image_url=image_url,
        image_read=image_read,
        fact_text=fact_text if fact_text is not None else image_read,
        visibility=visibility,
        image_node_id=node_id,
        is_you=is_you,
        source_kind=source_kind,
        source_ref=source_ref,
    )


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


# --- node dedupe: resolution + write-time prevention -----------------------
# These are the user-confirmed resolution primitives for the node-dedupe
# cross-check (founder Nov 17). Nothing here runs silently: Ayma surfaces a
# candidate group in chat (``skills/node_dedupe.py``) and the user's choice —
# merge / link-as-related / keep-both — calls one of these.


def link_related(
    db, uid: str, a: str, b: str, *, label: str | None = None
) -> bool:
    """Link two non-parent/child nodes as RELATED (Contract 4) — a two-way typed
    ``related`` link (a reference, never a copy). Safe to re-run (``add_link`` is
    idempotent). Returns True if any link was newly added. At least one side must
    be an overlay node (a seed node's links are fixed); the link is placed on
    whichever side(s) are overlay nodes."""
    rel = pg.StrictLinkType.RELATED.value
    added = False
    if isinstance(load_overlay(db, uid).get(a), dict):
        added |= add_link(db, uid, a, b, rel, label=label)
    if isinstance(load_overlay(db, uid).get(b), dict):
        added |= add_link(db, uid, b, a, rel, label=label)
    return added


def merge_nodes(db, uid: str, survivor_id: str, dup_id: str) -> dict:
    """Fold the duplicate node ``dup_id`` into ``survivor_id`` and remove it —
    the user-confirmed "merge" resolution. NEVER silent, NEVER automatic.

    The duplicate's live answer is retired to the survivor's Ayma-only dated
    ``history`` (a change of record is itself a fact, mirroring ``set_answer``);
    its children are rehomed onto the survivor; its links are carried over; and
    any OTHER node that pointed at ``dup_id`` (parent or link target) is
    repointed at the survivor so no dangling reference is left. Then ``dup_id``
    is deleted. ``dup_id`` must be an overlay (emergent) node — a seed node is a
    shared template and is never deleted; to merge toward a seed node, make the
    seed node the survivor. Returns a summary dict. Raises ``ValueError`` on a
    bad request."""
    if survivor_id == dup_id:
        raise ValueError("merge_nodes: survivor and duplicate are the same node")
    if pg.seed_node(dup_id) is not None:
        raise ValueError(
            f"merge_nodes: {dup_id!r} is a seed node and cannot be deleted; "
            "merge toward it instead (make it the survivor)"
        )
    overlay = load_overlay(db, uid)
    if dup_id not in overlay:
        raise ValueError(f"merge_nodes: duplicate {dup_id!r} not found in overlay")
    if pg.seed_node(survivor_id) is None and survivor_id not in overlay:
        raise ValueError(f"merge_nodes: survivor {survivor_id!r} not found")

    dup = dict(overlay[dup_id])
    surv_is_overlay = survivor_id in overlay
    surv = _entry(overlay, survivor_id)

    # 1) retire the duplicate's live answer to the survivor's history.
    if surv_is_overlay:
        dup_answer = dup.get("answer")
        if dup_answer not in (None, "") and dup_answer != surv.get("answer"):
            history = list(surv.get("history") or [])
            history.append(
                {
                    "answer": dup_answer,
                    "date": pg.now_iso(),
                    "provenance": dup.get("provenance") or Provenance.STATED.value,
                }
            )
            surv["history"] = history

        # 2) rehome the duplicate's own child bullets onto the survivor.
        dup_children = list(dup.get("children") or [])
        if dup_children:
            surv["children"] = list(surv.get("children") or []) + dup_children

        # 3) carry the duplicate's links over (minus any self/survivor targets).
        dup_links = [
            l for l in (dup.get("links") or [])
            if isinstance(l, dict) and l.get("target") not in (dup_id, survivor_id)
        ]
        if dup_links:
            surv_links = list(surv.get("links") or [])
            have = {(l.get("target"), l.get("type")) for l in surv_links if isinstance(l, dict)}
            for l in dup_links:
                if (l.get("target"), l.get("type")) not in have:
                    surv_links.append(l)
                    have.add((l.get("target"), l.get("type")))
            surv["links"] = surv_links

        surv["updated_at"] = pg.now_iso()
        overlay[survivor_id] = OverlayNode.model_validate(surv).model_dump(exclude_none=True)

    # 4) repoint every OTHER overlay node that referenced the duplicate.
    rehomed_children = 0
    for nid, e in overlay.items():
        if nid in (dup_id, survivor_id) or not isinstance(e, dict):
            continue
        changed = False
        if e.get("parent") == dup_id:
            e["parent"] = survivor_id
            rehomed_children += 1
            changed = True
        links = e.get("links")
        if links:
            new_links: list = []
            have: set = set()
            for l in links:
                if isinstance(l, dict) and l.get("target") == dup_id:
                    l = dict(l)
                    l["target"] = survivor_id
                if isinstance(l, dict):
                    if l.get("target") == nid:  # repointing made it a self-link
                        continue
                    sig = (l.get("target"), l.get("type"))
                    if sig in have:  # collapsed onto an existing link; drop dup
                        continue
                    have.add(sig)
                new_links.append(l)
            if new_links != links:
                e["links"] = new_links
                changed = True
        if changed:
            overlay[nid] = OverlayNode.model_validate(e).model_dump(exclude_none=True)

    # 5) drop the duplicate.
    del overlay[dup_id]
    replace_overlay(db, uid, overlay)
    return {
        "survivor": survivor_id,
        "removed": dup_id,
        "rehomed_children": rehomed_children,
    }


def _dedupe_ref(db, uid: str):
    # A sibling document in the user's own graph collection (NOT ``main``): the
    # overlay doc is rewritten whole by ``replace_overlay`` (merge=False), which
    # would wipe a field stored there, so "keep both" decisions live next to it.
    return (
        db.collection("users").document(uid)
        .collection(_GRAPH_COLLECTION).document("dedupe")
    )


def dedupe_dismiss(db, uid: str, a: str, b: str) -> None:
    """Record a "keep both" decision for the pair ``(a, b)`` so the cross-check
    never re-surfaces it. Stored on a ``dedupe`` sibling doc in the user's graph
    collection (no parallel store), as a list of sorted ``"a|b"`` keys."""
    key = "|".join(sorted((str(a), str(b))))
    snap = _dedupe_ref(db, uid).get()
    data = snap.to_dict() if snap and snap.exists else None
    kept = list((data or {}).get("dedupe_dismissed") or [])
    if key not in kept:
        kept.append(key)
        _dedupe_ref(db, uid).set({"dedupe_dismissed": kept}, merge=True)


def dedupe_dismissed(db, uid: str) -> set[tuple[str, str]]:
    """The set of "keep both" pair keys the user has dismissed."""
    snap = _dedupe_ref(db, uid).get()
    data = snap.to_dict() if snap and snap.exists else None
    out: set[tuple[str, str]] = set()
    for k in (data or {}).get("dedupe_dismissed") or []:
        parts = str(k).split("|")
        if len(parts) == 2:
            out.add((parts[0], parts[1]))
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
        pg.StrictLinkType.RELATED: "same entity/topic, not identical, not parent/child",
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
