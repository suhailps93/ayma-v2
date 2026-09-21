import asyncio

import gemini
import explore as ex


def test_parse_nl_query(monkeypatch):
    seen = {}

    async def _fake(text, system_prompt, response_schema=None, **kw):
        assert "blonde" in text
        seen.update(kw)
        return {"hair_color": "blonde", "age_min": 30, "age_max": 39}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = asyncio.run(ex.parse_nl_query("blondes in their 30s", uid="u9"))
    assert out["hair_color"] == "blonde"
    # billed to the caller under the `explore` feature
    assert seen == {"uid": "u9", "feature": "explore"}
    assert asyncio.run(ex.parse_nl_query("   ")) == {}


def test_parse_nl_query_swallows_errors(monkeypatch):
    async def _boom(*a, **k):
        raise RuntimeError("x")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    assert asyncio.run(ex.parse_nl_query("anything")) == {}


def test_merge_filters_dropdown_wins():
    merged = ex.merge_filters(
        {"hair_color": "brown", "location": ""},
        {"hair_color": "blonde", "age_min": 25},
    )
    assert merged == {"hair_color": "brown", "age_min": 25}


def test_passes_filters():
    p = {"birthdate": "1994-01-01", "location": "Lisbon, Portugal",
         "gender": "Man",
         "photo_attrs": {"hair_color": "brown", "glasses": "yes"}}
    assert ex._passes_filters(p, {"hair_color": "brown"})
    assert not ex._passes_filters(p, {"hair_color": "blonde"})
    assert ex._passes_filters(p, {"location": "lisbon"})
    assert not ex._passes_filters(p, {"age_min": 40})
    assert ex._passes_filters(p, {"glasses": "yes"})
    # gender (case-insensitive, plural/synonym aware)
    assert ex._passes_filters(p, {"gender": "man"})
    assert ex._passes_filters(p, {"gender": "Men"})
    assert not ex._passes_filters(p, {"gender": "woman"})
    assert not ex._passes_filters({**p, "gender": "Woman"}, {"gender": "man"})


def test_passes_filters_physical_attributes():
    p = {
        "birthdate": "1994-01-01",
        "physical_attrs": {
            "eye_color": "blue",
            "skin_tone": "olive",
            "build": "athletic",
            "hair_type": "unknown",
            "height_estimate_cm": 182,
            "race_ethnicity": "Latino/Hispanic",
        },
    }
    # eye_color falls through to the physical-attrs mirror when photo_attrs
    # has nothing.
    assert ex._passes_filters(p, {"eye_color": "blue"})
    assert not ex._passes_filters(p, {"eye_color": "green"})
    # physical-only enum fields match case-insensitively.
    assert ex._passes_filters(p, {"skin_tone": "Olive"})
    assert not ex._passes_filters(p, {"build": "slim"})
    # "unknown" (and missing) on a physical-only field never excludes.
    assert ex._passes_filters(p, {"hair_type": "curly"})
    assert ex._passes_filters(p, {"hair_length": "long"})
    assert ex._passes_filters({"birthdate": "1994-01-01"}, {"build": "athletic"})
    # rough height range.
    assert ex._passes_filters(p, {"height_min_cm": 178})
    assert not ex._passes_filters(p, {"height_max_cm": 175})
    # a missing weight estimate does not exclude a weight filter.
    assert ex._passes_filters(p, {"weight_min_kg": 60, "weight_max_kg": 90})
    # race_ethnicity: coarse substring match.
    assert ex._passes_filters(p, {"race_ethnicity": "latino"})
    assert not ex._passes_filters(p, {"race_ethnicity": "east asian"})


# --- explore() over a fake db ------------------------------------------------

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
        self.store, self.key = store, key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _u(db, uid, **profile):
    # Every real profile has a name — the feed gates out nameless ones. Tests
    # that care about the no-name gate pass name="" explicitly.
    profile.setdefault("name", uid)
    db.docs[("users", uid)] = {"x": 1}
    db.docs[("users", uid, "profile", "main")] = profile


