"""2o P0 — report → Node-Visualiser tree adapter.

Pins the block→node conversion for the founder-named node kinds (SCORE/STAT,
CONFIDENCE, CANDIDATE, LINK) plus text / attribute / image / photo-grid, and
that ``report_node_tree`` reuses ``report_hub.get_report`` (so every type,
match included, gets a tree with its owner/permission checks intact).
"""
import report_blocks as rb
import report_hub
import report_tree
def _nodes(block, slug="sec", i=0):
    return report_tree._block_to_nodes(block, slug, i)
def test_numeric_stat_becomes_a_score_node():
    n = _nodes(rb.stat_block("face:overall", "Overall", 8, basis="measured"))[0]
    assert n["answer_type"] == "stat"
    assert n["label"] == "Overall"
    assert n["stat_value"] == 8.0
    assert n["stat_text"] == "8"
    assert n["stat_basis"] == "measured"
def test_non_numeric_stat_becomes_a_confidence_node_without_a_value():
    n = _nodes(rb.stat_block("confidence", "Confidence", "Low", editable=False))[0]
    assert "stat_value" not in n  # non-numeric → band pill, no bar
    assert n["stat_text"] == "Low"
def test_percent_string_score_becomes_a_banded_score_bar_not_a_band_pill():
    # A match report's top-line "Match score" is a percent STRING ("52%", from
    # `report_adapters.match_blocks`). It must render as a banded 0..100
    # ScoreBar — the same graphic its sub-dimension scores get — not the flat
    # CONFIDENCE band pill reserved for non-numeric words (2o P3; founder: "the
    # match report lost its graphics").
    n = _nodes(
        rb.stat_block("score", "Match score", "52%",
                      basis="High confidence", editable=False)
    )[0]
    assert n["stat_value"] == 52.0          # numeric → ScoreBar
    assert n["stat_text"] == "52%"          # the "%" is kept for the readout
    assert n["stat_basis"] == "High confidence"
def test_link_block_becomes_a_link_node_with_platform():
    n = _nodes(rb.link_block("link:0", "https://x.com/jane", label="Jane", tag="x"))[0]
    assert n["answer_type"] == "link"
    assert n["link_url"] == "https://x.com/jane"
    assert n["link_platform"] == "x"
    assert n["label"] == "Jane"
def test_pending_candidate_photo_becomes_a_candidate_node():
        rb.photo_block("candidate:abc", "https://site/p.jpg",
                       caption="Found online", status="pending")
    assert n["answer_type"] == "candidate"
    assert n["candidate_id"] == "abc"
    assert n["image_url"] == "https://site/p.jpg"
def test_ordinary_verified_photo_becomes_an_image_node_with_verdict():
    n = _nodes(rb.photo_block("web:0", "https://site/p.jpg",
                              caption="A photo", verified=True))[0]
    assert n["answer_type"] == "image"
    assert n["is_you"] == "yes"
    assert n["image_read"] == "A photo"
def test_attribute_becomes_a_standard_labelled_field():
    n = _nodes(rb.attribute_block("attr:eyes", "Eyes", "Brown"))[0]
    assert n["standard"] is True
    assert n["standard_label"] == "Eyes"
    assert n["text"] == "Brown"
def test_photo_grid_expands_to_one_image_node_per_photo():
    block = rb.photo_grid_block(
        "grid:0",
        [{"url": "u1", "caption": "a"}, {"url": "u2", "caption": "b"}],
    )
    out = _nodes(block)
    assert [n["answer_type"] for n in out] == ["image", "image"]
    assert [n["image_url"] for n in out] == ["u1", "u2"]
    assert out[0]["id"] != out[1]["id"]  # unique ids
def test_report_node_tree_reuses_get_report_and_shapes_sections(monkeypatch):
    def _fake_get_report(db, report_type, report_id, viewer_uid):
        assert report_type == "match"
        return {
            "title": "Match",
            "sections": [
                {
                    "heading": "Score",
                    "blocks": [
                        rb.stat_block("match:overall", "Match score", 31,
                                      basis="Low confidence", editable=False),
                        rb.stat_block("confidence", "Confidence", "Low",
                                      editable=False),
                    ],
                },
                    "heading": "What lines up",
                    "blocks": [rb.text_block("t:0", "You both love hiking.")],
            ],
            "meta": {"owner_uid": "u1", "viewer_can_edit": False},
        }
    monkeypatch.setattr(report_hub, "get_report", _fake_get_report)
    tree = report_tree.report_node_tree(None, "match", "m1", "u1")
    assert tree["surface"] == "report"
    assert tree["title"] == "Match"
    assert tree["meta"]["viewer_can_edit"] is False
    assert [s["title"] for s in tree["sections"]] == ["Score", "What lines up"]
    score = tree["sections"][0]["nodes"]
    assert score[0]["answer_type"] == "stat" and score[0]["stat_value"] == 31.0
    assert score[1]["answer_type"] == "stat" and "stat_value" not in score[1]
    assert tree["sections"][1]["nodes"][0]["text"] == "You both love hiking."
def test_report_node_tree_propagates_permission_error(monkeypatch):
    import pytest
    def _boom(*a, **k):
        raise PermissionError("nope")
    monkeypatch.setattr(report_hub, "get_report", _boom)
    with pytest.raises(PermissionError):
        report_tree.report_node_tree(None, "appearance", "current", "other")
def test_report_node_tree_propagates_key_error_for_a_non_participant_match(monkeypatch):
    # 2o P3 — a match report is readable only by its two participants. A
    # non-participant resolves to no owner (`report_hub.resolve_owner` → None),
    # so `get_report` raises `KeyError`; the tree adapter must propagate it
    # (the route maps it to a 404), never leak the score to a stranger.
    def _not_found(db, report_type, report_id, viewer_uid):
        raise KeyError("No such report.")
    monkeypatch.setattr(report_hub, "get_report", _not_found)
    with pytest.raises(KeyError):
        report_tree.report_node_tree(None, "match", "alice-uid__bob-uid", "eve-uid")
def test_snapshot_node_tree_shapes_sections_without_report_hub(monkeypatch):
    # The token-scoped (2o P5) path must NOT re-fetch through report_hub: the
    # public /s/{token} read is authorized by the token alone. If it tried,
    # this would blow up.
    def _boom(*a, **k):  # pragma: no cover - must never run
        raise AssertionError("snapshot_node_tree must not call report_hub")
    snapshot = {
        "title": "Shared research",
        "report_type": "deep_dive",
        "sections": [
            {
                "heading": "Overview",
                "blocks": [
                    rb.text_block("t:0", "Hello from a snapshot."),
                    rb.stat_block("score", "Score", 7, basis="measured"),
                ],
            }
        ],
    }
    tree = report_tree.snapshot_node_tree(snapshot)
    assert tree["title"] == "Shared research"
    # meta mirrors /s/{token}/data verbatim — no owner, never editable.
    assert tree["meta"] == {"owner_uid": "", "viewer_can_edit": False}
    assert [s["title"] for s in tree["sections"]] == ["Overview"]
    nodes = tree["sections"][0]["nodes"]
    assert nodes[0]["text"] == "Hello from a snapshot."
    assert nodes[1]["answer_type"] == "stat" and nodes[1]["stat_value"] == 7.0
def test_snapshot_node_tree_tolerates_empty_or_malformed_snapshot():
    assert report_tree.snapshot_node_tree({})["sections"] == []
    assert report_tree.snapshot_node_tree({"sections": [None, "bad"]})[
        "sections"
    ] == []
