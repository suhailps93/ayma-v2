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


# --- privacy gate: a private physical attribute can't be used to search for
# or filter out its owner (§ founder 2026-09-21: repurposing the per-field
# public/private flag that used to gate the since-removed story_public
# Attributes section — "Use it for the heuristic search tho"). A private
# field is treated exactly like a missing/unknown one: never excludes,
# regardless of whether it would have matched or mismatched the filter.


def test_passes_filters_public_fields_none_means_unrestricted():
    """The default (`public_fields` omitted) keeps every existing direct
    caller of `_passes_filters` working unchanged — only `explore()` itself
    passes a real set (see the integration test below)."""
    p = {"physical_attrs": {"eye_color": "blue"}}
    assert ex._passes_filters(p, {"eye_color": "blue"})
    assert not ex._passes_filters(p, {"eye_color": "green"})


def test_passes_filters_private_field_treated_exactly_like_an_unset_one():
    """A private field is dropped from the mirror before any filter reads
    it — i.e. treated EXACTLY as if the value had never been set, no
    special-casing beyond that. What that means for the search outcome
    then follows whatever this function already does for a genuinely
    unset/unknown value on that same field (which differs by field: see
    the two halves of this test) — never something new invented for
    privacy specifically."""
    p = {
        "physical_attrs": {
            "eye_color": "blue",
            "hair_color": "brown",
            "build": "athletic",
            "race_ethnicity": "Latino/Hispanic",
            "height_estimate_cm": 182,
        },
    }
    # `build`/`race_ethnicity`/height-range: an unset value never excludes
    # here (see test_passes_filters_physical_attributes) — so neither does
    # a real value that's merely private, in EITHER direction.
    assert ex._passes_filters(p, {"build": "slim"}, public_fields=set())  # real mismatch, ignored
    assert ex._passes_filters(p, {"build": "athletic"}, public_fields=set())  # real match, not relied on
    assert ex._passes_filters(p, {"race_ethnicity": "east asian"}, public_fields=set())
    assert ex._passes_filters(p, {"height_min_cm": 190}, public_fields=set())
    # made public -> a real mismatch excludes again, normally.
    assert not ex._passes_filters(p, {"build": "slim"}, public_fields={"build"})
    assert ex._passes_filters(p, {"build": "athletic"}, public_fields={"build"})

    # `eye_color` (and hair_color/facial_hair/glasses/…, the photo_attrs-
    # fallback group): an UNSET value already excludes here today, same as
    # a real mismatch — no "unknown never excludes" guard exists for this
    # group (see the module's own `_PHOTO_FIELDS` loop). A private value
    # gets that identical treatment: still excluded from a search on it,
    # exactly as an actually-unknown eye colour already would be — not a
    # free pass, because an unset one isn't one either.
    assert not ex._passes_filters(p, {"eye_color": "blue"}, public_fields=set())
    assert not ex._passes_filters(p, {"eye_color": "green"}, public_fields=set())
    # made public -> matches/mismatches for real again.
    assert ex._passes_filters(p, {"eye_color": "blue"}, public_fields={"eye_color"})
    assert not ex._passes_filters(p, {"eye_color": "green"}, public_fields={"eye_color"})

    # a field made public doesn't leak a DIFFERENT still-private field —
    # hair_color stays excluded-as-private even once eye_color is public.
    assert not ex._passes_filters(
        p, {"eye_color": "blue", "hair_color": "brown"}, public_fields={"eye_color"}
    )


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


class _Query:
    def __init__(self, store, key, limit_n=None, start_after_id=None):
        self.store, self.key = store, key
        self._limit = limit_n
        self._start_after_id = start_after_id

    def limit(self, n):
        return _Query(self.store, self.key, n, self._start_after_id)

    def start_after(self, snap):
        return _Query(self.store, self.key, self._limit, snap.id)

    def stream(self):
        d = len(self.key)
        rows = sorted(
            (k[-1], v)
            for k, v in list(self.store.docs.items())
            if len(k) == d + 1 and k[:d] == self.key and v is not None
        )
        if self._start_after_id is not None:
            rows = [(i, v) for i, v in rows if i > self._start_after_id]
        if self._limit is not None:
            rows = rows[: self._limit]
        for i, v in rows:
            yield _Snap(i, v)


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

    def order_by(self, field):
        assert field == "__name__", field
        return _Query(self.store, self.key)

    def limit(self, n):
        return _Query(self.store, self.key, limit_n=n)


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))

    def get_all(self, refs):
        return [r.get() for r in refs]


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


