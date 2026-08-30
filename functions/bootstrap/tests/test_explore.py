import asyncio

import gemini
import explore as ex


def test_parse_nl_query(monkeypatch):
    async def _fake(text, system_prompt, response_schema=None):
        assert "blonde" in text
        return {"hair_color": "blonde", "age_min": 30, "age_max": 39}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = asyncio.run(ex.parse_nl_query("blondes in their 30s"))
    assert out["hair_color"] == "blonde"
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
         "photo_attrs": {"hair_color": "brown", "glasses": "yes"}}
    assert ex._passes_filters(p, {"hair_color": "brown"})
    assert not ex._passes_filters(p, {"hair_color": "blonde"})
    assert ex._passes_filters(p, {"location": "lisbon"})
    assert not ex._passes_filters(p, {"age_min": 40})
    assert ex._passes_filters(p, {"glasses": "yes"})


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
    db.docs[("users", uid)] = {"x": 1}
    db.docs[("users", uid, "profile", "main")] = profile


def test_explore_filters_and_eligibility():
    db = FakeDb()
    _u(db, "me", community="c", gender="Woman", interested_in=["Men"],
       location="X", birthdate="1994-01-01")
    _u(db, "match", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01",
       photo_attrs={"hair_color": "brown"})
    _u(db, "wrong-community", community="z", gender="Man",
       interested_in=["Women"], location="X", birthdate="1993-01-01")
    _u(db, "wrong-orientation", community="c", gender="Man",
       interested_in=["Men"], location="X", birthdate="1993-01-01")
    _u(db, "blonde", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01",
       photo_attrs={"hair_color": "blonde"})
    db.docs[("blocks", "me_blockme")] = {}
    _u(db, "blockme", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01")
    db.docs[("users", "me", "explore_passed", "passed")] = {"passed_at": 1}
    _u(db, "passed", community="c", gender="Man", interested_in=["Women"],
       location="X", birthdate="1993-01-01")

    ids = [c["uid"] for c in ex.explore(db, "me", {})]
    assert set(ids) == {"match", "blonde"}

    ids2 = [c["uid"] for c in ex.explore(db, "me", {"hair_color": "brown"})]
    assert ids2 == ["match"]
