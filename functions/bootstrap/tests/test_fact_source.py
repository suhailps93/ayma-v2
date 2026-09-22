"""``find_fact_source`` — § fact-source-of-truth, 2026-09-21 (founder bug
report: asked Ayma "where did you get this from" about his child's name/
daycare and got a generic non-answer). Covers the four provenance sources it
aggregates: profile-field, questionnaire, wiki source_log, deep-dive facts."""

import json

import skills
from skills import fact_source


# --- a tiny path-keyed Firestore fake (same shape as test_wiki_ingest.py) ---


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

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))

    def get(self):
        return _Snap(self.key, self.store.docs.get(self.key))


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


def _tool(db):
    return skills.make_session_tool_fns(db, "u1")["find_fact_source"]


def test_registered_in_the_shared_registry():
    assert "find_fact_source" in {s.name for s in skills.all_skills()}
    assert "find_fact_source" in {
        d["name"] for d in skills.session_tool_declarations()
    }


def test_empty_query_asks_for_a_description():
    db = FakeDb()
    assert "description" in _tool(db)("").lower()


def test_no_match_returns_an_empty_list_not_a_guess():
    db = FakeDb({("users", "u1", "profile", "main"): {}})
    out = json.loads(_tool(db)("something totally unrelated xyz"))
    assert out == {"matches": []}


def test_finds_a_chat_profile_field_match():
    db = FakeDb({
        ("users", "u1", "profile", "main"): {
            "phone": "+15551234567",
            "provenance": {
                "phone": {
                    "source_type": "chat",
                    "quote": "my number is 555-123-4567",
                    "session_id": "sess-1",
                    "turn_index": 4,
                    "at": "2026-09-10T10:00:00+00:00",
                }
            },
        }
    })
    out = json.loads(_tool(db)("phone number"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "chat"
    assert m["exact"] is True
    assert m["quote"] == "my number is 555-123-4567"


def test_finds_a_questionnaire_match_with_provenance():
    db = FakeDb({
        ("users", "u1", "questionnaire", "alcohol_consumption"): {
            "value": "Rare Social",
            "provenance": {
                "source_type": "chat",
                "quote": "I drink socially, rarely",
                "session_id": "sess-2",
                "turn_index": 1,
                "at": "2026-09-01T00:00:00+00:00",
            },
        }
    })
    out = json.loads(_tool(db)("alcohol drinking habits"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["exact"] is True
    assert m["quote"] == "I drink socially, rarely"


def test_finds_a_questionnaire_match_without_provenance_marked_inexact():
    db = FakeDb({
        ("users", "u1", "questionnaire", "alcohol_consumption"): {
            "value": "Rare Social",
        }
    })
    out = json.loads(_tool(db)("alcohol drinking habits"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["exact"] is False
    assert m["current_value"] == "Rare Social"


def test_finds_a_wiki_source_log_match():
    """The exact bug report scenario: the Family page's ai_body has a
    verbatim excerpt on file — the fix that answers "where did you get
    this" instead of a generic reply."""
    db = FakeDb({
        ("users", "u1", "wiki_pages", "family"): {
            "ai_body": "His son Yahya goes to Sunshine Daycare.",
            "source_log": [
                {
                    "session_id": "sess-fam",
                    "excerpt": "User: my son Yahya goes to Sunshine Daycare",
                    "at": "2026-08-14T09:00:00+00:00",
                }
            ],
        }
    })
    out = json.loads(_tool(db)("my son's name and daycare"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "chat"
    assert m["exact"] is True
    assert "Yahya" in m["quote"]
    assert m["when"] == "2026-08-14T09:00:00+00:00"


def test_finds_a_deep_dive_web_search_match():
    db = FakeDb({
        ("users", "u1", "deep_dives", "uid_target1"): {
            "digest": {
                "name": "Jordan Rivers",
                "facts": [
                    {
                        "claim": "Jordan works as a designer at Acme Corp",
                        "category": "work",
                        "source_url": "https://acme.example.com/team/jordan",
                        "confidence": "high",
                    }
                ],
            },
            "created_at": "2026-07-01T00:00:00+00:00",
        }
    })
    out = json.loads(_tool(db)("Jordan's job at Acme"))
    assert len(out["matches"]) == 1
    m = out["matches"][0]
    assert m["type"] == "web_search"
    assert m["exact"] is True
    assert m["url"] == "https://acme.example.com/team/jordan"
    assert "designer" in m["quote"]


def test_results_are_capped_and_ranked_by_overlap():
    docs = {("users", "u1", "profile", "main"): {}}
    for i in range(10):
        docs[("users", "u1", "wiki_pages", f"page{i}")] = {
            "ai_body": "x",
            "source_log": [
                {"session_id": "s", "excerpt": "bouldering rocks", "at": "T"}
            ],
        }
    db = FakeDb(docs)
    out = json.loads(_tool(db)("bouldering"))
    assert len(out["matches"]) == fact_source._MAX_MATCHES
