"""The person graph — schema and seed⊕overlay merge.

One graph per user is the single source of truth for who a person is
(design: person-graph-design-plan-2026-11-15.md). This module owns the
**schema** (Pydantic node models, validated at every write boundary) and the
**merge**: the effective graph a reader sees is ``seed ⊕ overlay``.

- The **seed** is the shared template — every node's definition (prompt,
  answer type, section, level, starting weight, branch, common-sense default
  visibility). It is built from ``question_tree.json`` (the evolved v7 tree)
  so there is one source of question definitions, versioned in the repo.
- The **overlay** is the per-user divergence from the seed: answers, changed
  weights/visibility, state, history, children, typed links, and **emergent
  nodes** (facts no seed question covers). Stored at ``users/{uid}/graph`` as
  one document — the store and the tools that write it land in the next phase.

The effective node = seed fields overlaid with the user's divergences. Seed
updates (a reworded prompt, a new node, a level change) therefore reach every
user automatically; nobody's copy goes stale, and per-user storage stays small.

Nothing here reads or writes Firestore yet — this is the schema + merge
foundation the store, tools, and renders build on.
"""

from __future__ import annotations

import datetime as _dt
from enum import Enum
from functools import lru_cache
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

import question_tree

# --- enumerations (design §3) ---------------------------------------------


class Visibility(str, Enum):
    """Public profile render = public only; Your Story render = public +
    private; Ayma-only never renders (Ayma's private knowledge)."""

    PUBLIC = "public"
    PRIVATE = "private"
    AYMA_ONLY = "ayma_only"


class NodeState(str, Enum):
    NOT_ASKED = "not_asked"
    ASKED = "asked"
    PARTIAL = "partial"
    ANSWERED = "answered"
    PREFER_NOT_TO_SAY = "prefer_not_to_say"


class Provenance(str, Enum):
    STATED = "stated"      # the user said it
    INFERRED = "inferred"  # Ayma concluded it (carries confidence, ayma_only)
    IMPORTED = "imported"  # came from profile / migration


class StrictLinkType(str, Enum):
    """The closed set of link types deterministic code acts on (design §2.4).
    Free-form descriptive links are allowed too (context for Ayma only) via
    :class:`Link.label`, governed by the relationship-type registry."""

    ELABORATES = "elaborates"
    DEPENDS_ON = "depends_on"
    SAME_TOPIC = "same_topic"
    SAME_PERSON = "same_person"
    CONTRADICTS = "contradicts"
    # Contract 4 (node-dedupe, founder Nov 17): two nodes that are strongly
    # RELATED — same entity/topic, NOT identical and NOT ancestor/descendant —
    # linked after the cross-check surfaces them and the user keeps both. A
    # first-class strict type so deterministic code (the graph-highlight
    # consumer and write-time prevention) acts on it; ``label`` carries the
    # short human reason ("both about your time at Google"). A reference, never
    # a copy — the two nodes stay where they are.
    RELATED = "related"


_STRICT_LINK_VALUES = {t.value for t in StrictLinkType}

# Answer kinds carried over from the tree (question_tree.VALID_KINDS).
VALID_ANSWER_TYPES = question_tree.VALID_KINDS


# --- Contract 2: the `standard` node classification -----------------------
#
# A STANDARD node is a known structured field that exists for every user — the
# dating-profile identity facts and their equivalents in other sections (name,
# age, gender, location, interested-in, ethnic/cultural origin, …). It is marked
# on the node itself (``GraphNode.standard``) the same way an image node is
# marked by ``answer_type == "image"``, so the visualiser can render it as a
# labelled, consistently-formatted field in a fixed canonical order BEFORE the
# conversational (plain-bullet) nodes (founder Nov 16 fixed-order rule, folded
# into the Node Visualiser chunk).
#
# ``STANDARD_FIELDS`` is the registry: seed node id -> {label, order}. ``label``
# is the field's display label (e.g. "Name", "Age"); ``order`` is its position
# in the section's fixed order (lower renders first). The founder-specified
# About Me order is Name, Age, Gender, Location, Interested in, Ethnic & cultural
# origin. The registry is the single source for "is this node standard", its
# label, and its fixed-order rank — extend it here to mark a new structured
# field; nothing else changes.
STANDARD_FIELDS: dict[str, dict[str, Any]] = {
    # About Me (identity) — the founder-specified canonical order.
    "legal_first_name": {"label": "Name", "order": 0},
    "date_of_birth": {"label": "Age", "order": 1},
    "gender_identity": {"label": "Gender", "order": 2},
    "primary_location": {"label": "Location", "order": 3},
    "target_match_genders": {"label": "Interested in", "order": 4},
    "ethnic_cultural_origin": {"label": "Ethnic & cultural origin", "order": 5},
}


