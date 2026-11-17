"""NOTE 250 visualiser follow-ups (backend halves).

Item 1: Make public/private must work on a STRUCTURED level-1 node that carries
no visibility field of its own (a seed node) — the resolver flips it instead of
"could not find the line".
Item 3: the Career visualiser's public LinkedIn button — a `link` node built
from the profile doc's linkedin_url.
"""

import career_timeline
import person_graph as pg
import person_graph_store as store
import schema


# A Firestore fake with nested collections + get() (mirrors test_image_nodes).
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


# --- item 1: flip a structured level-1 seed node ---------------------------
def test_cascade_flips_a_structured_level1_seed_node():
    db = FakeDb()
    # `date_of_birth` is a level-1 structured seed node with no overlay entry.
    nid = "date_of_birth"
    assert pg.seed_node(nid) is not None and pg.seed_node(nid).level == 1
    changed = store.set_visibility_cascade(db, "u1", nid, "public")
    assert changed >= 1
    g = store.effective(db, "u1")
    assert g[nid].visibility.value == "public"
    # and flipping it back works too (no "could not find the line").
    store.set_visibility_cascade(db, "u1", nid, "private")
    assert store.effective(db, "u1")[nid].visibility.value == "private"


# --- item 3: the Career LinkedIn link node ---------------------------------
def test_linkedin_link_node_from_profile_doc():
    db = FakeDb()
    schema.profile_doc(db, "u1").set(
        {schema.PF_LINKEDIN_URL: "https://www.linkedin.com/in/jane"}
    )
    node = career_timeline.linkedin_link_node(db, "u1")
    assert node is not None
    assert node["answer_type"] == "link"
    assert node["link_platform"] == "linkedin"
    assert node["link_url"] == "https://www.linkedin.com/in/jane"
    assert node["section"] == "career"
    assert node["visibility"] == "public"


def test_linkedin_link_node_none_without_a_url():
    db = FakeDb()
    assert career_timeline.linkedin_link_node(db, "u1") is None
    # A non-LinkedIn URL is not accepted.
    schema.profile_doc(db, "u1").set({schema.PF_LINKEDIN_URL: "https://x.com/jane"})
    assert career_timeline.linkedin_link_node(db, "u1") is None


def test_inject_linkedin_button_prepends_into_career_section():
    from routes import profile as profile_routes

    tree = {
        "surface": "story",
        "sections": [
            {"page_type": "career", "title": "Work & ambition", "order": 3,
             "nodes": [{"id": "job1", "answer_type": "text", "text": "Analyst"}]},
        ],
    }

    class _Ctx:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    # get_db is called inside _inject; patch it to our fake.
    db = FakeDb()
    schema.profile_doc(db, "u1").set(
        {schema.PF_LINKEDIN_URL: "https://www.linkedin.com/in/jane"}
    )
    import routes.profile as rp

    orig = rp.get_db
    rp.get_db = lambda: db
    try:
        rp._inject_linkedin_button("u1", "story", tree)
    finally:
        rp.get_db = orig

    career = next(s for s in tree["sections"] if s["page_type"] == "career")
    assert career["nodes"][0]["id"] == career_timeline.LINKEDIN_NODE_ID
    assert career["nodes"][1]["id"] == "job1"  # existing nodes kept, after it
