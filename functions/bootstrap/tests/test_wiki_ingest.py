import asyncio

import gemini
import wiki_ingest
from transcript import Turn


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return _Snap(self._key[-1], self._store.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = self._store.docs.get(self._key, {}) if merge else {}
        cur.update(payload)
        self._store.docs[self._key] = cur
        self._store.writes.append((self._key, payload, merge))

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))

    def stream(self):
        depth = len(self._key)
        for key, data in self._store.docs.items():
            if len(key) == depth + 1 and key[:depth] == self._key:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.writes = []

    def collection(self, name):
        return _CollRef(self, (name,))


def _seed_page(db, uid, page_id, data):
    db.docs[("users", uid, "wiki_pages", page_id)] = data


def _run(coro):
    return asyncio.run(coro)


def test_ingest_creates_a_page_from_a_hobby_conversation(monkeypatch):
    db = FakeDb()

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        assert "bouldering" in contents  # the conversation reached the model
        return {
            "pages": [
                {
                    "page_id": "bouldering",
                    "page_type": "interests",
                    "visibility": "public",
                    "ai_body": "They boulder indoors twice a week and love it.",
                    "links": ["lifestyle"],
                    "frontmatter": {"sport": "bouldering"},
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    written = _run(
        wiki_ingest.ingest(
            db,
            "u1",
            "sess-1",
            [
                Turn("user", "my main hobby is bouldering, twice a week"),
                Turn("ayma", "indoor or real rock?"),
                Turn("user", "indoor mostly"),
            ],
        )
    )

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "bouldering")]
    assert page["ai_body"].startswith("They boulder indoors")
    assert page["visibility"] == "public"
    assert page["page_type"] == "interests"
    assert page["links"] == ["lifestyle"]
    assert page["frontmatter"] == {"sport": "bouldering"}
    assert "created_at" in page and "updated_at" in page


def test_ingest_rewrites_an_existing_page_and_keeps_created_at(monkeypatch):
    db = FakeDb()
    _seed_page(
        db,
        "u1",
        "career",
        {"ai_body": "Works in marketing.", "page_type": "career",
         "created_at": "ORIGINAL"},
    )

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        assert "Works in marketing." in contents  # existing body was shown
        return {
            "pages": [
                {
                    "page_id": "career",
                    "page_type": "career",
                    "visibility": "private",
                    "ai_body": "Marketing lead at a fintech; wants to move into"
                    " product.",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(
        wiki_ingest.ingest(
            db, "u1", "sess-2", [Turn("user", "actually I lead the team now")]
        )
    )

    assert written == 1
    page = db.docs[("users", "u1", "wiki_pages", "career")]
    assert "product" in page["ai_body"]
    assert page["created_at"] == "ORIGINAL"  # not overwritten on rewrite


def test_ingest_keeps_the_users_own_visibility_choice(monkeypatch):
    db = FakeDb()
    _seed_page(
        db, "u1", "career",
        {"ai_body": "Old.", "page_type": "career", "created_at": "ORIG",
         "visibility": "private", "user_updated_at": "USER-SET-IT"},
    )

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        return {"pages": [{
            "page_id": "career", "page_type": "career",
            "visibility": "public",  # model wants public; user chose private
            "ai_body": "New body.",
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))

    page = db.docs[("users", "u1", "wiki_pages", "career")]
    assert page["ai_body"] == "New body."  # body still refreshed
    assert page["visibility"] == "private"  # user's choice preserved


def test_ingest_skips_invalid_ops(monkeypatch):
    db = FakeDb()

    async def _fake_json(*a, **k):
        return {
            "pages": [
                {"page_id": "Bad Id", "page_type": "career",
                 "visibility": "private", "ai_body": "x"},
                {"page_id": "ok", "page_type": "not-a-type",
                 "visibility": "private", "ai_body": "x"},
                {"page_id": "ok2", "page_type": "career",
                 "visibility": "loud", "ai_body": "x"},
                {"page_id": "ok3", "page_type": "career",
                 "visibility": "private", "ai_body": "   "},
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(wiki_ingest.ingest(db, "u1", "s", [Turn("user", "hi")]))
    assert written == 0
    assert db.writes == []


def test_ingest_is_credit_gated_like_the_rest_of_the_llm_loop(monkeypatch):
    """Wiki ingest is LLM background work — it stops when the user is out of
    credits (only heuristic paths keep running). It does NOT pass
    ``enforce_cap=False``, so ``gemini.generate_json``'s default cap check
    applies."""
    db = FakeDb()
    seen = {}

    async def _fake_json(contents, system_prompt, response_schema=None, **kw):
        seen.update(kw)
        return {
            "pages": [
                {
                    "page_id": "career",
                    "page_type": "career",
                    "visibility": "private",
                    "ai_body": "Leads a small team.",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    written = _run(
        wiki_ingest.ingest(db, "u1", "s", [Turn("user", "I lead the team now")])
    )

    assert written == 1
    assert seen.get("feature") == "wiki"
    assert seen.get("enforce_cap") is None  # default (gated)


def test_ingest_no_turns_is_a_noop(monkeypatch):
    db = FakeDb()
    called = False

    async def _fake_json(*a, **k):
        nonlocal called
        called = True
        return {"pages": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    assert _run(wiki_ingest.ingest(db, "u1", "s", [])) == 0
    assert called is False


def test_ingest_accepts_an_interactions_page_and_it_stays_ai_only(monkeypatch):
    """A transcript where Ayma reports on another person must not create
    identity/career pages about that person, but MAY record a one-line
    `interactions` note about the user's reaction — and that page is `ai_only`
    and still reaches Ayma via read_wiki_context."""
    import wiki_query

    db = FakeDb()

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        # The prompt teaches this separation.
        assert "ACCOUNT HOLDER" in system_prompt
        return {
            "pages": [
                {
                    "page_id": "interactions",
                    "page_type": "interactions",
                    "visibility": "ai_only",
                    "ai_body": (
                        "Things the user did with Ayma, newest first.\n\n"
                        "- 2026-09-10 — deep-dived Jordan (designer, Berlin); "
                        "lit up about the creative-career angle -> leans toward "
                        "artistic partners"
                    ),
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    written = _run(
        wiki_ingest.ingest(
            db,
            "u1",
            "sess-x",
            [
                Turn("user", "what did you find on Jordan?"),
                Turn("ayma", "Jordan is a designer in Berlin, at a studio..."),
                Turn("user", "oh nice, I love that he's a creative"),
            ],
        )
    )

    assert written == 1
    keys = {
        k[-1] for k in db.docs if k[:3] == ("users", "u1", "wiki_pages")
    }
    assert keys == {"interactions"}  # no identity/career page about Jordan
    page = db.docs[("users", "u1", "wiki_pages", "interactions")]
    assert page["page_type"] == "interactions"
    assert page["visibility"] == "ai_only"

    ctx = wiki_query.read_wiki_context(db, "u1")
    assert "deep-dived Jordan" in ctx  # ai_only still feeds Ayma's context


def test_prompt_asks_for_the_interaction_pattern():
    p = wiki_ingest.load_ingest_prompt()
    assert "how the user engages with Ayma herself" in p
    assert "communication style" in p
    assert 'Write to `steering`' in p


def test_ingest_window_carries_the_users_turns_verbatim(monkeypatch):
    """TASK 2 check: the model input is the user's turns verbatim, not a
    summary — so the interaction pattern is observable."""
    db = FakeDb()
    seen = {}

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        seen["contents"] = contents
        return {"pages": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(
        wiki_ingest.ingest(
            db, "u1", "s",
            [
                Turn("user", "stop asking me so many questions, just listen"),
                Turn("ayma", "understood."),
            ],
        )
    )
    assert "stop asking me so many questions, just listen" in seen["contents"]
    assert "User: stop asking me so many questions" in seen["contents"]
