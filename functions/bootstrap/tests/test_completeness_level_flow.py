"""Phase 6b: Ayma's guided flow becomes breadth-first by level (design §5.2).

Flag on (person_graph_reads): she works the shallowest still-open level across
ALL sections before any deeper one, and ranks by weight within a level. Flag
off: today's section-core walk (covered by test_completeness.py).
"""

import dataclasses

import completeness as c
from config import CONFIG


def _node(nid, level, weight, page_type="personality"):
    return {
        "id": nid, "level": level, "weight": weight, "page_type": page_type,
        "label": nid, "kind": "enum", "options": ["a", "b"], "scale": None,
        "ayma_prompt": f"ask {nid}",
    }


def _ev(nid, level, weight, coverage=0.0, page_type="personality"):
    return {"node": _node(nid, level, weight, page_type), "coverage": coverage}


def _on(monkeypatch):
    monkeypatch.setattr(c, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=True))


def _off(monkeypatch):
    monkeypatch.setattr(c, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=False))


def test_level_ceiling_is_shallowest_open_level(monkeypatch):
    _on(monkeypatch)
    visible = [_ev("deep", 3, 5), _ev("breadth", 2, 1)]
    assert c._guided_level_ceiling(visible) == 2
    # once the level-2 node is answered, the ceiling moves to 3
    visible2 = [_ev("deep", 3, 5), _ev("breadth", 2, 1, coverage=1.0)]
    assert c._guided_level_ceiling(visible2) == 3
    # flag off -> no level gating
    _off(monkeypatch)
    assert c._guided_level_ceiling(visible) is None


def test_next_fills_shallower_level_first_even_at_lower_weight(monkeypatch):
    _on(monkeypatch)
    # a heavy level-3 node must NOT jump ahead of a light level-2 node
    visible = [
        _ev("deep_heavy", 3, 5, page_type="values"),
        _ev("breadth_light", 2, 1, page_type="personality"),
    ]
    nxt = c._next(visible, meta={}, intent_set=True, level_ceiling=c._guided_level_ceiling(visible))
    ids = [n["id"] for n in nxt]
    assert ids == ["breadth_light"]  # level 3 stays locked until level 2 is done


def test_next_ranks_by_weight_within_a_level(monkeypatch):
    _on(monkeypatch)
    visible = [
        _ev("l2_light", 2, 1, page_type="personality"),
        _ev("l2_heavy", 2, 5, page_type="values"),
    ]
    nxt = c._next(visible, meta={}, intent_set=True, level_ceiling=c._guided_level_ceiling(visible))
    assert [n["id"] for n in nxt] == ["l2_heavy", "l2_light"]


def test_routing_node_always_reachable(monkeypatch):
    _on(monkeypatch)
    # the routing node unlocks regardless of level ceiling
    assert c._node_unlocked({"id": c._ROUTING_ID, "level": 1, "page_type": "looking_for"}, {}, 3)


def test_flag_off_uses_section_gate_not_level(monkeypatch):
    _off(monkeypatch)
    # with the flag off, a node with no section meta is unlocked (today's default)
    assert c._node_unlocked(_node("x", 3, 1), meta={}, level_ceiling=None)
