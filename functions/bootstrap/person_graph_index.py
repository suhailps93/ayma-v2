"""Per-user index over EVERY person-graph node (node-dedupe, founder Nov 17).

The founder's ask: "a way to index and cross check the nodes to find related
nodes that is not parent and child so that there is no duplicated content."

This module owns step 1 — the INDEX. It reads the user's effective graph
(``seed ⊕ overlay`` via :func:`person_graph_store.effective`, so it covers
every kind: structured seed answers, narrative/editor bullets, report grounding
nodes ``emergent.skill.*``, loose facts, and IMAGE nodes with their
``image_read``) and projects each node to a flat :class:`NodeIndexEntry`: id,
parent/section path, visibility, kind, the node's content text, and a
deterministic lexical signature of that text (normalized text + token set).

On the embedding facility (reported to the lead): the backend has NO
LiveKit-routed TEXT-embedding endpoint. The only embedding model
(``CONFIG.image_embedding_model`` = ``gemini-embedding-2``) is a Vertex
multimodal call for photos, and ``AGENTS.md`` forbids routing any inference off
LiveKit — so introducing a Vertex text-embedding call here would violate the
hard rule. The "semantic embedding" of the brief is therefore served in two
layers that both stay inside existing backend patterns and need no parallel
store / second index DB:

* a deterministic LEXICAL signature here (normalized text + token set), used for
  exact + near-duplicate detection in :mod:`person_graph_crosscheck`; and
* a SEMANTIC judge for the bounded set of ambiguous candidate pairs, run through
  the existing LiveKit inference gateway (``gemini.generate_json``) in
  :mod:`person_graph_crosscheck` — not a stored vector.

Nothing here writes; the index is derived on demand from the live overlay.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

import person_graph as pg
import person_graph_store as store
import question_tree

# Content kinds the index distinguishes (so the cross-check can say "a report
# grounding node vs a story bullet", a known hunting ground).
KIND_SEED = "seed"
KIND_IMAGE = "image"
KIND_REPORT_DOC = "report_doc"  # non-rendering report scaffolding (answer_type)
KIND_GROUNDING = "grounding"  # emergent.skill.* / assess / steering / webfind
KIND_BULLET = "bullet"  # editor / story / loose narrative facts
KIND_OTHER = "other"

_GROUNDING_PREFIXES = (
    "emergent.skill.",
    "emergent.taste.",
    "emergent.steering.",
    "emergent.assess.",
    "emergent.webfind.",
    "emergent.appearance.",
    "emergent.interaction.",
)

# Tokens too common to carry topic signal when overlapping (kept small and
# generic — this is a pre-filter, not a model).
_STOPWORDS = frozenset(
    """a an and are as at be been being but by for from had has have he her his i
    in into is it its me my of on or our she that the their them they this to was
    we were what when where which who will with you your i'm i've it's""".split()
)

_WORD_RE = re.compile(r"[a-z0-9]+(?:'[a-z]+)?")


def normalize_text(text: str) -> str:
    """Lower-cased, whitespace- and punctuation-collapsed form of ``text`` — the
    canonical string two nodes are compared on for an EXACT match. ``""`` for
    empty/None."""
    if not text:
        return ""
    return " ".join(_WORD_RE.findall(str(text).lower()))


def token_set(text: str) -> frozenset[str]:
    """The content-bearing tokens of ``text`` (stopwords dropped) — the set used
    for Jaccard overlap and shared-entity detection."""
    return frozenset(t for t in _WORD_RE.findall(str(text or "").lower()) if t not in _STOPWORDS)


def _flatten(value, out: list[str]) -> None:
    """Collect the human-readable strings out of a nested answer payload (a
    report_doc node's ``answer`` is a dict/list; a plain node's is a string)."""
    if value is None:
        return
    if isinstance(value, str):
        s = value.strip()
        if s:
            out.append(s)
    elif isinstance(value, dict):
        for v in value.values():
            _flatten(v, out)
    elif isinstance(value, (list, tuple)):
        for v in value:
            _flatten(v, out)
    else:
        out.append(str(value))


