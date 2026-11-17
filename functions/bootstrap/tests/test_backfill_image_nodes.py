"""The image-node backfill's counts logic (dry-run) is proven here without
touching Firestore. The script itself is staging-only and run by hand."""

import asyncio
import importlib.util
import os

import photo_notes

_SCRIPT = os.path.join(
    os.path.dirname(__file__), "..", "..", "..", "scripts", "backfill_image_nodes.py"
)


def _load():
    spec = importlib.util.spec_from_file_location("backfill_image_nodes", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_plan_counts_nodes_carried_and_generated():
    bf = _load()
    photos = [
        {"url": "https://cdn/a.jpg", "source_kind": "chat", "source_ref": ""},
        {"url": "https://cdn/b.jpg", "source_kind": "web", "source_ref": "R1"},
        {"url": "https://cdn/c.jpg", "source_kind": "profile_grid", "source_ref": ""},
    ]
    reads_by_url = {"https://cdn/a.jpg": "a described photo", "https://cdn/b.jpg": "  "}
    counts = bf.plan(photos, reads_by_url)
    assert counts == {
        "photos": 3,
        "nodes": 3,
        "reads_carried_over": 1,  # only a.jpg has a real read
        "reads_generated": 2,  # b (blank) + c (missing)
    }


def test_dry_run_returns_counts_and_writes_nothing(monkeypatch):
    bf = _load()
    photos = [
        {"url": "https://cdn/x.jpg", "source_kind": "chat", "source_ref": "s1"},
        {"url": "https://cdn/y.jpg", "source_kind": "web", "source_ref": "R1"},
    ]

    async def _fake_collect(db, uid):
        return photos

    monkeypatch.setattr(bf, "_collect", _fake_collect)
    # y has a carried read; x has none.
    notes = {photo_notes.photo_id("https://cdn/y.jpg"): {"context": "a read", "is_user": "yes"}}
    monkeypatch.setattr(photo_notes, "all_notes", lambda db, uid: notes)

    wrote = []
    import person_graph_store as pg_store
    monkeypatch.setattr(pg_store, "add_photo_fact", lambda *a, **k: wrote.append(k))

    async def _no_caption(url):
        raise AssertionError("dry-run must not generate reads")

    counts = asyncio.run(
        bf.run("u1", dry_run=True, db=object(), caption_fn=_no_caption)
    )
    assert counts == {
        "photos": 2,
        "nodes": 2,
        "reads_carried_over": 1,
        "reads_generated": 1,
    }
    assert wrote == []  # dry-run writes NOTHING
