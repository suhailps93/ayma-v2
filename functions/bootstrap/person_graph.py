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
    source_kind: Optional[str] = None
    source_ref: Optional[str] = None
    source_created_at: Optional[str] = None


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
    source_created_at: Optional[str] = None


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
        # emergent node — defined wholly by the overlay (design §2.3)
        if not (o.prompt and o.section and o.level):
            raise ValueError(
                f"emergent node {node_id!r} needs prompt, section and level"
            )
        base = GraphNode(
            id=node_id,
            section=o.section,
            prompt=o.prompt,
            answer_type=o.answer_type,
            level=o.level,
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
    if o.source_created_at is not None:
        base.source_created_at = o.source_created_at
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
        out[nid] = merge_node(s, _coerce_overlay(overlay.get(nid)), nid)

    # emergent nodes: overlay entries with no seed
    for nid, raw in overlay.items():
        if nid in seed_nodes:
            continue
        out[nid] = merge_node(None, _coerce_overlay(raw), nid)
    return out


def validate_overlay(overlay: dict[str, Any]) -> dict[str, OverlayNode]:
    """Validate a raw per-user overlay document. Raises on any malformed node
    so a bad write can never be stored (the store/tools call this at the
    boundary). Returns the parsed overlay."""
    return {nid: _coerce_overlay(raw) for nid, raw in (overlay or {}).items()}


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat()
