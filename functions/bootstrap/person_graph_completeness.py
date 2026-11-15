"""Completeness as game-like tiers over the person graph (design §6).

A list-percentage stops making sense once the graph grows — the denominator
moves every time Ayma and the user add a node. Completeness becomes a **tier**:

    Surface → Core → Deep → Uncharted

- **Surface** — level 1 complete, nothing more. Not yet matchable.
- **Core** — levels 1–2 fully answered (for the user's branch). The matchable
  line: "actually here to use the app."
- **Deep** — the whole seed template answered (levels 1–3). Nothing Ayma came
  with is left.
- **Uncharted** — beyond the seed, measured on two axes of emergent growth:
  depth (deepest level reached) and breadth (sections that grew emergent nodes,
  and how many).

Measurement rule (§6.1): any percentage is computed against the **fixed seed
only**, per level, for the user's branch. Emergent nodes never enter a
denominator — growth is the separate Uncharted axis, so growing your graph can
never make you look *less* complete (this is what killed the live 81↔86% wobble).

This is an additive read over the effective graph; it is not yet wired into the
live completeness endpoint (that is the consumer-switch phase).
"""

from __future__ import annotations

from person_graph import GraphNode, NodeState

# states that count a seed node as covered for tier math
_COVERED = {NodeState.ANSWERED, NodeState.PREFER_NOT_TO_SAY}

SURFACE = "Surface"
CORE = "Core"
DEEP = "Deep"
UNCHARTED = "Uncharted"

TIER_ORDER = [SURFACE, CORE, DEEP, UNCHARTED]


def _seed_level_progress(graph: dict[str, GraphNode]) -> dict[int, dict]:
    """Per-level answered/total against the fixed seed (levels 1–3), for the
    nodes on this graph's branch. Emergent nodes are excluded."""
    out: dict[int, dict] = {1: {"answered": 0, "total": 0},
                            2: {"answered": 0, "total": 0},
                            3: {"answered": 0, "total": 0}}
    for n in graph.values():
        if n.emergent or n.level not in out:
            continue
        out[n.level]["total"] += 1
        if n.state in _COVERED:
            out[n.level]["answered"] += 1
    for lv, d in out.items():
        d["pct"] = round(100 * d["answered"] / d["total"]) if d["total"] else 100
    return out


def _uncharted(graph: dict[str, GraphNode]) -> dict:
    emergent = [n for n in graph.values() if n.emergent]
    sections = {n.section for n in emergent}
    depth = max((n.level for n in emergent), default=0)
    return {
        "emergent_count": len(emergent),
        "breadth": len(sections),          # sections that grew emergent nodes
        "sections": sorted(sections),
        "depth": depth,                    # deepest emergent level reached
    }


def compute_tier(graph: dict[str, GraphNode]) -> dict:
    """The completeness tier + supporting measures for one effective graph."""
    levels = _seed_level_progress(graph)
    l1 = levels[1]["pct"] >= 100
    l2 = l1 and levels[2]["pct"] >= 100
    l3 = l2 and levels[3]["pct"] >= 100
    unch = _uncharted(graph)
    has_growth = unch["emergent_count"] > 0

    if l3 and has_growth:
        tier = UNCHARTED
    elif l3:
        tier = DEEP
    elif l2:
        tier = CORE
    else:
        tier = SURFACE

    return {
        "tier": tier,
        "matchable": tier in (CORE, DEEP, UNCHARTED),  # nobody matches below Core
        "levels": levels,
        "uncharted": unch,
    }
