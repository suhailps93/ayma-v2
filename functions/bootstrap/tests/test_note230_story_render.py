"""NOTE 230: Your Story is a render of the GRAPH, not the frozen wiki.

NOTE 227 gated wiki ingest; NOTE 228 made a volunteered fact land in the graph as
a loose emergent node homed in ``misc`` / Little Extras. But Your Story
(``profile_bullets.get_bullets``) still read the frozen ``wiki_pages`` store, so
that fact never appeared — ``person_graph_render.story_sections`` (the graph
render) existed but was wired to nothing. The fix reads Your Story from the graph
when ``person_graph_reads`` is on (design §8.1), so a loose misc node renders
under Little Extras. Flag off → the wiki path runs unchanged.

NOT covered (Phase-6b story write-back, flagged): editing/creating a bullet still
writes the wiki; those edits won't round-trip into the graph-backed read yet.
"""

import dataclasses

import config
import person_graph as pg
import person_graph_render as render
import person_graph_source
import person_graph_store as store
import profile_bullets
import question_tree
import story
from config import CONFIG


# --- fake Firestore (overlay-only; the graph-authoritative read never touches
#     wiki_pages, so no .stream() is needed) ---------------------------------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _DocRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def collection(self, name):
        return _CollRef(self._st, self._key + (name,))

    def get(self):
        return _Snap(self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _set_reads(monkeypatch, reads: bool):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )


def _misc_section(payload: dict) -> dict:
    return next(s for s in payload["sections"] if s["page_type"] == "misc")


# --- the render surfaces a loose misc node ----------------------------------


def test_loose_misc_node_renders_under_little_extras():
    # A parentless, level-1, stated, private narrative node homed in misc — the
    # exact shape person_graph_store.add_loose_node writes (NOTE 228's remember).
    g = pg.effective_graph(
        {
            "emergent.figma": {
                "prompt": "Daniel is learning Figma variables on Fridays.",
                "answer": "Daniel is learning Figma variables on Fridays.",
                "answer_type": "narrative",
                "section": "misc",
                "level": 1,
                "visibility": "private",
            }
        }
    )
    out = render.story_sections(g)
    misc = _misc_section(out)
    assert misc["title"] == "Little Extras"
    texts = [b["text"] for b in misc["bullets"]]
    assert "Daniel is learning Figma variables on Fridays." in texts
    assert not misc["empty"]
    assert all(b["visibility"] == "private" for b in misc["bullets"])


# --- get_bullets (Your Story) reads the graph when authoritative ------------


def test_get_bullets_reads_graph_when_authoritative(monkeypatch):
    _set_reads(monkeypatch, True)
    db = FakeDb()
    store.add_loose_node(db, "u1", "Finds quiet on a bench by the lake at sunset")
    # If get_bullets read the (empty) wiki it would blow up on .stream(); the
    # graph-authoritative path never touches wiki_pages.
    out = profile_bullets.get_bullets(db, "u1")
    assert out["visibilities"] == ["public", "private"]
    misc = _misc_section(out)
    assert misc["title"] == "Little Extras"
    assert any(
        "bench by the lake" in b["text"] for b in misc["bullets"]
    ), "the volunteered fact must render under Little Extras from the graph"


def test_get_bullets_uses_the_wiki_when_flag_off(monkeypatch):
    _set_reads(monkeypatch, False)
    db = FakeDb()
    store.add_loose_node(db, "u1", "This graph fact must NOT appear when flag off")

    called = {"graph": False}

    def _boom(*a, **k):
        called["graph"] = True
        raise AssertionError("story_bullets must not be consulted when flag off")

    monkeypatch.setattr(person_graph_source, "story_bullets", _boom)
    # Flag off → the wiki read path runs; stub it to an empty story.
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    out = profile_bullets.get_bullets(db, "u1")
    assert called["graph"] is False
    # Every canonical section present and empty (no page yet), from the wiki path.
    assert {s["page_type"] for s in out["sections"]} >= set(
        question_tree.ordered_page_types()
    )
    assert _misc_section(out)["empty"] is True


def test_get_bullets_falls_back_to_wiki_when_graph_read_fails(monkeypatch):
    _set_reads(monkeypatch, True)
    db = FakeDb()
    # Graph read returns None (a failed/empty read) → never a blank story: fall
    # through to the frozen-wiki path rather than raising or returning nothing.
    monkeypatch.setattr(person_graph_source, "story_bullets", lambda db, uid, **k: None)
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    out = profile_bullets.get_bullets(db, "u1")
    assert {s["page_type"] for s in out["sections"]} >= set(
        question_tree.ordered_page_types()
    )
