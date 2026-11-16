"""The five person-graph tools, exposed to Ayma in text and voice (design §8.2).

Each maps one-to-one onto a :mod:`person_graph_store` operation, closed over
this session's ``(db, uid)`` so it can only ever touch the authenticated user's
own graph (``users/{uid}/graph/main``):

| tool | store op |
|---|---|
| ``set_answer`` | record an answer on a seed/overlay node (provenance stated) |
| ``set_weight`` | set a node's personal weight (§4.2) |
| ``set_visibility`` | public / private / ayma_only (§3) |
| ``add_node`` | create an emergent off-script node under a parent (§2.3) |
| ``query_nodes`` | pull a subgraph (one section / level / state) (§8.2) |

These are **gated** behind ``CONFIG.person_graph_tools`` (composed in
``skills/__init__`` via :func:`person_graph_tool_skills`), off by default. They
write the graph overlay, which nothing reads in production until the
consumer-switch reads flag flips — so enabling the tools alone is safe and
additive. Every write is validated at the store boundary, so a malformed node
can never be stored.

Weight note (§4.4 / §11 Q3): a weight jump into the top band must be confirmed
with the user out loud before it becomes a gate. The tool only stores a value;
the description tells Ayma to call ``set_weight`` toward the top band only after
the user confirms it truly matters. Nothing here promotes a gate silently.
"""

from __future__ import annotations

import logging
from typing import Callable

import person_graph_store as store
from person_graph import NodeState, Provenance, Visibility

from ._base import Skill

logger = logging.getLogger("ayma.person_graph_tools")

# How many nodes a single query_nodes call serialises back to the model — a
# whole section or level, not the whole person (that is what the renders are
# for). Keeps the tool result bounded.
_QUERY_LIMIT = 60


# --- set_answer ------------------------------------------------------------

_SET_ANSWER = {
    "name": "pg_set_answer",
    "description": (
        "Record the user's answer to one person-graph node (a stated fact about "
        "them). Use the node's id (from pg_query_nodes). For an off-script fact "
        "that has no node yet, use pg_add_node instead."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "node_id": {"type": "string", "description": "the node's id"},
            "answer": {
                "type": "string",
                "description": "the user's answer, in their own words",
            },
        },
        "required": ["node_id", "answer"],
    },
}


def _bind_set_answer(db, uid: str) -> Callable[..., str]:
    def pg_set_answer(node_id: str, answer: str) -> str:
        try:
            store.set_answer(db, uid, node_id, answer, provenance=Provenance.STATED)
        except ValueError as exc:
            return f"error: {exc}"
        return f"recorded answer for {node_id}"

    return pg_set_answer


# --- set_weight ------------------------------------------------------------

_SET_WEIGHT = {
    "name": "pg_set_weight",
    "description": (
        "Set how much one person-graph node matters to the user (their personal "
        "weight, 0=not at all to 5=crucial). Only push a weight toward the top "
        "(4-5) AFTER the user confirms out loud it truly matters and could rule "
        "someone out — never on a passing mention."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "node_id": {"type": "string", "description": "the node's id"},
            "weight": {
                "type": "number",
                "description": "0 (irrelevant) to 5 (crucial)",
            },
        },
        "required": ["node_id", "weight"],
    },
}


def _bind_set_weight(db, uid: str) -> Callable[..., str]:
    def pg_set_weight(node_id: str, weight: float) -> str:
        try:
            w = float(weight)
        except (TypeError, ValueError):
            return f"error: weight must be a number, got {weight!r}"
        if not 0.0 <= w <= 5.0:
            return "error: weight must be between 0 and 5"
        try:
            store.set_weight(db, uid, node_id, w)
        except ValueError as exc:
            return f"error: {exc}"
        return f"set weight {w:g} on {node_id}"

    return pg_set_weight


# --- set_visibility --------------------------------------------------------

_VIS_VALUES = [v.value for v in Visibility]

_SET_VISIBILITY = {
    "name": "pg_set_visibility",
    "description": (
        "Set who can see one person-graph node: 'public' (on the user's public "
        "profile), 'private' (only the user and Ayma), or 'ayma_only' (only "
        "Ayma, never shown to the user or anyone). Use when the user says a fact "
        "should or shouldn't be visible."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "node_id": {"type": "string", "description": "the node's id"},
            "visibility": {"type": "string", "enum": _VIS_VALUES},
        },
        "required": ["node_id", "visibility"],
    },
}


