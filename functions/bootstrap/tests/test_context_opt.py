"""Tests for the token-cost context-optimization switchboard (context_opt.py,
cost program 2026-09-26): flag parsing, Phase 0 measurement, the level-2 wiki
page-type routing, and the rolling summary machinery."""

import asyncio

import pytest

import context_opt
from transcript import Turn


# --- a tiny in-memory Firestore stub (just what context_opt touches) ---------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _Col:
    def __init__(self):
        self.added = []

    def add(self, doc):
        self.added.append(doc)

    def order_by(self, *a, **k):  # pruning path — return an empty query
        return self

    def offset(self, *_a):
        return self

    def limit(self, *_a):
        return self

    def stream(self):
        return []


class _UserDoc:
    def __init__(self, db, uid):
        self._db = db
        self._uid = uid

    def get(self):
        return _Snap(self._db.users.get(self._uid))

    def set(self, payload, merge=False):
        cur = self._db.users.setdefault(self._uid, {})
        cur.update(payload)

    def collection(self, name):
        return self._db.subcols.setdefault((self._uid, name), _Col())


class _Users:
    def __init__(self, db):
        self._db = db

    def document(self, uid):
        return _UserDoc(self._db, uid)


class _Db:
    def __init__(self):
        self.users = {}
        self.subcols = {}

    def collection(self, name):
        assert name == "users"
        return _Users(self)


@pytest.fixture
def db():
    return _Db()


@pytest.fixture(autouse=True)
def _fake_server_ts(monkeypatch):
    import firebase_admin.firestore as fs

    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "ts", raising=False)


# --- flags -------------------------------------------------------------------


def test_level_defaults_to_zero_everything_off(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    assert context_opt.level() == 0
    assert not context_opt.voice_compression_enabled()
    assert not context_opt.stable_prefix_enabled()
    assert not context_opt.summary_enabled()
    assert not context_opt.voice_seed_diet_enabled()
    assert not context_opt.wiki_trim_enabled()
    assert not context_opt.recall_enabled()


def test_level_gates_stack_cumulatively(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "1")
    assert context_opt.voice_compression_enabled()
    assert context_opt.stable_prefix_enabled()
    assert not context_opt.summary_enabled()

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    assert context_opt.voice_compression_enabled()
    assert context_opt.summary_enabled()
    assert context_opt.voice_seed_diet_enabled()
    assert context_opt.wiki_trim_enabled()
    assert not context_opt.recall_enabled()

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    assert context_opt.recall_enabled()


def test_voice_compression_supported_for_gates_by_model():
    # The Dev-API 3.1 preview accepts but does not honor the sliding window
    # (soft hint on audio; fatal 1007 on the text-seed path) — never send it.
    assert not context_opt.voice_compression_supported_for(
        "gemini-3.1-flash-live-preview"
    )
    assert not context_opt.voice_compression_supported_for(
        "models/gemini-3.1-flash-live-preview"
    )
    # The Vertex native-audio launch model honors it — keep it on there.
    assert context_opt.voice_compression_supported_for(
        "gemini-live-2.5-flash-native-audio"
    )
    assert context_opt.voice_compression_supported_for(
        "gemini-2.5-flash-native-audio-preview-12-2025"
    )
    assert context_opt.voice_compression_supported_for("")


def test_level_is_read_at_call_time_not_import_time(monkeypatch):
    # Rollback is a config flip: the same process must see a changed env.
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    assert context_opt.level() == 3
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "0")
    assert context_opt.level() == 0


def test_level_clamps_garbage_and_out_of_range(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "banana")
    assert context_opt.level() == 0
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "99")
    assert context_opt.level() == 3
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "-4")
    assert context_opt.level() == 0


def test_measure_flag_is_independent_of_level(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "true")
    assert context_opt.measure_enabled()
    assert context_opt.level() == 0
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "false")
    assert not context_opt.measure_enabled()


# --- Phase 0 measurement -------------------------------------------------------


