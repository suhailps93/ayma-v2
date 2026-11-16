"""NOTE 233 defects — match recalc + completeness drop + L1 seed staleness.

Covered here (the backend defects):
* Defect 3 — a conversational edit to an L1 seed field (``set_profile_field``)
  updates the graph SEED node itself (not just ``profile/main``), so matching's
  graph hydration and Your Story stay fresh. This also unblocks defect 1's fresh
  pair doc (matching hydrates from the seed via ``load_user``).
* Defect 2 — a dealt-with (skipped/declined/"none") question stays COVERED after
  the reader migration, so completeness doesn't drop and next_questions doesn't
  re-ask it.
(Defect 1's client crash is a Flutter fix — public_profile_screen, verified by
flutter analyze.)
"""

import dataclasses

import config
from config import CONFIG
import person_graph as pg


# --- Firestore fake (tuple-path; graph + profile) --------------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
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
        return _Snap(self._key[-1], self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))

    def stream(self):
        depth = len(self._key)
        for key, data in list(self._st.docs.items()):
            if len(key) == depth + 1 and key[:depth] == self._key and data is not None:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _set_reads(monkeypatch, reads: bool):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )


# --- Defect 3 — L1 seed field stays fresh ----------------------------------


def test_set_profile_field_updates_graph_seed_node(monkeypatch):
    import person_graph_store as store
    import skills.set_profile_field as spf

    db = FakeDb()
    # the user already had San Jose on their primary_location seed node
    store.set_answer(db, "u1", "primary_location", "San Jose")
    _set_reads(monkeypatch, True)

    fn = spf.SKILL.bind(db, "u1", session_id="s", turn_index=0, turns=[])
    out = fn("location", "Seattle")
    assert out == "set location"

    entry = store.node_overlay_entry(db, "u1", "primary_location")
    assert entry["answer"] == "Seattle", "the seed node is updated, not a parallel node"
    # the superseded value retires to Ayma-only history (answer-history rule)
    assert any(h.get("answer") == "San Jose" for h in entry.get("history") or [])
    # no parallel emergent location node was minted
    emergent = [
        nid for nid in store.load_overlay(db, "u1")
        if nid.startswith("emergent.")
    ]
    assert emergent == []


def test_set_profile_field_hydrates_matching_profile(monkeypatch):
    """The updated seed flows into the matching profile (load_user), so a refresh
    scores the new location instead of the stale one (defect 1 fresh pair doc)."""
    import person_graph_source as src
    import person_graph_store as store
    import skills.set_profile_field as spf

    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"location": "San Jose"}
    store.set_answer(db, "u1", "primary_location", "San Jose")
    _set_reads(monkeypatch, True)

    spf.SKILL.bind(db, "u1", turns=[])("location", "Seattle")
    profile, _q = src.load_user(db, "u1")
    assert profile["location"] == "Seattle"


def test_set_profile_field_flag_off_leaves_graph_untouched(monkeypatch):
    import person_graph_store as store
    import skills.set_profile_field as spf

    db = FakeDb()
    store.set_answer(db, "u1", "primary_location", "San Jose")
    _set_reads(monkeypatch, False)
    spf.SKILL.bind(db, "u1", turns=[])("location", "Seattle")
    # flag off → the graph is not written by the tool (today's behaviour)
    assert store.node_overlay_entry(db, "u1", "primary_location")["answer"] == "San Jose"


# --- Defect 2 — dealt-with questions stay covered --------------------------


def test_completeness_qstore_counts_dealt_with_nodes():
    import person_graph_source as src
    import person_graph_store as store

    db = FakeDb()
    store.set_answer(db, "u1", "gender_identity", "Woman")  # a real answer
    # a dealt-with (declined) question: a PREFER_NOT_TO_SAY node on its seed, the
    # exact shape person_graph_migrate writes for a skipped/declined/"none" value.
    overlay = store.load_overlay(db, "u1")
    overlay["family_of_origin_narrative"] = {
        "state": pg.NodeState.PREFER_NOT_TO_SAY.value,
        "provenance": pg.Provenance.STATED.value,
    }
    store.replace_overlay(db, "u1", overlay)
    graph = store.effective(db, "u1")

    # matching store: answered only (a declined question never scores a match)
    sq = src.structured_qstore(graph)
    assert "gender_identity" in sq
    assert "family_of_origin_narrative" not in sq

    # completeness store: the dealt-with node IS covered (so it isn't re-asked
    # and the score doesn't drop)
    cq = src.completeness_qstore(graph)
    assert "gender_identity" in cq
    assert "family_of_origin_narrative" in cq
    assert cq["family_of_origin_narrative"]["source"] == "stated"  # cov 1.0


def test_dealt_with_survives_migration_and_counts(monkeypatch):
    """End to end: a skipped questionnaire answer migrates to a covered node and
    completeness counts it — the recompute doesn't lose it (defect 2)."""
    import person_graph_migrate as mig
    import person_graph_source as src

    db = FakeDb()
    db.docs[("users", "u1", "questionnaire", "gender_identity")] = {
        "node_id": "gender_identity", "value": "Woman", "source": "stated",
    }
    db.docs[("users", "u1", "questionnaire", "past_relationship_narrative")] = {
        "node_id": "past_relationship_narrative", "value": "skipped", "source": "stated",
    }
    overlay = mig.build_overlay(db, "u1")
    graph = pg.effective_graph(overlay, intent=None)
    cq = src.completeness_qstore(graph)
    # both the real answer and the skipped (dealt-with) question are covered
    assert "gender_identity" in cq
    assert "past_relationship_narrative" in cq