def is_standard(node_id: str) -> bool:
    """True when ``node_id`` is a known structured (standard) field."""
    return node_id in STANDARD_FIELDS


def standard_label(node_id: str) -> Optional[str]:
    meta = STANDARD_FIELDS.get(node_id)
    return meta["label"] if meta else None


def standard_order(node_id: str) -> Optional[int]:
    meta = STANDARD_FIELDS.get(node_id)
    return meta["order"] if meta else None


# --- leaf models -----------------------------------------------------------


class Link(BaseModel):
    """A typed related link to a node anywhere in the graph. ``type`` is a
    strict type (code acts on it) or ``"free"`` for a descriptive link whose
    label comes from the relationship-type registry. Rendered from other
    sections as a reference, never a copy."""

    model_config = ConfigDict(extra="forbid")

    target: str
    type: str = StrictLinkType.SAME_TOPIC.value
    label: Optional[str] = None  # registry name, required for free-form links
    dated: Optional[str] = None  # ISO date, used by `contradicts`

    @field_validator("type")
    @classmethod
    def _known_type(cls, v: str) -> str:
        if v in _STRICT_LINK_VALUES or v == "free":
            return v
        raise ValueError(
            f"link type must be a strict type {sorted(_STRICT_LINK_VALUES)} "
            "or 'free' (with a registry label)"
        )

    @model_validator(mode="after")
    def _free_needs_label(self):
        if self.type == "free" and not (self.label and self.label.strip()):
            raise ValueError("free-form links require a registry label")
        return self


class HistoryEntry(BaseModel):
    """A superseded answer, retired Ayma-only (design §2.5). Never renders,
    never scored; kept because a change of heart is itself a fact."""

    model_config = ConfigDict(extra="forbid")

    answer: Any
    date: str
    provenance: Provenance = Provenance.STATED
    # Where the retired answer came from (founder Nov 17: a merge KEEPS BOTH
    # sources). When a duplicate is folded into a survivor, the duplicate's
    # answer retires here carrying its own source so neither node's provenance is
    # lost. Optional — older history entries have none.
    source_kind: Optional[str] = None
    source_ref: Optional[str] = None


class ChildBullet(BaseModel):
    """A sub-bullet under a node — renders as an indented bullet."""

    model_config = ConfigDict(extra="forbid")

    text: str
    visibility: Visibility = Visibility.PRIVATE


# --- seed + overlay + effective node --------------------------------------


class SeedNode(BaseModel):
    """A node's shared definition (the template). Built from the v7 tree."""

    model_config = ConfigDict(extra="forbid")

    id: str
    section: str
    prompt: str
    answer_type: str
    level: int = Field(ge=1)
    weight: float
    branch: str = "all"
    options: Optional[list[str]] = None
    scale: Optional[Any] = None
    hard_filter: bool = False
    dating_relevant: bool = False
    sensitive: bool = False
    optional: bool = False
    default_visibility: Visibility = Visibility.PRIVATE

    @field_validator("answer_type")
    @classmethod
    def _known_kind(cls, v: str) -> str:
        if v not in VALID_ANSWER_TYPES:
            raise ValueError(f"answer_type {v!r} not in {VALID_ANSWER_TYPES}")
        return v