def content_text(node: pg.GraphNode) -> str:
    """The text the node's meaning lives in, for indexing/comparison:

    * an IMAGE node → its ``image_read`` (Ayma's read of who/what is in it —
      Contract 1, Track A), which is what collides with a stated fact;
    * a report_doc node → the flattened strings of its structured payload;
    * any other node → its answer (stringified) plus its child bullets, falling
      back to the prompt when there is no answer yet.

    The prompt is appended as weak context so an unanswered node still indexes.
    """
    parts: list[str] = []
    if node.answer_type == "image":
        if node.image_read:
            parts.append(str(node.image_read).strip())
    elif node.answer_type == "report_doc":
        _flatten(node.answer, parts)
    else:
        if node.answer not in (None, ""):
            _flatten(node.answer, parts)
        for c in node.children or []:
            t = str(getattr(c, "text", "") or "").strip()
            if t:
                parts.append(t)
    if not parts and node.prompt:
        parts.append(str(node.prompt).strip())
    return " ".join(p for p in parts if p).strip()


def _kind(node: pg.GraphNode) -> str:
    if not node.emergent:
        return KIND_SEED
    if node.answer_type == "image":
        return KIND_IMAGE
    if node.answer_type == "report_doc":
        return KIND_REPORT_DOC
    if any(node.id.startswith(p) for p in _GROUNDING_PREFIXES):
        return KIND_GROUNDING
    if node.answer_type in (None, "narrative") or node.id.startswith(
        ("emergent.editor.", "emergent.story.")
    ):
        return KIND_BULLET
    return KIND_OTHER


@dataclass(frozen=True)
class NodeIndexEntry:
    """One node, flattened for cross-checking. ``norm`` is the exact-match key,
    ``tokens`` the content-token set, ``ancestors`` the id chain up to the root
    (so the cross-check can exclude ancestor/descendant pairs)."""

    node_id: str
    section: str
    parent: Optional[str]
    level: int
    visibility: str
    kind: str
    answer_type: Optional[str]
    text: str
    norm: str
    tokens: frozenset[str] = field(default_factory=frozenset)
    ancestors: frozenset[str] = field(default_factory=frozenset)

    @property
    def indexable(self) -> bool:
        """Whether this entry carries enough content to compare. Empty-text
        nodes (an unanswered seed node with only a prompt that is a bare
        question) are skipped by the cross-check."""
        return bool(self.norm)


def _ancestors(node_id: str, parent_of: dict[str, Optional[str]]) -> frozenset[str]:
    seen: set[str] = set()
    cur = parent_of.get(node_id)
    while cur and cur not in seen:
        seen.add(cur)
        cur = parent_of.get(cur)
    return frozenset(seen)


def build_index(db, uid: str, *, intent: str | None = None) -> list[NodeIndexEntry]:
    """The per-user index over ALL nodes in the effective graph. Read-only."""
    graph = store.effective(db, uid, intent=intent)
    return index_from_graph(graph)


def find_exact_match(
    index: list[NodeIndexEntry],
    text: str,
    *,
    section: str | None = None,
    exclude: frozenset[str] | set[str] | tuple[str, ...] = (),
) -> Optional[str]:
    """The id of an existing node whose content is an EXACT normalized match for
    ``text`` (optionally restricted to ``section``), or ``None``. Exact-only on
    purpose: write-time prevention collapses only unambiguous duplicates; every
    fuzzy/semantic match routes to the never-silent user resolution flow."""
    norm = normalize_text(text)
    if not norm:
        return None
    for e in index:
        if e.node_id in exclude:
            continue
        if section is not None and e.section != section:
            continue
        if e.norm == norm:
            return e.node_id
    return None


def index_from_graph(graph: dict[str, pg.GraphNode]) -> list[NodeIndexEntry]:
    """The index for an already-loaded effective graph (unit-testable without a
    db). ``graph`` is ``{node_id: GraphNode}``."""
    parent_of = {nid: n.parent for nid, n in graph.items()}
    entries: list[NodeIndexEntry] = []
    for nid, n in graph.items():
        text = content_text(n)
        entries.append(
            NodeIndexEntry(
                node_id=nid,
                section=n.section,
                parent=n.parent,
                level=n.level,
                visibility=n.visibility.value if hasattr(n.visibility, "value") else str(n.visibility),
                kind=_kind(n),
                answer_type=n.answer_type,
                text=text,
                norm=normalize_text(text),
                tokens=token_set(text),
                ancestors=_ancestors(nid, parent_of),
            )
        )
    entries.sort(key=lambda e: (question_tree.section_order(e.section), e.level, e.node_id))
    return entries
