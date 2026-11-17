"""`main._graph_node_context` — the server-side brief injected into a chat
turn opened from "Chat about it" on a person-graph node (the partial Ayma
window). It resolves the whole node + what's connected to it through the SINGLE
graph lookup (`graph_lookup` by node id) and carries each node's text / image
read, visibility and source so Ayma answers about exactly that node."""

from types import SimpleNamespace

import main


def _node(
    nid,
    *,
    answer="",
    prompt="",
    answer_type="text",
    vis="public",
    image_read="",
    is_you="",
    source_kind="",
    source_ref="",
):
    return SimpleNamespace(
        id=nid,
        answer=answer,
        prompt=prompt,
        answer_type=answer_type,
        visibility=SimpleNamespace(value=vis),
        image_read=image_read,
        is_you=is_you,
        source_kind=source_kind,
        source_ref=source_ref,
    )


def test_empty_node_id_returns_no_context():
    assert main._graph_node_context(object(), "u1", "") == ""
    assert main._graph_node_context(object(), "u1", "   ") == ""


def test_lookup_failure_degrades_to_empty(monkeypatch):
    import person_graph_store as pg_store

    def _boom(*a, **k):
        raise RuntimeError("nope")

    monkeypatch.setattr(pg_store, "graph_lookup", _boom)
    assert main._graph_node_context(object(), "u1", "n1") == ""


def test_missing_anchor_returns_empty(monkeypatch):
    import person_graph_store as pg_store

    monkeypatch.setattr(
        pg_store, "graph_lookup",
        lambda *a, **k: {"anchor": None, "node_ids": [], "nodes": []},
    )
    assert main._graph_node_context(object(), "u1", "n1") == ""


def test_text_node_briefs_text_visibility_and_connected(monkeypatch):
    import person_graph_store as pg_store

    anchor = _node("n1", answer="I love climbing", vis="public")
    child = _node("n2", answer="Bouldering mostly", vis="private",
                  source_kind="chat")
    monkeypatch.setattr(
        pg_store, "graph_lookup",
        lambda db, uid, **k: {
            "anchor": "n1", "node_ids": ["n1", "n2"], "nodes": [anchor, child]
        },
    )
    out = main._graph_node_context(object(), "u1", "n1")
    assert "I love climbing" in out
    assert "[public]" in out
    # the connected node + its visibility + source ride along
    assert "Bouldering mostly" in out
    assert "[private]" in out
    assert "a conversation" in out
    # and the model is told to answer about THIS node
    assert "THIS node" in out


def test_image_node_briefs_read_and_is_you_verdict(monkeypatch):
    import person_graph_store as pg_store

    anchor = _node(
        "img1", answer_type="image", image_read="a man hiking",
        is_you="yes", vis="public", source_kind="profile_grid",
    )
    monkeypatch.setattr(
        pg_store, "graph_lookup",
        lambda db, uid, **k: {
            "anchor": "img1", "node_ids": ["img1"], "nodes": [anchor]
        },
    )
    out = main._graph_node_context(object(), "u1", "img1")
    assert "a man hiking" in out
    assert "confirmed to be the user" in out
    assert "their photos" in out