class OverlayNode(BaseModel):
    """A user's divergences from the seed for one node. Every field optional:
    an overlay stores only what differs. Emergent nodes (no seed entry) carry
    their full definition here (``prompt``/``section``/``level``/``parent``)."""

    model_config = ConfigDict(extra="forbid")

    answer: Any = None
    partner_pref: Any = None
    state: Optional[NodeState] = None
    visibility: Optional[Visibility] = None
    weight: Optional[float] = None
    provenance: Optional[Provenance] = None
    confidence: Optional[float] = Field(default=None, ge=0.0, le=1.0)
    children: list[ChildBullet] = Field(default_factory=list)
    links: list[Link] = Field(default_factory=list)
    history: list[HistoryEntry] = Field(default_factory=list)
    updated_at: Optional[str] = None

    # emergent-only definition (present when there is no seed node)
    prompt: Optional[str] = None
    section: Optional[str] = None
    level: Optional[int] = Field(default=None, ge=1)
    parent: Optional[str] = None
    answer_type: Optional[str] = None
    # image nodes (design §6, "images are nodes"): for an ``answer_type == "image"``
    # node, ``answer`` holds the Firebase Storage link and ``image_read`` holds
    # Ayma's read of the image (who/what is in it). Never set on a text node.
    image_read: Optional[str] = None
    # Image-node verdict + SOURCE provenance (founder Nov 16 2026). ``is_you`` is
    # the structured face-match verdict ("yes"/"no"/"unknown"), written at
    # ingestion — NOT folded into prose. The source axis is DISTINCT from the
    # epistemic ``provenance`` (stated/inferred/imported) above: ``source_kind``
    # ∈ chat|appearance_report|profile_grid|web records WHERE the image came
    # from, ``source_ref`` the conversation/session or report id ("" if none),
    # ``source_created_at`` the ISO time it was first ingested. Only on image nodes.
    is_you: Optional[str] = None
    # SOURCE provenance on ANY node, not just images (founder Nov 17: "every node
    # has a source"). ``source_kind`` ∈ chat|appearance_report|profile_grid|web|
    # report|…; ``source_ref`` the conversation/session id, web link, or report
    # run id; ``source_message_id`` the exact message within a chat (so tapping
    # the source opens that conversation scrolled to it); ``source_created_at``
    # the ISO time the fact was captured. Stamped at write time on every creation
    # path; older sourceless nodes are fine (no backfill — founder waived it).
    source_kind: Optional[str] = None
    source_ref: Optional[str] = None
    source_message_id: Optional[str] = None
    source_created_at: Optional[str] = None
    # Gist-first writing (less-text-heavy program, Part 3): a short punchy
    # one-line headline (aim <= ~80 chars) for this node, emitted by every writer
    # going forward. The longer text stays in ``answer`` but shortened to a brief
    # detail — never a multi-sentence third-person essay. Readers render ``gist``
    # by default and fall back to ``answer`` for older, gist-less nodes.
    gist: Optional[str] = None
    # Write-time VISUAL pick (sibling of ``gist``): how Part 2's renderers should
    # draw this node — ``{"type": <palette>, "params": {...}, "v": 1}`` (see
    # ``node_visual`` + docs/PERSON_GRAPH.md). Picked deterministically at write
    # time; absent/unknown → the reader falls back to a text row. Never affects
    # visibility.
    visual: Optional[dict] = None


class GraphNode(BaseModel):
    """An effective node = seed ⊕ overlay. What every reader (story, public
    profile, matching, sims) consumes."""

    model_config = ConfigDict(extra="forbid")

    id: str
    section: str
    prompt: str
    answer_type: Optional[str] = None
    level: int = Field(ge=1)
    weight: float
    branch: str = "all"
    options: Optional[list[str]] = None
    answer: Any = None
    partner_pref: Any = None
    state: NodeState = NodeState.NOT_ASKED
    visibility: Visibility = Visibility.PRIVATE
    provenance: Provenance = Provenance.STATED
    confidence: Optional[float] = None
    children: list[ChildBullet] = Field(default_factory=list)
    links: list[Link] = Field(default_factory=list)
    history: list[HistoryEntry] = Field(default_factory=list)
    hard_filter: bool = False
    sensitive: bool = False
    emergent: bool = False
    parent: Optional[str] = None
    updated_at: Optional[str] = None
    # image nodes (design §6): ``answer`` = Firebase Storage link,
    # ``image_read`` = Ayma's read of the image. Only on ``answer_type=="image"``.
    # ``is_you`` = face-match verdict; ``source_kind``/``source_ref``/
    # ``source_created_at`` = where the image came from (distinct from the
    # epistemic ``provenance`` axis). See OverlayNode for the field contract.
    image_read: Optional[str] = None
    is_you: Optional[str] = None
    source_kind: Optional[str] = None
    source_ref: Optional[str] = None
    source_message_id: Optional[str] = None
    source_created_at: Optional[str] = None
    # Contract 2: this node is a known structured (standard) field — rendered as a
    # labelled field in a fixed order first. ``standard_field_label`` /
    # ``standard_field_order`` carry its display label and canonical rank.
    standard: bool = False
    standard_field_label: Optional[str] = None
    standard_field_order: Optional[int] = None
    # Gist-first writing (Part 3): short one-line headline for this node (see
    # OverlayNode.gist). None on older nodes written before gist-first.
    gist: Optional[str] = None
    # Write-time visual descriptor (see OverlayNode.visual). None on older nodes.
    visual: Optional[dict] = None