def test_record_breakdown_persists_when_measure_on(monkeypatch, db):
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "true")
    context_opt.record_breakdown(
        db, "u1", "chat",
        {"system": 4000, "wiki": 8000, "history": 2000, "message": 40},
        session_id="s1",
    )
    col = db.subcols[("u1", context_opt.TOKEN_TURNS_COLLECTION)]
    assert len(col.added) == 1
    doc = col.added[0]
    assert doc["surface"] == "chat"
    assert doc["session_id"] == "s1"
    assert doc["components_chars"]["wiki"] == 8000
    assert doc["components_tokens"]["wiki"] == 2000  # chars/4
    assert doc["total_chars"] == 14040
    assert doc["est_tokens"] == 14040 // 4


def test_record_breakdown_only_logs_when_measure_off(monkeypatch, db, caplog):
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "false")
    with caplog.at_level("INFO", logger="ayma.context_opt"):
        context_opt.record_breakdown(
            db, "u1", "chat", {"system": 400, "message": 40}, session_id="s1"
        )
    assert ("u1", context_opt.TOKEN_TURNS_COLLECTION) not in db.subcols
    assert any("context-breakdown" in r.message for r in caplog.records)


def test_record_breakdown_never_raises(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "true")

    class _Boom:
        def collection(self, *_a):
            raise RuntimeError("firestore down")

    context_opt.record_breakdown(_Boom(), "u1", "chat", {"system": 1})


# --- level-2 wiki page-type routing -------------------------------------------


def test_wiki_include_types_always_carries_the_core():
    for msg in ("tell me about my job", "hey", "my mom visited", ""):
        got = context_opt.wiki_include_types(msg)
        assert context_opt.CORE_PAGE_TYPES <= got


def test_wiki_include_types_routes_topics():
    assert "career" in context_opt.wiki_include_types(
        "I got a promotion at work today"
    )
    assert "family" in context_opt.wiki_include_types("my sister is in town")
    assert "finances" in context_opt.wiki_include_types(
        "worried about my salary and rent"
    )
    assert "interests" in context_opt.wiki_include_types(
        "I went hiking this weekend"
    )


def test_wiki_include_types_unmatched_message_gets_the_default_set():
    got = context_opt.wiki_include_types("hmm ok")
    assert context_opt.DEFAULT_EXTRA_TYPES <= got


