"""Phase 3 of the cost program (context_opt): the on-demand ``recall(topic)``
tool — wiki-backed retrieval registered in both tool paths at
CONTEXT_OPT_LEVEL >= 3, with the standing wiki context shrunk to the core
card."""

import gemini
import skills
import wiki_query
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _Db:
    def __init__(self, snaps):
        self._snaps = snaps

    def collection(self, name):
        return self

    def document(self, name):
        return self

    def stream(self):
        return iter(self._snaps)


def _fake_wiki():
    return _Db(
        [
            _Snap("meera", {
                "page_type": "family",
                "ai_body": "Sister Meera lives in Kochi; they're close.",
            }),
            _Snap("career", {
                "page_type": "career",
                "ai_body": "Cardiologist at a Bangalore hospital.",
            }),
            _Snap("pottery", {
                "page_type": "interests",
                "ai_body": "Throws pots on weekends.",
            }),
        ]
    )


# --- recall_snippets (the wiki-backed retrieval) ------------------------------


def test_recall_returns_relevant_wiki_content_for_a_topic():
    out = wiki_query.recall_snippets(_fake_wiki(), "u1", "her sister and family")
    assert "Meera" in out
    assert "Cardiologist" not in out
    assert "Throws pots" not in out


def test_recall_matches_on_page_type_and_id_too():
    out = wiki_query.recall_snippets(_fake_wiki(), "u1", "career")
    assert "Cardiologist" in out


def test_recall_reports_no_match_honestly():
    assert wiki_query.recall_snippets(
        _fake_wiki(), "u1", "quantum physics"
    ) == "No notes found on that topic."
    assert wiki_query.recall_snippets(_fake_wiki(), "u1", "") == (
        "No notes found on that topic."
    )


def test_recall_respects_the_char_budget():
    big = _Db(
        [
            _Snap(f"family-{i}", {"page_type": "family", "ai_body": "x" * 2000})
            for i in range(5)
        ]
    )
    out = wiki_query.recall_snippets(big, "u1", "family", max_chars=3000)
    assert len(out) < 3500  # header + one page, not all five


def test_recall_never_raises():
    class _Boom:
        def collection(self, *_a):
            raise RuntimeError("firestore down")

    out = wiki_query.recall_snippets(_Boom(), "u1", "family")
    assert "Could not check" in out


# --- registration in both tool paths, flag-gated ------------------------------


def test_recall_is_absent_from_the_text_tool_set_below_level_3(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    names = {d["name"] for d in skills.session_tool_declarations()}
    assert "recall" not in names
    assert "recall" not in skills.make_session_tool_fns(object(), "u1")

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    names = {d["name"] for d in skills.session_tool_declarations()}
    assert "recall" not in names


def test_recall_is_registered_in_the_text_tool_set_at_level_3(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    decls = {d["name"]: d for d in skills.session_tool_declarations()}
    assert "recall" in decls
    assert "topic" in decls["recall"]["parameters"]["properties"]

    fns = skills.make_session_tool_fns(_fake_wiki(), "u1")
    assert "recall" in fns
    assert "Meera" in fns["recall"](topic="her sister")


def test_recall_has_kicker_labels():
    assert gemini._tool_label("recall") == "Checked her notes"
    assert gemini._working_label("recall") == "Checking her notes…"


# --- /chat wiring at level 3 ---------------------------------------------------


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer valid"}


def test_chat_level3_shrinks_wiki_to_core_and_registers_recall(monkeypatch):
    import context_opt
    import main

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    wiki_calls = []

    def _wiki(_db, _uid, *a, **k):
        wiki_calls.append(k)
        return "CORE CARD"

    monkeypatch.setattr(main, "read_wiki_context", _wiki)
    seen = {}

    async def _capture(message, system_prompt=None, tool_declarations=None, **_kw):
        seen["prompt"] = system_prompt
        seen["tools"] = {d["name"] for d in (tool_declarations or [])}
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    assert wiki_calls[0]["max_chars"] == context_opt.core_wiki_chars()
    assert wiki_calls[0]["include_page_types"] == context_opt.CORE_PAGE_TYPES
    assert "CORE CARD" in seen["prompt"]
    assert "recall" in seen["tools"]


def test_chat_level0_has_no_recall_tool(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    seen = {}

    async def _capture(message, tool_declarations=None, **_kw):
        seen["tools"] = {d["name"] for d in (tool_declarations or [])}
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    assert "recall" not in seen["tools"]
