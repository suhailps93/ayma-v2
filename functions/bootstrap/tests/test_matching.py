import matching


def test_orientation_match():
    m = matching.orientation_match
    assert m("Woman", ["Men"], "Man", ["Women"]) is True
    assert m("Woman", ["Women"], "Man", ["Women"]) is False  # she wants women
    assert m("Non-binary", ["Everyone"], "Man", ["Everyone"]) is True
    assert m("Man", ["Everyone"], "Woman", ["Men"]) is True
    assert m("Man", [], "Woman", ["Men"]) is False


def test_heuristic_score_rewards_similarity():
    a = {"birthdate": "1994-01-01", "location": "Lisbon"}
    b_close = {"birthdate": "1995-01-01", "location": "Lisbon"}
    b_far = {"birthdate": "1968-01-01", "location": "Oslo"}

    s_close, r_close = matching.heuristic_score(
        a, b_close, {"wants_kids": True}, {"wants_kids": True}
    )
    s_far, _ = matching.heuristic_score(a, b_far, {}, {})

    assert s_close > s_far
    assert 0.0 <= s_far <= s_close <= 1.0
    assert any("same location" in x for x in r_close)
    assert any("shared" in x for x in r_close)


# --- source_and_score against an in-memory Firestore fake -------------------

class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(data)
        self.store.docs[self.key] = cur

    def delete(self):
        self.store.docs.pop(self.key, None)

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        depth = len(self.key)
        for key, data in list(self.store.docs.items()):
            if len(key) == depth + 1 and key[:depth] == self.key and data is not None:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _seed_user(db, uid, **profile):
    db.docs[("users", uid)] = {"created_at": 1}
    db.docs[("users", uid, "profile", "main")] = profile


def test_source_and_score_finds_a_compatible_account():
    db = FakeDb()
    _seed_user(
        db, "u1",
        community="lisbon", gender="Woman", interested_in=["Men"],
        location="Lisbon", birthdate="1994-05-01",
    )
    _seed_user(
        db, "u2",
        community="lisbon", gender="Man", interested_in=["Women"],
        location="Lisbon", birthdate="1993-03-03",
    )
    # wrong community
    _seed_user(
        db, "u3",
        community="porto", gender="Man", interested_in=["Women"],
        location="Porto", birthdate="1990-01-01",
    )
    # orientation mismatch
    _seed_user(
        db, "u4",
        community="lisbon", gender="Man", interested_in=["Men"],
        location="Lisbon", birthdate="1992-01-01",
    )
    # paused — excluded from candidate sourcing (§14.2)
    _seed_user(
        db, "u5",
        community="lisbon", gender="Man", interested_in=["Women"],
        location="Lisbon", birthdate="1991-02-02", paused=True,
    )

    out = matching.source_and_score(db, "u1", limit=50)
    ids = [c["candidate_uid"] for c in out]
    assert ids == ["u2"]
    written = db.docs[("users", "u1", "match_candidates", "u2")]
    assert 0 <= written["heuristic_score"] <= 1
    assert "reasons" in written


def test_source_and_score_excludes_practice_personas():
    # Practice-date simulator personas (demo_practice_*) are never real
    # candidates (BUG E).
    db = FakeDb()
    _seed_user(db, "u1", community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "demo_practice_maya", community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1993-01-01")
    _seed_user(db, "real", community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1992-01-01")

    out = matching.source_and_score(db, "u1", limit=50)
    assert [c["candidate_uid"] for c in out] == ["real"]


def test_source_and_score_excludes_blocked_and_matched():
    db = FakeDb()
    _seed_user(db, "u1", community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "blk", community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "mch", community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    db.docs[("blocks", "u1_blk")] = {"blocker": "u1", "blocked": "blk"}
    from pair_key import sorted_pair_key
    db.docs[("matches", sorted_pair_key("u1", "mch"))] = {"status": "scored"}

    out = matching.source_and_score(db, "u1", limit=50)
    assert [c["candidate_uid"] for c in out] == []


def test_source_and_score_clears_stale_candidate_once_a_pair_is_matched():
    """A pair that already has a real ``matches`` doc (Pass 2 has scored it)
    must never keep a leftover Pass-1 ``match_candidates`` entry lying
    around on either side — that stale, lower-fidelity record is exactly
    the kind of data Explore (or any other reader) could mistake for the
    current score."""
    db = FakeDb()
    _seed_user(db, "u1", community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "mch", community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    from pair_key import sorted_pair_key
    db.docs[("matches", sorted_pair_key("u1", "mch"))] = {"status": "scored"}
    # Stale entries from an earlier Pass-1 run, before the pair was scored,
    # on *both* sides.
    db.docs[("users", "u1", "match_candidates", "mch")] = {
        "heuristic_score": 0.43}
    db.docs[("users", "mch", "match_candidates", "u1")] = {
        "heuristic_score": 0.29}

    out = matching.source_and_score(db, "u1", limit=50)
    assert out == []  # already matched -> not re-sourced as a candidate
    assert ("users", "u1", "match_candidates", "mch") not in db.docs
    assert ("users", "mch", "match_candidates", "u1") not in db.docs