def test_explore_search_excludes_private_physical_attributes_end_to_end():
    """Full round trip against `physical_attributes.public_fields` (not
    mocked) via `explore()` itself: a candidate whose real `hair_color` is
    still private can't be FOUND by a search on it — same as if their
    hair_color were simply unknown to Ayma — even though it's a genuine
    match; making the field public surfaces them for real. § founder
    2026-09-21: "Use it for the heuristic search tho"."""
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "private-blonde", location="X", birthdate="1993-01-01",
       physical_attrs={"hair_color": "blonde"})
    _u(db, "public-blonde", location="X", birthdate="1993-01-01",
       physical_attrs={"hair_color": "blonde"})
    db.docs[("users", "public-blonde", "physical_attributes", "visibility")] = {
        "public": {"hair_color": True}
    }
    _u(db, "public-brunette", location="X", birthdate="1993-01-01",
       physical_attrs={"hair_color": "brown"})
    db.docs[("users", "public-brunette", "physical_attributes", "visibility")] = {
        "public": {"hair_color": True}
    }

    # Searching for blonde: the private blonde is treated the same as an
    # unknown hair colour would be here (excluded — no "unknown never
    # excludes" guard for this field, see _PHOTO_FIELDS) even though their
    # real value is a genuine match; only the candidate who made hair_color
    # public and actually matches shows up.
    ids = {c["uid"] for c in ex.explore(db, "me", {"hair_color": "blonde"})}
    assert "private-blonde" not in ids  # a real match, but still private
    assert "public-blonde" in ids  # public and a real match
    assert "public-brunette" not in ids  # public and a real mismatch

    # No physical-attribute filter active at all -> nobody is even looked
    # up for visibility, and everybody shows up regardless.
    ids_unfiltered = {c["uid"] for c in ex.explore(db, "me", {})}
    assert ids_unfiltered == {"me", "private-blonde", "public-blonde", "public-brunette"}


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

    class _DupQuery:
        def __init__(self, real):
            self._real = real

        def limit(self, n):
            return _DupQuery(self._real.limit(n))

        def start_after(self, snap):
            return _DupQuery(self._real.start_after(snap))

        def stream(self):
            snaps = list(self._real.stream())
            return iter(snaps + snaps)  # simulate a duplicated doc id

    class _DupUsersColl:
        def __init__(self, real):
            self._real = real

        def document(self, doc_id):
            return self._real.document(doc_id)

        def stream(self):
            snaps = list(self._real.stream())
            return iter(snaps + snaps)  # simulate a duplicated doc id

        def order_by(self, field):
            return _DupQuery(self._real.order_by(field))

        def limit(self, n):
            return _DupQuery(self._real.limit(n))

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


def test_explore_excludes_practice_personas(monkeypatch):
    # Practice-date simulator personas (demo_practice_*) are never real
    # accounts and must never surface in the live feed (BUG E).
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "real", location="X", birthdate="1993-01-01", name="Dana")
    _u(db, "demo_practice_maya", location="X", birthdate="1993-01-01",
       name="Maya")

    ids = {c["uid"] for c in ex.explore(db, "me", {})}
    assert "demo_practice_maya" not in ids
    assert ids == {"me", "real"}


# --- explore card: server-minted thumb variant URL with fallback ------------
# The grid gets a smaller thumb variant when it exists (staging); otherwise it
# falls back to the original photo_url. explore imports _photo_url/_variant_url
# from public_profile at call time, so patching that module is enough.
import public_profile as pp  # noqa: E402


def test_explore_card_uses_thumb_variant_when_present(monkeypatch):
    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}")
    monkeypatch.setattr(pp, "_variant_url", lambda sp, spec, w: f"https://cdn/{sp}__{spec}_{w}")
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "hasphoto", location="X", birthdate="1993-01-01",
       photos=[{"media_id": "pm", "order": 0}])
    db.docs[("users", "hasphoto", "user_media", "pm")] = {
        "storage_path": "uploads/hasphoto/p.jpg"
    }
    cards = {c["uid"]: c for c in ex.explore(db, "me", {})}
    card = cards["hasphoto"]
    assert card["photo_url"] == "https://cdn/uploads/hasphoto/p.jpg"
    assert card["photo_url_thumb"] == "https://cdn/uploads/hasphoto/p.jpg__thumb_400"


