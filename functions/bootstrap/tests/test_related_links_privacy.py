"""Privacy tests for related links (founder Nov 18): a surface only ever
traverses related links between nodes the viewer MAY see — a public node that
links to a private/Ayma-only node must NOT leak it (not the target id, not its
reason label) on any shared surface, in BOTH render and lookup.
"""

import profile_graph
import person_graph_store as store
from person_graph import Visibility

from test_node_dedupe import UID, FakeDb, _overlay_doc, _profile


# --- render: profile_graph drops related links to invisible targets ---------


def test_render_drops_related_link_to_invisible_target():
    graph = {
        "center": {"id": "me", "label": "You"},
        "sections": [],
        "edges": [],
        "nodes": [
            {
                "id": "pub",
                "kind": "taste",
                "visibility": "public",
                "links": [
                    # the private target is NOT in this (public) payload
                    {"target": "privnode", "type": "related", "label": "secret topic"},
                    {"target": "visraw", "type": "related", "label": "ok"},
                    {"target": "bulletX", "type": "related", "label": "bullet ok"},
                ],
            },
            {"id": "visraw", "kind": "taste", "visibility": "public"},
            {"id": "b:bulletX", "kind": "bullet", "visibility": "public"},
        ],
    }
    out = profile_graph._filter_related_to_visible(graph)
    pub = next(n for n in out["nodes"] if n["id"] == "pub")
    targets = {l["target"] for l in pub.get("links", [])}
    assert "privnode" not in targets  # no leak: id AND its reason label are gone
    assert "visraw" in targets  # a visible raw target survives
    assert "bulletX" in targets  # resolved to the b:<id> flat node, survives


def test_render_strips_links_key_when_all_targets_hidden():
    graph = {
        "center": {"id": "me", "label": "You"},
        "sections": [],
        "edges": [],
        "nodes": [
            {
                "id": "pub",
                "kind": "taste",
                "visibility": "public",
                "links": [{"target": "privnode", "type": "related", "label": "x"}],
            },
        ],
    }
    out = profile_graph._filter_related_to_visible(graph)
    assert "links" not in out["nodes"][0]


# --- lookup: graph_lookup never traverses a related edge to a hidden node ----


def _nodes():
    return {
        "pub": {
            "prompt": "", "section": "misc", "level": 3, "answer_type": "narrative",
            "answer": "Rocky the dog loves the park", "state": "answered",
            "visibility": "public", "provenance": "stated",
        },
        "priv": {
            "prompt": "", "section": "misc", "level": 3, "answer_type": "narrative",
            "answer": "Rocky bit the neighbour last year", "state": "answered",
            "visibility": "private", "provenance": "stated",
        },
    }


def test_lookup_public_only_does_not_cross_to_private_related_node():
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, _nodes())})
    # link the public node to the private one (mutual).
    store.link_related(db, UID, "pub", "priv", label="same dog")

    # Owner lookup: the private related node IS reachable one hop out.
    owner = store.graph_lookup(db, UID, node_id="pub")
    assert "priv" in owner["node_ids"]

    # Shared/public lookup: the private node is NEVER surfaced via the link.
    shared = store.graph_lookup(db, UID, node_id="pub", public_only=True)
    assert "priv" not in shared["node_ids"]
    assert "pub" in shared["node_ids"]
