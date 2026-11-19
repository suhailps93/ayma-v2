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


def _editor_identity_entry(text):
    """An ``emergent.editor.identity.*`` overlay node in the shape a header
    import leaves behind (public narrative bullet in the identity section whose
    text restates a standard fact) — the real demo-test1 leak shape."""
    return {
        "prompt": text, "answer": text, "answer_type": "narrative",
        "section": "identity", "visibility": "public",
        "state": "answered", "provenance": "stated", "level": 2,
    }


def _seed_note265_public_fixture(db):
    """The EXACT demo-test1 overlay the NOTE 264 unit tests pin, seeded through
    the store so the LIVE self + other-member routes both exercise the public
    header/duplicate suppression (canonical answer-only seed nodes + the three
    ``emergent.editor.identity.*`` duplicates)."""
    store.replace_overlay(db, _ME, {
        "legal_first_name": {"answer": "Daniel Reyes"},
        "date_of_birth": {"answer": "1997-02-10"},
        "gender_identity": {"answer": "Man"},
        "primary_location": {"answer": "Austin, TX, United States"},
        "ethnic_cultural_origin": {"answer": ["Hispanic / Latino"]},
        "target_match_genders": {"answer": ["Women"]},
        "emergent.editor.identity.0": _editor_identity_entry("Age: 29"),
        "emergent.editor.identity.1": _editor_identity_entry("Gender identity: Man"),
        "emergent.editor.identity.4": _editor_identity_entry("Interested in: Women"),
    })


def _section_texts(body, page_type):
    """Every rendered text in a section's node-trees (recursing children), or
    ``None`` when the section is absent from this surface."""
    sec = next(
        (s for s in body.get("sections", []) if s.get("page_type") == page_type),
        None,
    )
    if sec is None:
        return None
    out = []

    def _walk(nodes):
        for n in nodes:
            t = str(n.get("text", ""))
            if t:
                out.append(t)
            _walk(n.get("children") or [])

    _walk(sec.get("nodes") or [])
    return out


def test_self_route_publicprofile_dedups_like_other_member_route(monkeypatch):
    """NOTE 265 (build 2518): the SELF route (uid = caller, ``surface=
    publicProfile``) is the founder's OWN public-profile preview — the path he
    tests. The allowlist used to coerce ``publicProfile`` → ``story``, so this
    route never reached the fixed public walk: About Me still leaked ``Age: 29``
    / ``Austin`` / ``Interested in: Women`` while the other-member route
    ``/profile/graph/tree/{uid}`` was already deduped. With ``publicProfile`` in
    the allowlist the two public views must be identical."""
    db = FakeDb()
    _seed_note265_public_fixture(db)
    monkeypatch.setattr(main, "get_db", lambda: db)

    self_r = client.get(
        "/profile/graph/tree?surface=publicProfile", headers=_auth(monkeypatch)
    )
    other_r = client.get(
        f"/profile/graph/tree/{_ME}", headers=_auth(monkeypatch, uid="viewer")
    )
    assert self_r.status_code == 200, self_r.text
    assert other_r.status_code == 200, other_r.text
    self_body, other_body = self_r.json(), other_r.json()

    ident = _section_texts(self_body, "identity") or []
    looking = _section_texts(self_body, "looking_for")

    # About Me on the SELF route no longer leaks age / location / interested-in.
    assert not any("29" in t for t in ident), ident
    assert not any("Austin" in t for t in ident), ident
    assert not any("Interested in" in t for t in ident), ident
    assert not any("Women" in t for t in ident), ident
    # The Interested-in fact renders exactly once under What I'm Looking For.
    assert looking is not None
    assert len([t for t in looking if "Women" in t]) == 1, looking

    # The self preview matches the other-member public view section-for-section
    # (both render _ME's graph at publicProfile through one `_tree_payload`).
    def _sectmap(body):
        return {
            s["page_type"]: _section_texts(body, s["page_type"])
            for s in body.get("sections", [])
        }

    assert _sectmap(self_body) == _sectmap(other_body)


def test_self_route_publicprofile_not_coerced_to_story(monkeypatch):
    """Guards the allowlist directly: the self ``publicProfile`` surface must
    carry the public visibility set (private loose nodes excluded), NOT the
    story owner set that the old coercion produced."""
    db = FakeDb()
    _seed_flat_parentless_graph(db)  # mixes a public fact with private loose nodes
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.get(
        "/profile/graph/tree?surface=publicProfile", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200, r.text
    blob = " ".join(
        str(n.get("label", "")) + " " + str(n.get("text", ""))
        for s in r.json().get("sections", [])
        for n in s.get("nodes", [])
    )
    assert "Founder" in blob  # the public fact survives
    # the private loose nodes that `story` WOULD show are excluded on publicProfile
    assert "Lisbon" not in blob and "ultramarathons" not in blob


def test_career_section_renders_linkedin_source_link_plus_prose_no_timeline(monkeypatch):
    """Build 2502 end-to-end: the founder's Career today — his LinkedIn URL plus
    PROSE career facts, no dated role/company nodes. The Career section renders
    the ``career.linkedin`` SOURCE link (not the whole section) followed by its
    prose as ``gist_row`` bullets, and NO ``timeline_entry`` is fabricated. The
    timeline populates only once dated nodes exist."""
    import schema

    db = FakeDb()
    # his LinkedIn URL on the profile doc → the injected source-link node
    schema.profile_doc(db, _ME).set(
        {schema.PF_LINKEDIN_URL: "https://www.linkedin.com/in/founder"}, merge=True
    )
    # prose career facts, none dated
    store.upsert_fact_node(
        db, _ME, "emergent.career.0", "I did my BTech in Mahatma Gandhi University.",
        section="career", visibility="public", provenance="stated", label="",
    )
    store.upsert_fact_node(
        db, _ME, "emergent.career.1",
        "Works as an autonomous system integration engineer.",
        section="career", visibility="public", provenance="stated", label="",
    )
    monkeypatch.setattr(main, "get_db", lambda: db)

    r = client.get("/profile/graph/tree?surface=story", headers=_auth(monkeypatch))
    assert r.status_code == 200, r.text
    career = next(
        s for s in r.json()["sections"] if s.get("page_type") == "career"
    )
    nodes = career["nodes"]
    # the LinkedIn SOURCE link sits on top of the section (not the whole section)
    assert nodes[0]["id"] == "career.linkedin"
    assert nodes[0]["answer_type"] == "link"
    assert "linkedin.com/in/founder" in nodes[0].get("link_url", "")
    # the prose facts render as bullets, never a fabricated timeline
    prose = [n for n in nodes if n["id"] != "career.linkedin"]
    assert prose, "the prose career facts still render"
    assert all(n.get("dated", "") == "" for n in prose)
    assert not any(
        (n.get("visual") or {}).get("type") == "timeline_entry" for n in nodes
    )