def test_explore_card_thumb_falls_back_to_original_when_variant_absent(monkeypatch):
    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}")
    monkeypatch.setattr(pp, "_variant_url", lambda sp, spec, w: None)
    db = FakeDb()
    _u(db, "me", location="X", birthdate="1994-01-01")
    _u(db, "hasphoto", location="X", birthdate="1993-01-01",
       photos=[{"media_id": "pm", "order": 0}])
    db.docs[("users", "hasphoto", "user_media", "pm")] = {
        "storage_path": "uploads/hasphoto/p.jpg"
    }
    cards = {c["uid"]: c for c in ex.explore(db, "me", {})}
    card = cards["hasphoto"]
    assert card["photo_url_thumb"] == card["photo_url"]  # == original


# --- explore_page() cursor pagination ----------------------------------------

def _seed_roster(db, n, prefix="u"):
    _u(db, "me", location="X", birthdate="1994-01-01")
    for i in range(n):
        _u(db, f"{prefix}{i:02d}", location="X", birthdate="1993-01-01")


def test_cursor_round_trip_and_malformed_restarts_page_one():
    token = ex._encode_cursor("u07")
    assert ex._decode_cursor(token) == "u07"
    assert ex._decode_cursor(None) is None
    assert ex._decode_cursor("") is None
    assert ex._decode_cursor("not-a-cursor!!!") is None
    assert ex._decode_cursor("e30=") is None  # valid base64, no last_uid


def test_explore_page_walks_disjoint_pages_to_exhaustion():
    db = FakeDb()
    _seed_roster(db, 5)
    seen: set[str] = set()
    cursor = None
    pages = 0
    while True:
        cards, cursor = ex.explore_page(db, "me", {}, limit=2, cursor=cursor)
        pages += 1
        ids = [c["uid"] for c in cards]
        assert not (set(ids) & seen), f"page {pages} repeats {set(ids) & seen}"
        seen.update(ids)
        if cursor is None:
            break
        assert pages < 10, "pagination did not terminate"
    # me + 5 users, all reachable across pages, page 1 self-pinned.
    assert seen == {"me", "u00", "u01", "u02", "u03", "u04"}
    first, _ = ex.explore_page(db, "me", {}, limit=2)
    assert first[0]["uid"] == "me"


def test_explore_page_pins_self_first_even_when_uid_sorts_late():
    db = FakeDb()
    _u(db, "zzz-me", location="X", birthdate="1994-01-01")
    _u(db, "aaa", location="X", birthdate="1993-01-01")
    _u(db, "mmm", location="X", birthdate="1993-01-01")
    cards, cursor = ex.explore_page(db, "zzz-me", {}, limit=2)
    assert cards[0]["uid"] == "zzz-me"
    assert cursor is not None
    # ... and self never repeats on later pages.
    rest, _ = ex.explore_page(db, "zzz-me", {}, limit=2, cursor=cursor)
    assert "zzz-me" not in {c["uid"] for c in rest}


def test_explore_page_prefers_batched_get_all():
    db = FakeDb()
    _seed_roster(db, 3)
    calls = []
    real_get_all = FakeDb.get_all

    def _counting(self, refs):
        calls.append(len(refs))
        return real_get_all(self, refs)

    FakeDb.get_all = _counting
    try:
        cards, _ = ex.explore_page(db, "me", {}, limit=10)
    finally:
        FakeDb.get_all = real_get_all
    assert len(cards) == 4
    assert calls, "expected at least one batched get_all"
    # One candidate batch (profile + blocks + likes + match + cand refs),
    # not one round trip per candidate per doc.
    assert len(calls) <= 2, f"too many batch rounds: {calls}"


def test_explore_page_empty_roster_and_unknown_caller():
    db = FakeDb()
    cards, cursor = ex.explore_page(db, "ghost", {}, limit=10)
    assert cards == [] and cursor is None


def test_explore_legacy_limit_truncates_after_global_sort():
    db = FakeDb()
    _seed_roster(db, 6)
    cards = ex.explore(db, "me", {}, limit=3)
    assert [c["uid"] for c in cards][0] == "me"
    assert len(cards) == 3
    assert ex.explore(db, "me", {}, limit=0) == []