def test_trim_history_keeps_only_the_tail(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_TAIL_TURNS", "5")
    turns = [Turn("user", f"t{i}") for i in range(40)]
    tail = context_opt.trim_history(turns)
    assert len(tail) == 5
    assert tail[-1].text == "t39"


# --- rolling summary -----------------------------------------------------------


def _window(n, prefix="turn"):
    out = []
    for i in range(n):
        role = "user" if i % 2 == 0 else "ayma"
        out.append(Turn(role, f"{prefix} {i}"))
    return out


def _fake_summarizer(monkeypatch, calls):
    import gemini

    async def _fake_generate_json(contents, system_prompt, **kwargs):
        calls.append({"contents": contents, "kwargs": kwargs})
        return {"summary": "SUMMARY(" + str(len(calls)) + ")"}

    monkeypatch.setattr(gemini, "generate_json", _fake_generate_json)


def test_summary_updates_once_enough_new_turns_landed(monkeypatch, db):
    monkeypatch.setenv("CONTEXT_OPT_TAIL_TURNS", "15")
    monkeypatch.setenv("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", "20")
    calls = []
    _fake_summarizer(monkeypatch, calls)

    window = _window(50)
    assert asyncio.run(context_opt.maybe_update_summary(db, "u1", window))
    assert len(calls) == 1
    state = db.users["u1"][context_opt.SUMMARY_FIELD]
    assert state["text"] == "SUMMARY(1)"
    assert state["turn_count"] == 35  # 50 - 15 tail
    assert state["last_turn_text"] == "turn 34"
    assert context_opt.stored_summary_text(db, "u1") == "SUMMARY(1)"


def test_summary_is_incremental_never_per_message(monkeypatch, db):
    monkeypatch.setenv("CONTEXT_OPT_TAIL_TURNS", "15")
    monkeypatch.setenv("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", "20")
    calls = []
    _fake_summarizer(monkeypatch, calls)

    window = _window(50)
    assert asyncio.run(context_opt.maybe_update_summary(db, "u1", window))
    assert len(calls) == 1

    # A few more turns — below the threshold — must NOT re-summarize.
    window = window + _window(4, prefix="new")
    assert not asyncio.run(context_opt.maybe_update_summary(db, "u1", window))
    assert len(calls) == 1

    # Once ≥ N new turns have accumulated, exactly one more call happens and
    # its input carries only the new turns plus the previous summary.
    window = window + _window(30, prefix="fresh")
    assert asyncio.run(context_opt.maybe_update_summary(db, "u1", window))
    assert len(calls) == 2
    assert "SUMMARY(1)" in calls[1]["contents"]  # previous summary carried in
    # Only turns AFTER the first update's anchor ("turn 34") are re-sent:
    # already-summarized turns never pass through the model twice.
    new_section = calls[1]["contents"].split("New turns")[1]
    assert "turn 34" not in new_section
    assert "turn 20" not in new_section
    assert "turn 35" in new_section  # the first not-yet-summarized turn


def test_summary_survives_the_anchor_scrolling_away(monkeypatch, db):
    monkeypatch.setenv("CONTEXT_OPT_TAIL_TURNS", "15")
    monkeypatch.setenv("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", "20")
    calls = []
    _fake_summarizer(monkeypatch, calls)

    asyncio.run(context_opt.maybe_update_summary(db, "u1", _window(50)))
    # The client's rolling window slid past the anchor entirely.
    fresh = _window(60, prefix="other")
    assert asyncio.run(context_opt.maybe_update_summary(db, "u1", fresh))
    assert len(calls) == 2


def test_summary_noop_for_short_windows(monkeypatch, db):
    monkeypatch.setenv("CONTEXT_OPT_TAIL_TURNS", "15")
    monkeypatch.setenv("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", "20")
    calls = []
    _fake_summarizer(monkeypatch, calls)
    assert not asyncio.run(context_opt.maybe_update_summary(db, "u1", _window(10)))
    assert not calls
    assert context_opt.stored_summary_text(db, "u1") == ""


def test_summary_update_never_raises(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", "1")

    class _Boom:
        def collection(self, *_a):
            raise RuntimeError("firestore down")

    assert not asyncio.run(
        context_opt.maybe_update_summary(_Boom(), "u1", _window(60))
    )


def test_durable_fact_from_an_early_turn_survives_100_turns(monkeypatch, db):
    """Guardrail (Phase 2 deliverable): a durable fact stated early must still
    reach the assembled context after 100+ turns — via the summary, since the
    raw tail no longer carries it. The fake summarizer forwards any line
    containing 'Meera' the way the real prompt instructs (never drop names/
    preferences), so this exercises the real plumbing: the early turn must be
    IN the summarizer's input, and the stored summary must be IN the prompt."""
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    monkeypatch.setenv("CONTEXT_OPT_TAIL_TURNS", "15")
    monkeypatch.setenv("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", "20")

    import gemini

    async def _fact_keeping_summarizer(contents, system_prompt, **kwargs):
        kept = [
            ln for ln in contents.splitlines()
            if "Meera" in ln or ln.startswith("Previous summary:")
        ]
        prev = ""
        if "Previous summary:\n" in contents:
            prev = contents.split("Previous summary:\n")[1].split("\n\n")[0]
            if prev == "(none yet)":
                prev = ""
        return {"summary": (prev + " " + " ".join(kept)).strip()}

    monkeypatch.setattr(gemini, "generate_json", _fact_keeping_summarizer)

    window = [Turn("user", "my sister Meera lives in Kochi")] + _window(
        30, prefix="early"
    )
    asyncio.run(context_opt.maybe_update_summary(db, "u1", window))
    # 100+ more turns of unrelated chatter, summarized incrementally.
    for _ in range(4):
        window = window + _window(30, prefix="later")
        asyncio.run(context_opt.maybe_update_summary(db, "u1", window))
    assert len(window) > 100

    from prompt import compose_system_prompt

    prompt = compose_system_prompt(
        recent_turns=context_opt.trim_history(window),
        summary_context=context_opt.stored_summary_text(db, "u1"),
    )
    assert "Meera" in prompt  # carried by the summary, not the raw tail
    assert "early 0" not in prompt  # the raw early turns really are gone