# --- seed construction (from the v7 tree) ---------------------------------


# Founder-approved PUBLIC allow-list (Nov 15 2026): the standard dating-profile
# facts that appear on the public profile. date_of_birth is public as AGE only —
# the raw birthdate never renders (see person_graph_render). Everything not here
# defaults private. (The open "What I'm Looking For" description node is a
# pending Nov-15 addition; it joins this list when the looking-for flow adds it.)
_PUBLIC_ALLOWLIST = {
    "date_of_birth",
    "gender_identity",
    "primary_location",
    "target_match_genders",
    "relationship_intent",
    # The open "What I'm looking for" description (seed v8, 6b): a standard,
    # user-authored dating-profile field — founder-approved public alongside the
    # identity set. Its default visibility is public; the user can still make it
    # private per node like any other.
    "looking_for_description",
}


def _default_visibility_for(node: dict, section_default: Visibility) -> Visibility:
    """The node's common-sense default visibility (design §3).

    A structured personal fact is NOT public until it is explicitly opted in:
    publishing a questionnaire answer (DOB, gender, booleans, enums, …) to the
    public profile is a per-node decision, not a section-default fallback
    (Scout 2449 blocker 1 — the founder reviews and approves the public set).
    So the rule is:
      - an explicit per-node ``visibility`` in the seed wins (the public
        allow-list, and the sensitive overrides, live here);
      - a ``sensitive`` node is never public;
      - everything else defaults **private** — visible to the owner in Your
        Story, never on the public profile, until opted in.
    Wiki/story prose keeps its own page visibility at migration time (it does
    not pass through this), so this changes only seed-node (questionnaire)
    answers, which previously did not render as story/public bullets at all."""
    explicit = node.get("visibility")
    if explicit in {v.value for v in Visibility}:
        return Visibility(explicit)
    if node.get("id") in _PUBLIC_ALLOWLIST and not node.get("sensitive"):
        return Visibility.PUBLIC  # founder-approved public dating-profile fact
    if node.get("sensitive"):
        # sensitive content is never public; keep an even-more-private section
        # default (e.g. ayma_only) if the section sets one.
        return section_default if section_default is not Visibility.PUBLIC else Visibility.PRIVATE
    return Visibility.PRIVATE


@lru_cache(maxsize=1)
def _section_default_visibility() -> dict[str, Visibility]:
    out: dict[str, Visibility] = {}
    for pt, meta in question_tree.section_meta().items():
        dv = meta.get("default_visibility", "public")
        out[pt] = Visibility(dv) if dv in {v.value for v in Visibility} else Visibility.PUBLIC
    return out


@lru_cache(maxsize=1)
def seed() -> dict[str, SeedNode]:
    """Every seed node, keyed by id, built from the v7 tree. Cached."""
    sec_def = _section_default_visibility()
    out: dict[str, SeedNode] = {}
    for n in question_tree.nodes():
        pt = n["page_type"]
        section_default = sec_def.get(pt, Visibility.PUBLIC)
        out[n["id"]] = SeedNode(
            id=n["id"],
            section=pt,
            prompt=n.get("label") or n["id"],
            answer_type=n["kind"],
            level=int(n.get("level", 2)),
            weight=float(n.get("weight", 0)),
            branch=n.get("branch", "all"),
            options=n.get("options"),
            scale=n.get("scale"),
            hard_filter=bool(n.get("hard_filter")),
            dating_relevant=bool(n.get("dating_relevant")),
            sensitive=bool(n.get("sensitive")),
            optional=bool(n.get("optional")),
            default_visibility=_default_visibility_for(n, section_default),
        )
    return out


def seed_node(node_id: str) -> Optional[SeedNode]:
    return seed().get(node_id)


# --- the merge: seed ⊕ overlay --------------------------------------------


