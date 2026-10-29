"""Taste backfill: mines Story + conversation history for music/film/food and
fills empty Taste-page domains, is a cheap no-op when already full, and only
ever appends the user's own stated names (via merge_taste_mentions)."""

import asyncio

import gemini
import pytest
import taste_backfill
import wiki_query
from skills import questionnaire


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- a tiny path-keyed Firestore fake (mirrors test_questionnaire_skill) ----


class _Snap:
    def __init__(self, key, data):
        self.id = key[-1]
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))

    def get(self):
        return _Snap(self.key, self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = self.store.docs.get(self.key)
        if merge and isinstance(cur, dict):
            self.store.docs[self.key] = {**cur, **data}
        else:
            self.store.docs[self.key] = dict(data)


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        seen = set()
        for k in list(self.store.docs.keys()):
            if len(k) > d and k[:d] == self.key and k[d] not in seen:
                seen.add(k[d])
                child = self.key + (k[d],)
                yield _Snap(child, self.store.docs.get(child))


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _q(nid):
    return ("users", "u1", "questionnaire", nid)


_TASTE_PAGE = ("users", "u1", "wiki_pages", "taste")


@pytest.fixture(autouse=True)
def _inert_schedule(monkeypatch):
    # The merge fires a fire-and-forget completeness recompute; keep it inert.
    import completeness

    monkeypatch.setattr(completeness, "schedule", lambda db, uid: False)


def _stub_sources(monkeypatch, *, story="", turns=None):
    monkeypatch.setattr(wiki_query, "read_wiki_context", lambda *a, **k: story)
    monkeypatch.setattr(
        taste_backfill.chat_history, "_collect", lambda db, uid: list(turns or [])
    )


def _stub_extract(monkeypatch, payload):
    calls = {"n": 0}

    async def _fake(*a, **k):
        calls["n"] += 1
        return payload

    monkeypatch.setattr(gemini, "generate_json", _fake)
    return calls


# --- tests ------------------------------------------------------------------


def test_is_thin_true_when_a_domain_empty():
    db = FakeDb({_q("taste_music"): {"value": "Khruangbin, Bon Iver"}})
    assert taste_backfill.is_thin(db, "u1") is True  # film + food empty


def test_is_thin_false_when_all_three_present():
    db = FakeDb(
        {
            _q("taste_music"): {"value": "Khruangbin"},
            _q("taste_film"): {"value": "Arrival"},
            _q("taste_food"): {"value": "ramen"},
        }
    )
    assert taste_backfill.is_thin(db, "u1") is False


def test_backfill_fills_empty_film_and_food_from_story_and_transcript(monkeypatch):
    # Music already answered; Film/Food empty. Story mentions films, transcript
    # mentions food — the extractor returns all three, backfill fills the gaps.
    db = FakeDb({_q("taste_music"): {"value": "Khruangbin, Bon Iver"}})
    _stub_sources(
        monkeypatch,
        story="### interests — movies\nShe loves Arrival and Amélie.",
        turns=[
            {"ts": 1, "role": "user", "text": "honestly I could eat ramen every day"},
            {"ts": 2, "role": "ayma", "text": "ramen is elite"},
            {"ts": 3, "role": "user", "text": "and we always get Thai on fridays"},
        ],
    )
    calls = _stub_extract(
        monkeypatch,
        {
            "music": ["Khruangbin"],  # already present -> no change for music
            "film": ["Arrival", "Amélie"],
            "food": ["ramen", "Thai food"],
        },
    )

    changed = _run(taste_backfill.backfill(db, "u1"))

    assert calls["n"] == 1  # the LLM ran once (taste was thin)
    assert set(changed) == {"film", "food"}
    assert db.docs[_q("taste_film")]["value"] == "Arrival, Amélie"
    assert db.docs[_q("taste_food")]["value"] == "ramen, Thai food"
    # the public Taste page the Qloo engine reads now carries all three domains
    body = db.docs[_TASTE_PAGE]["ai_body"]
    assert "Music: Khruangbin, Bon Iver" in body
    assert "Film: Arrival, Amélie" in body
    assert "Food: ramen, Thai food" in body
    assert db.docs[_TASTE_PAGE]["visibility"] == "public"


def test_backfill_is_cheap_noop_when_all_domains_full(monkeypatch):
    db = FakeDb(
        {
            _q("taste_music"): {"value": "Khruangbin"},
            _q("taste_film"): {"value": "Arrival"},
            _q("taste_food"): {"value": "ramen"},
        }
    )
    _stub_sources(monkeypatch, story="whatever", turns=[{"ts": 1, "role": "user", "text": "hi"}])
    calls = _stub_extract(monkeypatch, {"film": ["Dune"]})

    changed = _run(taste_backfill.backfill(db, "u1"))

    assert changed == []
    assert calls["n"] == 0  # no LLM call — pure Firestore thin-check short-circuit
    assert db.docs[_q("taste_film")]["value"] == "Arrival"  # untouched


def test_backfill_force_runs_even_when_full(monkeypatch):
    db = FakeDb(
        {
            _q("taste_music"): {"value": "Khruangbin"},
            _q("taste_film"): {"value": "Arrival"},
            _q("taste_food"): {"value": "ramen"},
        }
    )
    _stub_sources(monkeypatch, story="loves Dune", turns=[])
    calls = _stub_extract(monkeypatch, {"film": ["Dune"]})

    changed = _run(taste_backfill.backfill(db, "u1", force=True))

    assert calls["n"] == 1
    assert changed == ["film"]
    assert db.docs[_q("taste_film")]["value"] == "Arrival, Dune"


def test_backfill_noop_when_no_source_text(monkeypatch):
    db = FakeDb({_q("taste_music"): {"value": "Khruangbin"}})
    _stub_sources(monkeypatch, story="", turns=[])
    calls = _stub_extract(monkeypatch, {"film": ["Dune"]})

    changed = _run(taste_backfill.backfill(db, "u1"))

    assert changed == []
    assert calls["n"] == 0  # nothing to mine -> never hits the LLM


def test_backfill_never_raises_on_extract_failure(monkeypatch):
    db = FakeDb({_q("taste_music"): {"value": "Khruangbin"}})
    _stub_sources(monkeypatch, story="loves Dune", turns=[])

    async def _boom(*a, **k):
        raise RuntimeError("gemini down")

    monkeypatch.setattr(gemini, "generate_json", _boom)

    assert _run(taste_backfill.backfill(db, "u1")) == []  # best-effort


def test_schedule_noop_when_taste_full(monkeypatch):
    db = FakeDb(
        {
            _q("taste_music"): {"value": "Khruangbin"},
            _q("taste_film"): {"value": "Arrival"},
            _q("taste_food"): {"value": "ramen"},
        }
    )
    # No running loop in this sync test, but the thin-check short-circuits first.
    assert taste_backfill.schedule(db, "u1") is False
