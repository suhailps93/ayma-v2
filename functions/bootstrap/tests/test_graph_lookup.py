"""The single graph lookup (founder Nov 17): ONE way to look up info in the
graph, with topic search that finds the one anchor node and walks its parents,
children and related links to pull everything connected in one call.
"""

import person_graph as pg
import person_graph_store as store


# A Firestore fake with get() (mirrors test_person_graph_images).
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
    def __init__(self, overlay):
        self.docs = {("users", "u1", "graph", "main"): {"nodes": dict(overlay)}}

    def collection(self, name):
        return _CollRef(self, (name,))


def _overlay():
    return {
        "emergent.hobby": {"prompt": "Hobbies", "section": "interests",
                           "level": 1, "answer": "rock climbing",
                           "visibility": "public"},
        "emergent.hobby.gear": {"prompt": "Gear", "section": "interests",
                                "level": 2, "answer": "trad rack",
                                "parent": "emergent.hobby"},
        "emergent.gym": {"prompt": "Gym", "section": "interests", "level": 1,
                         "answer": "climbs at Movement",
                         "links": [{"target": "emergent.hobby",
                                    "type": "related"}]},
        "emergent.job": {"prompt": "Job", "section": "career", "level": 1,
                         "answer": "analyst in Lisbon"},
        # an Ayma-only (assessment-style) node connected to the hobby
        "emergent.assess": {"prompt": "Note", "section": "interests", "level": 2,
                            "answer": "driven by achievement",
                            "parent": "emergent.hobby", "visibility": "ayma_only"},
    }


def test_topic_search_finds_the_one_anchor():
    db = FakeDb(_overlay())
    res = store.graph_lookup(db, "u1", topic="climbing")
    assert res["anchor"] == "emergent.hobby"


def test_lookup_pulls_parents_children_and_related_in_one_call():
    db = FakeDb(_overlay())
    res = store.graph_lookup(db, "u1", node_id="emergent.hobby")
    ids = set(res["node_ids"])
    # self + descendant (gear) + related (gym) + the ayma-only child
    assert "emergent.hobby" in ids
    assert "emergent.hobby.gear" in ids
    assert "emergent.gym" in ids
    assert "emergent.assess" in ids
    # an unrelated node is NOT pulled
    assert "emergent.job" not in ids


def test_ancestor_chain_is_walked_up():
    db = FakeDb(_overlay())
    res = store.graph_lookup(db, "u1", node_id="emergent.hobby.gear")
    ids = set(res["node_ids"])
    assert "emergent.hobby" in ids  # parent pulled when anchoring on the child


def test_include_ayma_only_false_drops_assessment_nodes():
    db = FakeDb(_overlay())
    res = store.graph_lookup(db, "u1", node_id="emergent.hobby",
                             include_ayma_only=False)
    assert "emergent.assess" not in set(res["node_ids"])


def test_no_anchor_returns_empty():
    db = FakeDb(_overlay())
    res = store.graph_lookup(db, "u1", topic="nonexistent topic xyz")
    assert res["anchor"] is None and res["nodes"] == []
