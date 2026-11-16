"""Phase 5c: per-user emergent gates (design §4.3).

A seed node a user raised to the top of their weight budget (confirmed, §4.4)
becomes a personal hard filter that fires on a partner clash with data present.
"""

import match_deterministic as md
import person_graph_source as src
import person_graph_store as store


# --- a Firestore fake with a graph doc -------------------------------------


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


def _q(**kw):
    return {k: {"value": v} for k, v in kw.items()}


# --- personal_gate_ids -----------------------------------------------------


def test_personal_gate_ids_reads_top_band_seed_nodes_only():
    db = FakeDb()
    # a seed node raised to crucial -> a personal gate
    store.set_answer(db, "u1", "social_energy", 8)
    store.set_weight(db, "u1", "social_energy", 5)
    # a seed node at a modest weight -> NOT a gate
    store.set_answer(db, "u1", "cleanliness_index", 6)
    store.set_weight(db, "u1", "cleanliness_index", 2)
    # an emergent node raised to crucial -> NOT a deterministic gate (no shared id)
    nid = store.add_node(db, "u1", "social_energy", "fav band", answer="Taylor Swift")
    store.set_weight(db, "u1", nid, 5)

    gates = src.personal_gate_ids(db, "u1")
    assert gates == frozenset({"social_energy"})


# --- score_structured personal-gate behaviour ------------------------------


def test_personal_gate_fires_on_clash():
    base = md.score_structured(
        {"name": "Ann"}, _q(social_energy=1), {}, _q(social_energy=10), "long-term"
    )
    assert not any(g.get("personal") for g in base["gate_failures"])

    gated = md.score_structured(
        {"name": "Ann"}, _q(social_energy=1), {}, _q(social_energy=10), "long-term",
        personal_gates_a={"social_energy"},
    )
    personal = [g for g in gated["gate_failures"] if g.get("personal")]
    assert len(personal) == 1 and personal[0]["node_id"] == "social_energy"
    assert "Ann" in personal[0]["reason"]
    # a fired gate caps the overall score
    assert gated["structured_overall"] <= base["structured_overall"]


def test_personal_gate_silent_when_compatible():
    g = md.score_structured(
        {}, _q(social_energy=6), {}, _q(social_energy=5), "long-term",
        personal_gates_a={"social_energy"},
    )
    assert not any(x.get("personal") for x in g["gate_failures"])


def test_personal_gate_missing_partner_data_never_fails():
    g = md.score_structured(
        {}, _q(social_energy=1), {}, _q(), "long-term",
        personal_gates_a={"social_energy"},
    )
    assert not any(x.get("personal") for x in g["gate_failures"])


def test_personal_gate_deduped_against_fixed_gate():
    # relationship_intent is already a fixed gate; a personal gate on it must not
    # add a second failure for the same node.
    g = md.score_structured(
        {}, _q(relationship_intent="Long-term"),
        {}, _q(relationship_intent="Long-term"), "long-term",
        personal_gates_a={"relationship_intent"},
    )
    assert not any(x.get("personal") for x in g["gate_failures"])


def test_empty_personal_gates_is_todays_behaviour():
    a = md.score_structured({}, _q(social_energy=1), {}, _q(social_energy=10), "long-term")
    b = md.score_structured(
        {}, _q(social_energy=1), {}, _q(social_energy=10), "long-term",
        personal_gates_a=frozenset(), personal_gates_b=frozenset(),
    )
    assert a["gate_failures"] == b["gate_failures"]
    assert a["structured_overall"] == b["structured_overall"]