def test_explore_lists_everyone_including_self_no_gates():
    db = FakeDb()
    _u(db, "me", community="c", gender="Woman", interested_in=["Men"],
       location="X", birthdate="1994-01-01")
    _u(db, "match", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01",
       photo_attrs={"hair_color": "brown"})
    # Neither of these is gated out any more.
    _u(db, "other-community", community="z", gender="Man",
       interested_in=["Women"], location="X", birthdate="1993-01-01")
    _u(db, "other-orientation", community="c", gender="Man",
       interested_in=["Men"], location="X", birthdate="1993-01-01")
    _u(db, "blonde", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01",
       photo_attrs={"hair_color": "blonde"})
    # Still excluded: blocked, passed, paused.
    db.docs[("blocks", "me_blockme")] = {}
    _u(db, "blockme", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01")
    db.docs[("users", "me", "explore_passed", "passed")] = {"passed_at": 1}
    _u(db, "passed", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01")
    _u(db, "paused-user", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01", paused=True)

    cards = ex.explore(db, "me", {})
    ids = {c["uid"] for c in cards}
    assert ids == {"me", "match", "other-community", "other-orientation",
                   "blonde"}
    assert "blockme" not in ids and "passed" not in ids
    assert "paused-user" not in ids

    me_card = next(c for c in cards if c["uid"] == "me")
    assert me_card["self"] is True and me_card["score"] is None
    assert cards[0]["uid"] == "me"  # your own card pins to the top

    # Search filters still narrow the roster (self has no photo_attrs).
    ids2 = [c["uid"] for c in ex.explore(db, "me", {"hair_color": "brown"})]
    assert ids2 == ["match"]


def test_paused_self_still_sees_own_card():
    # "Pause matching" hides you from other people, not from yourself.
    db = FakeDb()
    _u(db, "me", community="c", gender="Woman", interested_in=["Men"],
       location="X", birthdate="1994-01-01", paused=True)
    _u(db, "match", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01")

    cards = ex.explore(db, "me", {})
    me_card = next((c for c in cards if c["uid"] == "me"), None)
    assert me_card is not None
    assert me_card["self"] is True and me_card["paused"] is True


def test_primary_photo_path_resolves_media_id_via_user_media():
    db = FakeDb()
    db.docs[("users", "u", "user_media", "m1")] = {
        "storage_path": "uploads/u/a.jpg"
    }
    db.docs[("users", "u", "user_media", "m2")] = {
        "storage_path": "uploads/u/b.jpg"
    }
    photos = [{"media_id": "m2", "order": 1}, {"media_id": "m1", "order": 0}]
    assert ex._primary_photo_path(db, "u", photos) == "uploads/u/a.jpg"


def test_primary_photo_path_handles_legacy_inline_and_missing():
    db = FakeDb()
    # legacy shape: storage_path inlined on the entry
    assert (
        ex._primary_photo_path(db, "u", [{"storage_path": "uploads/u/x.jpg"}])
        == "uploads/u/x.jpg"
    )
    # no photos / malformed entries / dangling media_id -> None, never raises
    assert ex._primary_photo_path(db, "u", []) is None
    assert ex._primary_photo_path(db, "u", None) is None
    assert ex._primary_photo_path(db, "u", ["nope", 3]) is None
    assert ex._primary_photo_path(db, "u", [{"media_id": "ghost"}]) is None


def test_explore_populates_photo_path_and_survives_a_bad_photo_entry():
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "hasphoto", location="X", birthdate="1993-01-01",
       photos=[{"media_id": "pm", "order": 0}])
    db.docs[("users", "hasphoto", "user_media", "pm")] = {
        "storage_path": "uploads/hasphoto/p.jpg"
    }
    # a profile whose photos array is junk must not 500 the feed
    _u(db, "badphoto", location="X", birthdate="1993-01-01",
       photos="not-a-list")

    cards = {c["uid"]: c for c in ex.explore(db, "me", {})}
    assert cards["hasphoto"]["photo_path"] == "uploads/hasphoto/p.jpg"
    assert cards["badphoto"]["photo_path"] is None
    assert cards["me"]["photo_path"] is None


def test_score_for_prefers_the_real_match_over_a_stale_candidate():
    """A ``matches`` doc (Pass 2 — the real, recalculable score) must always
    win over a ``match_candidates`` entry (Pass 1's heuristic-only ordering
    hint) for the same pair — this is what lets a "Recalculate" show up in
    Explore without anything else touching the stale candidate doc."""
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "them", location="X", birthdate="1993-01-01")
    db.docs[("users", "me", "match_candidates", "them")] = {
        "heuristic_score": 0.43}
    from pair_key import sorted_pair_key
    db.docs[("matches", sorted_pair_key("me", "them"))] = {
        "score": 0.0}  # just recalculated

    cards = {c["uid"]: c for c in ex.explore(db, "me", {})}
    assert cards["them"]["score"] == 0.0


def test_explore_never_shows_two_cards_for_the_same_person():
    """Defends the ``seen`` guard in ``explore()``: even if the underlying
    users stream ever repeated a document id (it shouldn't — Firestore
    stream() doesn't duplicate — but this is exactly the shape of the
    reported bug: the same real person shown as two cards with two
    different percentages), Explore must still emit exactly one card per
    person."""

    class _DupUsersColl:
        def __init__(self, real):
            self._real = real

        def document(self, doc_id):
            return self._real.document(doc_id)

        def stream(self):
            snaps = list(self._real.stream())
            return iter(snaps + snaps)  # simulate a duplicated doc id

    class _DupDb:
        def __init__(self, real):
            self._real = real

        def collection(self, name):
            real_coll = self._real.collection(name)
            return _DupUsersColl(real_coll) if name == "users" else real_coll

    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "them", location="X", birthdate="1993-01-01")

    cards = ex.explore(_DupDb(db), "me", {})
    ids = [c["uid"] for c in cards]
    assert ids.count("them") == 1
    assert ids.count("me") == 1


def test_explore_drops_profiles_with_no_name():
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "real", location="X", birthdate="1993-01-01", name="Dana")
    _u(db, "nameless", location="X", birthdate="1993-01-01", name="")
    _u(db, "whitespace", location="X", birthdate="1993-01-01", name="   ")

    ids = {c["uid"] for c in ex.explore(db, "me", {})}
    assert ids == {"me", "real"}  # self is exempt; nameless are gated out
