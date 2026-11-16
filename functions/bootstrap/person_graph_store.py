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
) -> str:
    """Create an emergent IMAGE node under ``parent_id`` (design §6, "images are
    nodes"): an ``answer_type == "image"`` node whose ``answer`` holds the
    Firebase Storage ``image_url`` and ``image_read`` holds Ayma's read of the
    image (who/what is in it). Private by default; ``links`` (typed related
    links, §2.4) connect it to the fact nodes it belongs to — a reference, never
    a copy. Returns the new node's id."""
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
    if nid in overlay or pg.seed_node(nid) is not None:
        raise ValueError(f"node id {nid!r} already exists")

    e: dict[str, Any] = {
        "prompt": (image_read or "image").strip()[:120] or "image",
        "section": sec,
        "level": int(parent_level) + 1,
        "parent": parent_id,
        "answer_type": "image",
        "answer": image_url,
        "image_read": image_read,
        "state": NodeState.ANSWERED.value,
        "visibility": vis,
        "provenance": Provenance.STATED.value,
        "updated_at": pg.now_iso(),
    }
    if links:
        e["links"] = links

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
