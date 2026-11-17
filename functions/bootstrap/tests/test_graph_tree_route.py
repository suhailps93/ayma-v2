"""Route-TABLE tests for the person-graph tree endpoints (build 2487 defect).

These go through the REAL FastAPI route table (``TestClient(main.app)``), not a
direct call to ``_tree_payload`` / ``node_tree``. That distinction is the whole
point: the direct-call tests all passed while the live endpoint was broken,
because ``GET /profile/graph/tree`` was shadowed by the earlier-registered
``GET /profile/graph/{target_uid}`` catch-all (it bound ``target_uid="tree"``
and returned the flat public graph for a nonexistent user — a 115-byte
centre-only payload that the client rendered as an empty Story / empty graph).
Only a test that resolves the path through the router catches that.
"""

import main
import person_graph_store as store
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

_ME = "founder-uid"


# --- a minimal Firestore double supporting the overlay + profile docs --------
class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _Doc:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def collection(self, name):
        return _Coll(self._st, self._key + (name,))

    def get(self):
        return _Snap(self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _Coll:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _Doc(self._st, self._key + (name,))

    def stream(self):
        return iter(())  # no sub-collection docs seeded (supplemental reads)

    def where(self, *a, **k):
        return self


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _Coll(self, (name,))


def _auth(monkeypatch, uid=_ME):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def _seed_flat_parentless_graph(db):
    """The founder's real shape in miniature: parentless emergent nodes spread
    across several sections (no parent tree), plus one public node."""
    store.add_loose_node(db, _ME, "Grew up in Lisbon", section="identity")
    store.add_loose_node(db, _ME, "Runs ultramarathons", section="lifestyle")
    store.add_loose_node(db, _ME, "Reads stoic philosophy", section="values")
    store.add_loose_node(db, _ME, "Two older sisters", section="relationships")
    # a public fact so the public-profile surface is non-empty too
    store.upsert_fact_node(
        db, _ME, "emergent.career.title", "Founder",
        section="career", visibility="public", provenance="stated",
        label="Work",
    )


def _flat_sentinel(_db, _target):
    """Stand-in for the flat other-user graph — carries the flat-shape markers
    (``center``/``edges``) the tree payload must NOT have."""
    return {"center": {"id": "them", "label": "Them"},
            "sections": [], "nodes": [], "edges": []}


def test_self_tree_route_returns_the_tree_shape_not_the_flat_graph(monkeypatch):
    """GET /profile/graph/tree must reach the tree handler, not the shadowing
    flat catch-all. With the bug it returned the flat shape (center/edges) with
    empty sections — the empty-Story defect."""
    db = FakeDb()
    _seed_flat_parentless_graph(db)
    monkeypatch.setattr(main, "get_db", lambda: db)
    # If routing regressed, /tree would fall through to the flat catch-all; make
    # that path return a distinct flat sentinel so this test fails loudly then.
    import routes.profile as profile_routes
    monkeypatch.setattr(profile_routes.profile_graph, "public_graph", _flat_sentinel)

    r = client.get("/profile/graph/tree?surface=story", headers=_auth(monkeypatch))
    assert r.status_code == 200, r.text
    body = r.json()
    # the TREE shape — a sections list whose sections carry nodes
    assert isinstance(body.get("sections"), list)
    assert body["sections"], "self story tree came back with zero sections (empty-Story bug)"
    assert any(s.get("nodes") for s in body["sections"]), "no section carried any nodes"
    # and NOT the flat shape the shadowing route returns
    assert "edges" not in body and "center" not in body, (
        "tree endpoint returned the flat graph shape — the catch-all is shadowing it"
    )


def test_self_tree_graphdetail_surface_is_non_empty(monkeypatch):
    db = FakeDb()
    _seed_flat_parentless_graph(db)
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.get("/profile/graph/tree?surface=graphDetail", headers=_auth(monkeypatch))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body.get("sections") and any(s.get("nodes") for s in body["sections"])


def test_flat_other_user_route_still_returns_the_flat_graph(monkeypatch):
    """The catch-all GET /profile/graph/{uid} must still resolve for a real uid
    and return the flat graph (not be broken by the reorder)."""
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    import routes.profile as profile_routes
    monkeypatch.setattr(profile_routes.profile_graph, "public_graph", _flat_sentinel)
    r = client.get("/profile/graph/someone-else", headers=_auth(monkeypatch))
    assert r.status_code == 200, r.text
    body = r.json()
    assert "edges" in body and "center" in body  # the flat shape


def test_public_tree_shows_only_public_nodes(monkeypatch):
    """GET /profile/graph/tree/{uid} (publicProfile) exposes public nodes only —
    the private loose nodes never leak to another viewer."""
    db = FakeDb()
    _seed_flat_parentless_graph(db)
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.get(f"/profile/graph/tree/{_ME}", headers=_auth(monkeypatch, uid="viewer"))
    assert r.status_code == 200, r.text
    body = r.json()
    texts = [
        (str(n.get("label", "")) + " " + str(n.get("text", "")))
        for s in body.get("sections", [])
        for n in s.get("nodes", [])
    ]
    blob = " ".join(texts)
    assert "Founder" in blob  # the public node is present
    assert "Lisbon" not in blob and "ultramarathons" not in blob  # private excluded
