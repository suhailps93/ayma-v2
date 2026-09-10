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

# Node tiers for progressive disclosure. ``core`` is the first thing to cover in
# a section — the routing node and the high-weight essentials; ``deep`` is the
# extra detail that only opens once a section's core is answered.
VALID_TIERS = ("core", "deep")

# Human-facing section names, keyed by ``page_type``. Canonical here (the config
# layer); :mod:`completeness` extends this for non-questionnaire surfaces.
PAGE_TYPE_LABELS = {
    "identity": "Identity & basics",
    "personality": "Personality & temperament",
    "lifestyle": "Daily life & habits",
    "relationships": "Relationship style",
    "interests": "Interests",
    "values": "Values & beliefs",
    "career": "Work & ambition",
    "goals": "Goals & timelines",
    "family": "Family & kinship",
    "dealbreakers": "Dealbreakers",
}

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


@lru_cache(maxsize=1)
def _tier_by_id() -> dict[str, str]:
    return {n["id"]: n.get("tier", "core") for n in nodes()}


def tier(node_id: str) -> str | None:
    """``"core"`` | ``"deep"`` for ``node_id``, or ``None`` if unknown."""
    return _tier_by_id().get(node_id)


@lru_cache(maxsize=1)
def core_ids() -> tuple[str, ...]:
    """Ids of every ``tier == "core"`` node, in config order."""
    return tuple(n["id"] for n in nodes() if n.get("tier") == "core")


def label_for_page_type(page_type: str) -> str:
    """The section label for ``page_type`` — falls back to a title-cased id."""
    return PAGE_TYPE_LABELS.get(page_type, page_type.replace("_", " ").title())


def sections_for_intent(intent: str | None) -> list[dict]:
    """The sections (``page_type`` groups) in the ``intent`` tree, as
    ``{page_type, label, priority}`` where ``priority`` is the highest node
    weight in that section. Ordered by ``priority`` descending, then by the
    order the section first appears in the tree."""
    order: list[str] = []
    priority: dict[str, int] = {}
    for n in nodes_for_intent(intent):
        pt = n["page_type"]
        if pt not in priority:
            order.append(pt)
            priority[pt] = n["weight"]
        else:
            priority[pt] = max(priority[pt], n["weight"])
    ranked = sorted(order, key=lambda pt: (-priority[pt], order.index(pt)))
    return [
        {
            "page_type": pt,
            "label": label_for_page_type(pt),
            "priority": priority[pt],
        }
        for pt in ranked
    ]