def _bind_set_visibility(db, uid: str) -> Callable[..., str]:
    def pg_set_visibility(node_id: str, visibility: str) -> str:
        try:
            store.set_visibility(db, uid, node_id, visibility)
        except ValueError as exc:
            return f"error: {exc}"
        return f"set {node_id} visibility to {visibility}"

    return pg_set_visibility


# --- add_node --------------------------------------------------------------

_ADD_NODE = {
    "name": "pg_add_node",
    "description": (
        "Create a new person-graph node for an off-script fact that no existing "
        "node covers, as a child of the closest parent node (parent_id, from "
        "pg_query_nodes). The new node sits one level deeper than its parent and "
        "is private by default. Returns the new node's id."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "parent_id": {
                "type": "string",
                "description": "the closest existing node this fact grows out of",
            },
            "label": {
                "type": "string",
                "description": "a short prompt/label naming what this node is about",
            },
            "answer": {
                "type": "string",
                "description": "the fact itself, in the user's words (optional)",
            },
            "section": {
                "type": "string",
                "description": "override the home section (defaults to the parent's)",
            },
        },
        "required": ["parent_id", "label"],
    },
}


def _bind_add_node(db, uid: str) -> Callable[..., str]:
    def pg_add_node(
        parent_id: str, label: str, answer: str = "", section: str = ""
    ) -> str:
        try:
            nid = store.add_node(
                db,
                uid,
                parent_id,
                label,
                answer=(answer or None),
                section=(section or None),
                answer_type=("narrative" if answer else None),
                provenance=Provenance.STATED,
            )
        except ValueError as exc:
            return f"error: {exc}"
        return f"added node {nid}"

    return pg_add_node


# --- query_nodes -----------------------------------------------------------

_QUERY_NODES = {
    "name": "pg_query_nodes",
    "description": (
        "Pull a slice of the user's person graph instead of the whole person: "
        "filter by section, level (1=pre-boarding basics, 2=breadth, 3=depth, "
        "4+=grown in conversation), state ('not_asked'/'answered'/'skipped'), or "
        "minimum weight. Use it to find what still needs asking in a section, or "
        "to look up a node's id before set_answer/set_weight/set_visibility."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {"type": "string", "description": "home section key"},
            "level": {"type": "integer", "description": "1, 2, 3, 4, ..."},
            "state": {
                "type": "string",
                "enum": [s.value for s in NodeState],
            },
            "min_weight": {
                "type": "number",
                "description": "only nodes weighted at least this much",
            },
        },
    },
}


def _bind_query_nodes(db, uid: str) -> Callable[..., str]:
    def pg_query_nodes(
        section: str = "",
        level: int = 0,
        state: str = "",
        min_weight: float = 0.0,
    ) -> str:
        try:
            nodes = store.query_nodes(
                db,
                uid,
                section=(section or None),
                level=(int(level) or None),
                state=(state or None),
                min_weight=(float(min_weight) or None),
            )
        except ValueError as exc:
            return f"error: {exc}"
        if not nodes:
            return "no matching nodes"
        lines = []
        for n in nodes[:_QUERY_LIMIT]:
            head = f"{n.id} [L{n.level} {n.section} {n.state.value}]"
            if n.answer not in (None, ""):
                lines.append(f"{head} {n.prompt} = {n.answer}")
            else:
                lines.append(f"{head} {n.prompt}")
        more = len(nodes) - _QUERY_LIMIT
        if more > 0:
            lines.append(f"... (+{more} more; narrow the filter)")
        return "\n".join(lines)

    return pg_query_nodes


# --- registry --------------------------------------------------------------

SKILLS: list[Skill] = [
    Skill(declaration=_SET_ANSWER, bind=_bind_set_answer),
    Skill(declaration=_SET_WEIGHT, bind=_bind_set_weight),
    Skill(declaration=_SET_VISIBILITY, bind=_bind_set_visibility),
    Skill(declaration=_ADD_NODE, bind=_bind_add_node),
    Skill(declaration=_QUERY_NODES, bind=_bind_query_nodes),
]

SKILL_NAMES = {s.name for s in SKILLS}
