"""Nov 16 2026 founder direction (via Astro): the person graph must show
EVERYTHING in the graph store, not just story bullets. The appearance report,
web-findings, photo, skill and assessment nodes all live in the overlay but
never became bullets, so the graph used to hide them. These tests pin that
``profile_graph`` now surfaces every store node, visibility-filtered, each
tappable node carrying an ``open`` target.
"""

import person_graph_store as store
import profile_graph
from fake_firestore import FakeDb


def _seed(db, uid):
    store.replace_overlay(
        db,
        uid,
        {
            "emergent.appearance.report": {
                "prompt": "Appearance report", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Face 7.0, Body 6.4",
                "state": "answered", "visibility": "private",
            },
            "emergent.webfind.report.RID123": {
                "prompt": "Web findings", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Found a LinkedIn.",
                "state": "answered", "visibility": "private",
            },
            "emergent.image.photo1": {
                "prompt": "Profile photo", "section": "identity", "level": 2,
                "answer_type": "image", "answer": "https://cdn/p1.jpg",
                "image_read": "A man smiling outdoors.",
                "state": "answered", "visibility": "public",
            },
            "emergent.skill.physical-profile": {
                "prompt": "Physical profile", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Athletic build.",
                "state": "answered", "visibility": "private",
            },
            "emergent.assess.summary": {
                "prompt": "Ayma's assessment", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Thoughtful and warm.",
                "state": "answered", "visibility": "ayma_only",
            },
        },
    )


def _by_id(g):
    return {n["id"]: n for n in g["nodes"]}


def test_owner_graph_surfaces_every_store_node_with_open_targets():
    db = FakeDb()
    _seed(db, "u1")
    g = profile_graph.get_graph(db, "u1")
    nodes = _by_id(g)

    # All the previously-hidden kinds now appear.
    kinds = {n["kind"] for n in g["nodes"]}
    assert {"report", "image", "skill", "assess"} <= kinds

    # The appearance report node opens the current Appearance report.
    appr = nodes["emergent.appearance.report"]
    assert appr["kind"] == "report"
    assert appr["open"] == {"type": "appearance_report", "id": "current"}

    # The web-findings node opens its deep-dive report by id.
    wf = nodes["emergent.webfind.report.RID123"]
    assert wf["open"] == {"type": "webfind_report", "id": "RID123"}

    # The photo node carries its url + Ayma's read, and opens the photo.
    img = nodes["emergent.image.photo1"]
    assert img["kind"] == "image"
    assert img["image_url"] == "https://cdn/p1.jpg"
    assert img["open"]["type"] == "image"
    assert img["open"]["url"] == "https://cdn/p1.jpg"
    assert img["open"]["read"] == "A man smiling outdoors."
    # The open target also carries the node's verdict + source for the viewer.
    assert "is_you" in img["open"]
    assert "source_kind" in img["open"]

    # Each node hangs off a section hub reachable from the centre.
    edge_pairs = {(e["from"], e["to"]) for e in g["edges"]}
    for nid in nodes:
        if nodes[nid]["kind"] in ("report", "image", "skill", "assess"):
            assert any(frm.startswith("sec:") and to == nid for frm, to in edge_pairs)
    titles = {s["title"] for s in g["sections"]}
    assert {"Appearance", "Web findings", "Ayma's assessment"} <= titles


def test_public_graph_hides_private_and_ayma_only_store_nodes():
    db = FakeDb()
    _seed(db, "u1")
    g = profile_graph.public_graph(db, "u1")
    ids = {n["id"] for n in g["nodes"]}

    # Only the PUBLIC photo survives; the private report/webfind/skill and the
    # Ayma-only assessment are all dropped.
    assert "emergent.image.photo1" in ids
    for hidden in (
        "emergent.appearance.report",
        "emergent.webfind.report.RID123",
        "emergent.skill.physical-profile",
        "emergent.assess.summary",
    ):
        assert hidden not in ids