def merge_node(seed_n: Optional[SeedNode], overlay_n: Optional[OverlayNode], node_id: str) -> GraphNode:
    """Resolve one effective node. ``seed_n`` present → a seed node, its
    divergences applied; ``seed_n`` None → an emergent node defined entirely by
    the overlay. At least one must be present."""
    if seed_n is None and overlay_n is None:
        raise ValueError(f"no seed or overlay for node {node_id!r}")

    o = overlay_n or OverlayNode()

    if seed_n is not None:
        base = GraphNode(
            id=seed_n.id,
            section=seed_n.section,
            prompt=seed_n.prompt,
            answer_type=seed_n.answer_type,
            level=seed_n.level,
            weight=seed_n.weight,
            branch=seed_n.branch,
            options=seed_n.options,
            visibility=seed_n.default_visibility,
            hard_filter=seed_n.hard_filter,
            sensitive=seed_n.sensitive,
            emergent=False,
        )
    else:
        # emergent node — defined wholly by the overlay (design §2.3). The write
        # paths (add_node / add_loose_node) always set prompt+section+level, but
        # a legacy or partial write may lack them (founder defect Nov 17: 54
        # nodes stored with only answer/provenance/state). DEFAULT the missing
        # structural fields to a renderable loose fact (Little Extras, level 1)
        # rather than RAISE — one such node must never blank the whole effective
        # graph (which would empty Your Story / public profile / the person
        # graph, as it did). A node that carries an answer is content and belongs
        # on the graph; here it simply homes in `misc` with its answer as text.
        section = o.section or "misc"
        level = o.level or 1
        # A narrative/loose fact is now written with an explicit EMPTY prompt —
        # its statement lives in the answer only, so it is not duplicated into a
        # header (founder build 2493). Preserve that empty prompt. Only a node
        # that is MISSING a prompt entirely (``None`` — a legacy/partial write,
        # the Nov 17 54-node defect) is given a synthesized one so it still
        # renders a label rather than blanking.
        if o.prompt is not None:
            prompt = o.prompt
        else:
            prompt = str(o.answer).strip()[:80] if o.answer is not None else node_id
        base = GraphNode(
            id=node_id,
            section=section,
            prompt=prompt,
            answer_type=o.answer_type,
            level=level,
            weight=o.weight if o.weight is not None else 0.0,
            visibility=Visibility.PRIVATE,  # emergent default private (§8.2)
            emergent=True,
            parent=o.parent,
        )

    # apply overlay divergences
    if o.answer is not None:
        base.answer = o.answer
    if o.partner_pref is not None:
        base.partner_pref = o.partner_pref
    if o.state is not None:
        base.state = o.state
    elif o.answer is not None:
        base.state = NodeState.ANSWERED
    if o.visibility is not None:
        base.visibility = o.visibility
    if o.weight is not None:
        base.weight = o.weight
    if o.provenance is not None:
        base.provenance = o.provenance
    if o.confidence is not None:
        base.confidence = o.confidence
    if o.children:
        base.children = list(o.children)
    if o.links:
        base.links = list(o.links)
    if o.history:
        base.history = list(o.history)
    if o.updated_at is not None:
        base.updated_at = o.updated_at
    if o.image_read is not None:
        base.image_read = o.image_read
    if o.is_you is not None:
        base.is_you = o.is_you
    if o.source_kind is not None:
        base.source_kind = o.source_kind
    if o.source_ref is not None:
        base.source_ref = o.source_ref
    if o.source_message_id is not None:
        base.source_message_id = o.source_message_id
    if o.source_created_at is not None:
        base.source_created_at = o.source_created_at
    if o.gist is not None:
        base.gist = o.gist
    if o.visual is not None:
        base.visual = o.visual
    # Contract 2: mark the known structured (standard) fields from the registry.
    if is_standard(base.id):
        base.standard = True
        base.standard_field_label = standard_label(base.id)
        base.standard_field_order = standard_order(base.id)
    return base


def _coerce_overlay(raw: Any) -> OverlayNode:
    if isinstance(raw, OverlayNode):
        return raw
    return OverlayNode.model_validate(raw or {})


