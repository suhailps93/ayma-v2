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


def test_add_image_node_rejects_bad_input():
    db = FakeDb()
    import pytest

    with pytest.raises(ValueError):
        store.add_image_node(db, "u1", "ghost_parent", _URL, "read")
    with pytest.raises(ValueError):
        store.add_image_node(db, "u1", _parent(), "", "read")  # no url
    with pytest.raises(ValueError):
        store.add_image_node(db, "u1", _parent(), _URL, "read", visibility="nope")
