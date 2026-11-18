"""Phase 6b: images are nodes (design §6, "images are nodes — SETTLED").

A sent image becomes an emergent node holding its Firebase Storage link plus
Ayma's read of the image, with its own visibility; it renders as the read (never
the raw URL), connected to the fact nodes via typed links.
"""

import person_graph as pg
import person_graph_render as render
import person_graph_store as store


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


_URL = "https://firebasestorage.example/users/u1/dog.jpg"


def _parent():
    # any real seed node works as the home parent
    return sorted(pg.seed())[0]


def test_add_image_node_creates_an_image_node():
    db = FakeDb()
    nid = store.add_image_node(
        db, "u1", _parent(), _URL, "A golden retriever in a park — likely the user's dog",
    )
    node = store.load_overlay(db, "u1")[nid]
    assert node["answer_type"] == "image"
    assert node["answer"] == _URL
    assert node["image_read"].startswith("A golden retriever")
    assert node["visibility"] == "private"  # private by default
    # effective graph carries the image fields through the merge
    g = store.effective(db, "u1")
    assert g[nid].answer_type == "image" and g[nid].image_read


def test_image_node_renders_the_read_never_the_url():
    db = FakeDb()
    store.add_image_node(
        db, "u1", _parent(), _URL, "The user's dog Rex", visibility="public",
    )
    g = store.effective(db, "u1")
    prose = render.persona_prose(g, include_ayma_only=True)
    assert "Rex" in prose
    assert _URL not in prose  # the raw storage link never appears in prose
    pub = render.public_sections(g)
    blob = "\n".join(b for s in pub for b in s["bullets"])
    assert "Rex" in blob and _URL not in blob


def test_ayma_only_image_excluded_from_public():
    db = FakeDb()
    store.add_image_node(
        db, "u1", _parent(), _URL, "a private medical photo", visibility="ayma_only",
    )
    g = store.effective(db, "u1")
    pub = render.public_sections(g)
    blob = "\n".join(b for s in pub for b in s["bullets"])
    assert "medical" not in blob
    # but Ayma's own grounding sees it
    assert "medical" in render.persona_prose(g, include_ayma_only=True)


def test_image_node_links_to_fact_nodes():
    db = FakeDb()
    nid = store.add_image_node(
        db, "u1", _parent(), _URL, "the user's dog",
        links=[{"target": _parent(), "type": "same_topic"}],
    )
    g = store.effective(db, "u1")
    assert any(l.target == _parent() for l in g[nid].links)


def test_image_delete_retains_as_ayma_only():
    # Founder retention rule (Nov 18): deleting an IMAGE node does not erase it —
    # it moves to ayma_only, node + read + provenance kept, so it leaves the
    # story/profile/public surfaces yet stays in the owner's Ayma-only view.
    db = FakeDb()
    nid = store.add_image_node(
        db, "u1", _parent(), _URL, "a selfie at the beach",
        visibility="private", source_kind="chat_upload", source_ref="msg_42",
    )
    result = store.retire_image_or_delete(db, "u1", nid)
    assert result == {"retired": nid, "removed": 0}
    # The node SURVIVES, now ayma_only, with its read + provenance intact.
    node = store.load_overlay(db, "u1")[nid]
    assert node["answer_type"] == "image"
    assert node["visibility"] == "ayma_only"
    assert node["image_read"] == "a selfie at the beach"
    assert node["answer"] == _URL
    assert node["source_kind"] == "chat_upload" and node["source_ref"] == "msg_42"
    # It still shows in the OWNER's photo view (findable), carrying ayma_only…
    owner_rows = store.image_nodes_for_view(db, "u1")
    assert any(r["id"] == nid and r["visibility"] == "ayma_only" for r in owner_rows)
    # …but NEVER on a public/shared surface (privacy: ayma_only is not public).
    assert store.image_nodes_for_view(db, "u1", public_only=True) == []
    g = store.effective(db, "u1")
    blob = "\n".join(b for s in render.public_sections(g) for b in s["bullets"])
    assert "beach" not in blob


def test_retained_ayma_only_image_never_on_story_or_public_body():
    # Scout NOTE 256 (Privacy P0): a deleted-but-retained image moves to
    # ayma_only. Even with the dev flag ON (include_ayma_only=True, which keeps
    # ayma_only TEXT inferences visible on the owner's story body), the retained
    # IMAGE must NOT appear in the story / public node-tree body — it belongs only
    # in the owner's Ayma-only Photos view.
    import person_graph_tree as tree

    db = FakeDb()
    kept = store.add_image_node(
        db, "u1", _parent(), _URL, "a public selfie", visibility="public",
    )
    retired = store.add_image_node(
        db, "u1", _parent(), _URL + "?x=2", "a deleted beach photo",
        visibility="private",
    )
    store.retire_image_or_delete(db, "u1", retired)  # -> ayma_only
    g = store.effective(db, "u1")

    def _image_ids(surface):
        t = tree.node_tree(g, surface=surface, include_ayma_only=True)
        ids = []
        stack = [n for s in t["sections"] for n in s["nodes"]]
        while stack:
            n = stack.pop()
            if n.get("answer_type") == "image":
                ids.append(n["id"])
            stack.extend(n.get("children", []))
        return ids

    # Story body (dev flag ON): the retained ayma_only image is GONE; the public
    # image still renders.
    story_ids = _image_ids("story")
    assert retired not in story_ids
    assert kept in story_ids
    # Public profile: neither ayma_only nor private, only the public image.
    assert _image_ids("publicProfile") == [kept]
    # The retained image is still findable in the owner's Ayma-only Photos view.
    owner_rows = store.image_nodes_for_view(db, "u1")
    assert any(r["id"] == retired and r["visibility"] == "ayma_only" for r in owner_rows)


def test_non_image_node_hard_deletes_as_before():
    # Retention is scoped to IMAGE nodes: every other node kind still hard-deletes.
    db = FakeDb()
    nid = store.add_node(
        db, "u1", _parent(), "a plain fact", answer="I love hiking",
    )
    result = store.retire_image_or_delete(db, "u1", nid)
    assert result == {"retired": None, "removed": 1}
    assert nid not in store.load_overlay(db, "u1")  # truly gone, not retained


def test_add_image_node_rejects_bad_input():
    db = FakeDb()
    import pytest

    with pytest.raises(ValueError):
        store.add_image_node(db, "u1", "ghost_parent", _URL, "read")
    with pytest.raises(ValueError):
        store.add_image_node(db, "u1", _parent(), "", "read")  # no url
    with pytest.raises(ValueError):
        store.add_image_node(db, "u1", _parent(), _URL, "read", visibility="nope")
