"""Image nodes carry a structured is-you verdict + source provenance + read,
keyed by content hash (founder Nov 16 2026). The photo view renders from the
node, so these pin the ingestion writes + the node-driven read."""

import person_graph_store as store
from test_person_graph_store import FakeDb, _profile


def test_is_you_from_verdict_maps_face_match_to_structured():
    assert store.is_you_from_verdict("of user") == "yes"
    assert store.is_you_from_verdict("yes") == "yes"
    assert store.is_you_from_verdict("other") == "no"
    assert store.is_you_from_verdict("no") == "no"
    assert store.is_you_from_verdict("") == "unknown"
    assert store.is_you_from_verdict(None) == "unknown"
    assert store.is_you_from_verdict("unsure") == "unknown"


def test_add_photo_fact_writes_verdict_source_and_read_on_the_image_node():
    db = FakeDb(_profile("u1"))
    res = store.add_photo_fact(
        db, "u1",
        image_url="https://cdn/p.jpg", image_read="A man smiling outdoors.",
        fact_text="at the beach", image_node_id="emergent.image.abc123",
        is_you="yes", source_kind="chat", source_ref="sess-7",
    )
    assert res is not None
    overlay = store.load_overlay(db, "u1")
    node = overlay["emergent.image.abc123"]
    assert node["answer_type"] == "image"
    assert node["answer"] == "https://cdn/p.jpg"
    assert node["image_read"] == "A man smiling outdoors."
    assert node["is_you"] == "yes"
    assert node["source_kind"] == "chat"
    assert node["source_ref"] == "sess-7"
    assert node["source_created_at"]  # stamped at ingestion


def test_reingest_same_content_updates_in_place_and_never_duplicates():
    db = FakeDb(_profile("u1"))
    nid = "emergent.image.deadbeef"
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/v1.jpg", image_read="first read",
        fact_text="x", image_node_id=nid, is_you="unknown", source_kind="chat",
    )
    before = store.load_overlay(db, "u1")[nid]
    created_at = before["source_created_at"]
    image_nodes_before = [
        k for k, v in store.load_overlay(db, "u1").items()
        if isinstance(v, dict) and v.get("answer_type") == "image"
    ]
    # Same bytes re-shared under a fresh URL: a better read + a now-known verdict.
    out = store.add_photo_fact(
        db, "u1", image_url="https://cdn/v2.jpg", image_read="a sharper read",
        fact_text="x", image_node_id=nid, is_you="yes", source_kind="chat",
    )
    assert out is None  # no duplicate fact minted on a re-share
    after = store.load_overlay(db, "u1")[nid]
    image_nodes_after = [
        k for k, v in store.load_overlay(db, "u1").items()
        if isinstance(v, dict) and v.get("answer_type") == "image"
    ]
    assert len(image_nodes_after) == len(image_nodes_before) == 1  # still ONE image node
    assert after["answer"] == "https://cdn/v2.jpg"  # url updated
    assert after["image_read"] == "a sharper read"  # read refreshed
    assert after["is_you"] == "yes"  # verdict upgraded from unknown
    assert after["source_created_at"] == created_at  # first-ingest time is sticky


def test_reingest_preserves_user_visibility_choice():
    db = FakeDb(_profile("u1"))
    nid = "emergent.image.c0ffee11"
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/a.jpg", image_read="r",
        fact_text="f", image_node_id=nid,
    )
    # The user makes it public, then the same photo is re-ingested (default private).
    store.set_visibility(db, "u1", nid, "public")
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/a2.jpg", image_read="r2",
        fact_text="f", image_node_id=nid,
    )
    assert store.load_overlay(db, "u1")[nid]["visibility"] == "public"


def test_image_nodes_for_view_returns_node_fields_newest_first():
    db = FakeDb(_profile("u1"))
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/old.jpg", image_read="older",
        fact_text="f1", image_node_id="emergent.image.0001",
        is_you="no", source_kind="web", source_ref="rid1",
        source_created_at="2026-01-01T00:00:00Z",
    )
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/new.jpg", image_read="newer",
        fact_text="f2", image_node_id="emergent.image.0002",
        is_you="yes", source_kind="chat", source_ref="sess-9",
        source_created_at="2026-06-01T00:00:00Z",
    )
    rows = store.image_nodes_for_view(db, "u1")
    assert [r["url"] for r in rows] == ["https://cdn/new.jpg", "https://cdn/old.jpg"]
    top = rows[0]
    assert top["id"] == "emergent.image.0002"
    assert top["read"] == "newer"
    assert top["is_you"] == "yes"
    assert top["source_kind"] == "chat"
    assert top["source_ref"] == "sess-9"


def test_image_nodes_for_view_public_only_filters_private():
    db = FakeDb(_profile("u1"))
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/priv.jpg", image_read="r",
        fact_text="f", image_node_id="emergent.image.aaaa",
    )
    store.add_photo_fact(
        db, "u1", image_url="https://cdn/pub.jpg", image_read="r",
        fact_text="f", image_node_id="emergent.image.bbbb",
    )
    store.set_visibility(db, "u1", "emergent.image.bbbb", "public")
    rows = store.image_nodes_for_view(db, "u1", public_only=True)
    assert [r["url"] for r in rows] == ["https://cdn/pub.jpg"]


def test_photo_nodes_for_view_maps_node_rows_to_the_strip_shape(monkeypatch):
    """main._photo_nodes_for_view maps the graph image-node rows to the Photos
    strip shape: source_kind→source, read→context, is_you→is_user (unknown
    blanked), node id preserved for the owner actions."""
    import main

    rows = [
        {"id": "emergent.image.a", "url": "https://cdn/a.jpg", "read": "a portrait",
         "is_you": "yes", "source_kind": "profile_grid", "source_ref": "",
         "source_created_at": "2026-02-01T00:00:00Z", "visibility": "public"},
        {"id": "emergent.image.b", "url": "https://cdn/b.jpg", "read": "",
         "is_you": "unknown", "source_kind": "appearance_report", "source_ref": "R1",
         "source_created_at": "2026-01-01T00:00:00Z", "visibility": "private"},
    ]
    monkeypatch.setattr(main, "get_db", lambda: object())
    import person_graph_store as pg_store
    monkeypatch.setattr(pg_store, "image_nodes_for_view", lambda db, uid: rows)

    out = main._photo_nodes_for_view("u1")
    assert out[0]["id"] == "emergent.image.a"
    assert out[0]["source"] == "profile"  # profile_grid -> profile
    assert out[0]["context"] == "a portrait"  # read -> context
    assert out[0]["is_user"] == "yes"  # verdict -> is_user
    assert out[0]["visibility"] == "public"
    assert out[1]["source"] == "appearance"  # appearance_report -> appearance
    assert out[1]["is_user"] == ""  # "unknown" blanked for the view
    assert out[1]["source_page"] == "R1"
