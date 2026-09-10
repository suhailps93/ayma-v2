"""Loader for the tree-based deep-matchmaking questionnaire (``question_tree.json``).

A flat array of nodes; ``branch`` routes them. ``all`` is the global core every
intent sees; ``casual`` / ``long_term`` / ``nikah`` are the intent-specific deep
layers. :func:`nodes_for_intent` returns the global core plus exactly one branch.
The ``nikah`` branch is complete in the config but never routed to yet — no
supported intent value maps to it (parked).

Nothing here is hardcoded inline; the config file is the source of truth. Used by
:mod:`completeness` and :mod:`skills.questionnaire`.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

_CONFIG_PATH = Path(__file__).with_name("question_tree.json")

VALID_KINDS = ("enum", "multi", "scale", "bool", "narrative")
VALID_BRANCHES = ("all", "casual", "long_term", "nikah")

# The routing node's raw option strings → the branch they select. Anything not
# listed here (unset, "Not sure yet") falls back to ``long_term`` — see
# :func:`branch_for_intent`. "nikah" is intentionally unreachable from the
# routing node (parked) but still resolves if passed explicitly.
_INTENT_TO_BRANCH = {
    "casual": "casual",
    "long-term": "long_term",
    "long_term": "long_term",
    "longterm": "long_term",
    "marriage": "long_term",
    "nikah": "nikah",
}

_DEFAULT_BRANCH = "long_term"


@lru_cache(maxsize=1)
def _raw() -> dict:
    return json.loads(_CONFIG_PATH.read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def nodes() -> list[dict]:
    """Every node in config order (immutable copies)."""
    return [dict(n) for n in _raw()["nodes"]]


@lru_cache(maxsize=1)
def _by_id() -> dict[str, dict]:
    return {n["id"]: n for n in nodes()}


def node(node_id: str) -> dict | None:
    """The single node with ``node_id``, or ``None``."""
    n = _by_id().get(node_id)
    return dict(n) if n else None


def branch_for_intent(intent: str | None) -> str:
    """The branch name a raw ``relationship_intent`` value routes to. Unknown /
    unset / "Not sure yet" → ``long_term``."""
    key = (intent or "").strip().lower()
    return _INTENT_TO_BRANCH.get(key, _DEFAULT_BRANCH)


def nodes_for_intent(intent: str | None) -> list[dict]:
    """Global core (``branch == "all"``) plus the one branch ``intent`` routes
    to, in config order. Excludes ``nikah`` for every non-nikah intent."""
    branch = branch_for_intent(intent)
    return [n for n in nodes() if n["branch"] in ("all", branch)]


@lru_cache(maxsize=1)
def narrative_ids() -> tuple[str, ...]:
    """Ids of every ``kind == "narrative"`` node."""
    return tuple(n["id"] for n in nodes() if n["kind"] == "narrative")


@lru_cache(maxsize=1)
def hard_filter_ids() -> tuple[str, ...]:
    """Ids of every node with ``hard_filter`` true."""
    return tuple(n["id"] for n in nodes() if n.get("hard_filter"))