def effective_graph(
    overlay: dict[str, Any] | None,
    *,
    intent: str | None = None,
) -> dict[str, GraphNode]:
    """The whole effective graph for a user = seed ⊕ overlay, restricted to
    the branch ``intent`` routes to.

    - Every seed node on the user's branch appears (answered or not).
    - Overlay divergences are applied to their seed node.
    - Emergent nodes (overlay-only, no seed) appear too.
    Nodes off the user's branch are excluded (a user's overlay only holds
    nodes on their branch anyway).
    """
    overlay = overlay or {}
    branch = question_tree.branch_for_intent(intent)
    seed_nodes = seed()

    out: dict[str, GraphNode] = {}
    for nid, s in seed_nodes.items():
        if s.branch not in ("all", branch):
            continue
        try:
            out[nid] = merge_node(s, _coerce_overlay(overlay.get(nid)), nid)
        except Exception:  # noqa: BLE001 - one bad overlay entry must not blank the graph
            out[nid] = merge_node(s, None, nid)  # fall back to the seed node

    # emergent nodes: overlay entries with no seed
    for nid, raw in overlay.items():
        if nid in seed_nodes:
            continue
        # Safety net: a single unparseable emergent node must NEVER blank the
        # whole effective graph (founder defect Nov 17). merge_node now defaults
        # missing structural fields rather than raising; this is belt-and-braces
        # for anything still malformed — skip just that node, keep the rest.
        try:
            out[nid] = merge_node(None, _coerce_overlay(raw), nid)
        except Exception:  # noqa: BLE001
            continue
    return out


def validate_overlay(overlay: dict[str, Any]) -> dict[str, OverlayNode]:
    """Validate a raw per-user overlay document. Raises on any malformed node
    so a bad write can never be stored (the store/tools call this at the
    boundary). Returns the parsed overlay."""
    return {nid: _coerce_overlay(raw) for nid, raw in (overlay or {}).items()}


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat()


# --- related links (founder Nov 18) ---------------------------------------
#
# A RELATED link (``StrictLinkType.RELATED``) wires two nodes that are the same
# entity/topic but NOT identical and NOT ancestor/descendant — "the dog that came
# up talking about family" linked to the other dog notes elsewhere. The link is
# MUTUAL: if A links B, B reads as linked to A. Storage puts the link on whichever
# side(s) are overlay nodes (a seed node's links are fixed), and these read
# helpers DERIVE the missing direction so every surface sees the pair both ways.
#
# LEVEL RULE (founder Nov 18): a related link only ever connects nodes DEEPER than
# level 2 — BOTH ends must be level 3 or deeper. Levels 0/1/2 (You, and the
# form/structure layers) never carry a related link, as source or target.

RELATED_MIN_LEVEL = 3


def eligible_for_related_link(level_a: int, level_b: int) -> bool:
    """True when a related link MAY connect two nodes at these levels — both ends
    level ``RELATED_MIN_LEVEL`` or deeper (founder Nov 18). A pair touching a
    level-0/1/2 node on either end is never linked (structure layers need none)."""
    return int(level_a) >= RELATED_MIN_LEVEL and int(level_b) >= RELATED_MIN_LEVEL


def related_targets(node: "GraphNode") -> list[tuple[str, Optional[str]]]:
    """``[(target_id, reason), ...]`` — this node's own stored RELATED links. The
    ``reason`` is the link's short ``label`` (why the two are linked), or None."""
    out: list[tuple[str, Optional[str]]] = []
    for ln in getattr(node, "links", None) or []:
        if getattr(ln, "type", "") == StrictLinkType.RELATED.value:
            tgt = getattr(ln, "target", "")
            if tgt:
                out.append((tgt, getattr(ln, "label", None)))
    return out


def mutual_related(
    graph: dict[str, "GraphNode"],
) -> dict[str, dict[str, Optional[str]]]:
    """Symmetric related adjacency over the effective ``graph``, derived BOTH
    directions (founder Nov 18 mutuality): for every stored RELATED link A→B,
    both ``out[A][B]`` and ``out[B][A]`` are present so each end reads the other
    as related even when only one side could store the link (a seed target).
    The value is the link reason (``label``), kept from whichever direction
    carried it. Only targets that exist in ``graph`` are included."""
    out: dict[str, dict[str, Optional[str]]] = {}
    for nid, n in graph.items():
        for tgt, reason in related_targets(n):
            if tgt == nid or tgt not in graph:
                continue
            out.setdefault(nid, {})
            out.setdefault(tgt, {})
            if out[nid].get(tgt) is None:
                out[nid][tgt] = reason
            if out[tgt].get(nid) is None:
                out[tgt][nid] = reason
    return out
