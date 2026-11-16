"""Phase 5b parity: the graph-backed scorer read == the old questionnaire read.

Migrates a questionnaire store into the graph, then asserts the deterministic
scorer's typed value for EVERY question_tree node is identical whether it reads
the old ``(profile, qstore)`` or the graph-derived one — so switching
``person_graph_reads`` on changes the data source, never the score.
"""

import match_deterministic as md
import person_graph_migrate as mig
import person_graph_source as src
import question_tree as qt


# --- Firestore fake with questionnaire + graph subcollections --------------


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
        for key, data in self._st.docs.items():
            if len(key) == depth + 1 and key[:depth] == self._key and data is not None:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _q(uid, nid, value, source="stated"):
    return {("users", uid, "questionnaire", nid): {"node_id": nid, "value": value, "source": source}}


def _fixture(*, social_energy_mirror=7):
    """A migrated-account fixture. ``social_energy_mirror`` is the profile's
    ``qz_social_energy`` mirror: 7 (matches the questionnaire value — the real
    cleanly-migrated case) for parity; a different value models a STALE mirror
    the graph must override once it is authoritative."""
    uid = "u1"
    profile = {
        "name": "Sam Rivera", "birthdate": "1994-02-02", "gender": "Woman",
        "interested_in": ["Men"], "location": "San Jose",
        "relationship_intent": "Long-term",
        "completeness": {"score": 55.0},
    }
    if social_energy_mirror is not None:
        profile["qz_social_energy"] = social_energy_mirror
    docs = {("users", uid, "profile", "main"): profile}
    # one answer of each structured kind, plus a couple more
    docs.update(_q(uid, "attachment_style", "Secure"))
    docs.update(_q(uid, "social_energy", 7))
    docs.update(_q(uid, "smoking_vaping", False))
    docs.update(_q(uid, "pets_owned", ["Cats", "Dogs"]))
    docs.update(_q(uid, "relocation_radius", "Within my city"))
    return uid, docs


def test_graph_qstore_matches_questionnaire_values():
    import person_graph_store as store

    uid, docs = _fixture()
    db = FakeDb(docs)
    # migrate into the graph, then build the graph-backed qstore
    mig.migrate_user(db, uid, write=True, replace=True)
    graph = store.effective(db, uid)
    gq = src.structured_qstore(graph)
    for nid in ("attachment_style", "social_energy", "smoking_vaping", "pets_owned"):
        assert nid in gq and gq[nid]["value"] == graph[nid].answer


def test_typed_value_parity_every_node():
    uid, docs = _fixture()
    db = FakeDb(docs)

    # old read
    old_profile = db.collection("users").document(uid).collection("profile").document("main").get().to_dict()
    old_qstore = {}
    for s in db.collection("users").document(uid).collection("questionnaire").stream():
        old_qstore[s.id] = s.to_dict()

    # graph read (after migration)
    mig.migrate_user(db, uid, write=True, replace=True)
    g_profile, g_qstore = src.load_user(db, uid)

    for node in qt.nodes():
        old_v = md._typed_value(node, old_profile, old_qstore)
        new_v = md._typed_value(node, g_profile, g_qstore)
        assert old_v == new_v, f"parity break on {node['id']}: {old_v!r} != {new_v!r}"


def test_qz_mirror_stripped_graph_is_authoritative():
    # a stale profile mirror qz_social_energy=2 must not override the graph's 7
    uid, docs = _fixture(social_energy_mirror=2)
    db = FakeDb(docs)
    mig.migrate_user(db, uid, write=True, replace=True)
    g_profile, g_qstore = src.load_user(db, uid)
    assert "qz_social_energy" not in g_profile
    node = qt.node("social_energy")
    assert md._typed_value(node, g_profile, g_qstore) == 7


def test_load_user_keeps_gate_profile_fields():
    uid, docs = _fixture()
    db = FakeDb(docs)
    mig.migrate_user(db, uid, write=True, replace=True)
    g_profile, _ = src.load_user(db, uid)
    # the scorer's gate/identity fields survive the strip
    for k in ("gender", "interested_in", "location", "relationship_intent", "completeness"):
        assert k in g_profile


def test_persona_excludes_ayma_only_by_default_report_input():
    # The match report's narrative input (person_graph_source.persona default)
    # is public + private, NEVER Ayma-only — the graph counterpart of the wiki
    # dump that excludes Ayma's assessment page.
    import person_graph_store as store

    uid, docs = _fixture()
    db = FakeDb(docs)
    mig.migrate_user(db, uid, write=True, replace=True)
    parent = "attachment_style"  # a real answered seed node to hang nodes off
    visible = store.add_node(db, uid, parent, "note", answer="VISIBLE_PRIVATE_FACT")
    secret = store.add_node(db, uid, parent, "note", answer="ZZZ_AYMA_SECRET")
    store.set_visibility(db, uid, secret, "ayma_only")

    default = src.persona(db, uid)
    assert "VISIBLE_PRIVATE_FACT" in default
    assert "ZZZ_AYMA_SECRET" not in default  # ayma_only kept out of the report

    with_ayma = src.persona(db, uid, include_ayma_only=True)
    assert "ZZZ_AYMA_SECRET" in with_ayma  # folded in only for Ayma's own grounding

    public = src.persona(db, uid, public_only=True)
    assert "VISIBLE_PRIVATE_FACT" not in public  # a private note is not public


def test_persona_pages_shape_and_visibility():
    # sims read persona_pages -> [{title, body}] for PersonaContext.pages.
    import person_graph_store as store

    uid, docs = _fixture()
    db = FakeDb(docs)
    mig.migrate_user(db, uid, write=True, replace=True)
    parent = "attachment_style"
    priv = store.add_node(db, uid, parent, "note", answer="SELF_PRIVATE")
    secret = store.add_node(db, uid, parent, "note", answer="SELF_AYMA_SECRET")
    store.set_visibility(db, uid, secret, "ayma_only")

    # MATCH persona: public nodes only — no private, no ayma_only
    match_pages = src.persona_pages(db, uid, public_only=True)
    assert all(isinstance(p["title"], str) and isinstance(p["body"], str) for p in match_pages)
    blob = "\n".join(p["body"] for p in match_pages)
    assert "SELF_PRIVATE" not in blob and "SELF_AYMA_SECRET" not in blob

    # SELF persona: everything about the owner, ayma_only folded in
    self_pages = src.persona_pages(db, uid, include_ayma_only=True)
    self_blob = "\n".join(p["body"] for p in self_pages)
    assert "SELF_PRIVATE" in self_blob and "SELF_AYMA_SECRET" in self_blob
