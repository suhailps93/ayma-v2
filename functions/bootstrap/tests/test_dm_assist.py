import asyncio

import dm_assist
import gemini
import gemini
import gemini
import gemini
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    monkeypatch.setattr(main, "_enforce_age", _noop_age)
    return {"Authorization": "Bearer valid"}


async def _noop_age(*_a, **_k):
    return None


def _run(coro):
    return asyncio.run(coro)


class _MatchDb:
    """Minimal Firestore stand-in that returns one ``matches`` doc (or none)."""

    def __init__(self, doc):
        self._doc = doc

    def collection(self, name):
        assert name == "matches"
        return self

    def document(self, mid):
        self._mid = mid
        return self

    def get(self):
        doc = self._doc

        class _S:
            exists = doc is not None

            def to_dict(self):
                return doc

        return _S()


class _FakeProvider:
    """Stands in for the ``dm_coach`` LLM provider."""

    def __init__(self, result=None, boom=False):
        self._result = result
        self._boom = boom
        self.calls = []

    async def generate_json(self, contents, **kwargs):
        self.calls.append((contents, kwargs))
        if self._boom:
            raise RuntimeError("model down")
        return self._result


def _patch_provider(monkeypatch, provider):
    # DM coaching now resolves through the unified-brain resolver (§13.10).
    monkeypatch.setattr(
        dm_assist.llm_provider,
        "get_user_brain_provider",
        lambda uid, surface, *, needs=None: provider,
    )
    return provider


# --- opener mode --------------------------------------------------------- #


def test_opener_returns_empty_without_a_match_doc(monkeypatch):
    provider = _patch_provider(monkeypatch, _FakeProvider(boom=True))
    out = _run(dm_assist.assist(_MatchDb(None), "aaa", "bbb", []))
    assert out == {
        "mode": "opener", "chips": [], "tip": None,
        "safety": {"level": "none", "reason": "", "flags": []},
    }
    assert provider.calls == []  # never even called the model


def test_opener_generates_chips_from_the_analysis(monkeypatch):
    doc = {
        "ai_explanation": "Both are into trail running and long-form podcasts.",
        "user_explanation": {"aaa": "You both love the outdoors."},
    }
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider({"chips": ["  What's your favourite trail?  ", "", 5]}),
    )
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", []))
    assert out["mode"] == "opener"
    assert out["chips"] == ["What's your favourite trail?"]
    assert out["tip"] is None
    assert "MODE: opener" in provider.calls[0][0]
    assert "trail running" in provider.calls[0][0]


# --- coach mode ---------------------------------------------------------- #


def test_coach_returns_chips_and_tip(monkeypatch):
    doc = {
        "ai_explanation": "Both love the outdoors.",
        "user_explanation": {"aaa": "You both love hiking."},
    }
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "chips": ["So what got you into climbing?", "I tried bouldering once"],
                "tip": "You're asking a lot — share something about yourself too.",
            }
        ),
    )
    messages = [
        {"from": "me", "text": "hey!"},
        {"from": "them", "text": "hey, I just got back from climbing"},
    ]
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", messages))
    assert out["mode"] == "coach"
    assert out["chips"] == [
        "So what got you into climbing?",
        "I tried bouldering once",
    ]
    assert out["tip"] == "You're asking a lot — share something about yourself too."
    # Coach prompt carries both the analysis and the recent messages.
    sent = provider.calls[0][0]
    assert "MODE: coach" in sent
    assert "Them: hey, I just got back from climbing" in sent
    assert "Me: hey!" in sent


def test_assist_is_exempt_from_the_credit_cap(monkeypatch):
    """Root cause of the "no chips in a real thread" bug: DM assist is a nicety
    that must never block, so it calls the model with ``enforce_cap=False`` (the
    cap check is skipped, exactly like the Practice coach). A zero-credit user
    therefore still gets coaching instead of a silently-empty bar."""
    provider = _patch_provider(
        monkeypatch, _FakeProvider({"chips": ["tell me more"], "tip": "nice"})
    )
    _run(
        dm_assist.assist(
            _MatchDb(None), "aaa", "bbb", [{"from": "them", "text": "hi"}]
        )
    )
    assert provider.calls[0][1]["enforce_cap"] is False


def test_coach_survives_a_zero_credit_user(monkeypatch):
    """A provider that would raise ``TokenCapExceeded`` under the cap still
    yields coaching, because DM assist disables the cap check."""
    import token_ledger

    class _CappedProvider:
        async def generate_json(self, contents, **kwargs):
            # Mirror the real providers: only check the cap when asked to.
            if kwargs.get("enforce_cap", True):
                raise token_ledger.TokenCapExceeded("out of credits")
            return {"chips": ["so where to from here?"], "tip": "keep going"}

    _patch_provider(monkeypatch, _CappedProvider())
    out = _run(
        dm_assist.assist(
            _MatchDb(None), "aaa", "bbb", [{"from": "them", "text": "hey"}]
        )
    )
    assert out == {
        "mode": "coach",
        "chips": ["so where to from here?"],
        "tip": "keep going",
        "safety": {"level": "none", "reason": "", "flags": []},
    }


def test_coach_works_without_a_match_doc(monkeypatch):
    provider = _patch_provider(
        monkeypatch, _FakeProvider({"chips": ["tell me more"], "tip": ""})
    )
    out = _run(
        dm_assist.assist(
            _MatchDb(None), "aaa", "bbb", [{"from": "them", "text": "hi there"}]
        )
    )
    assert out["mode"] == "coach"
    assert out["chips"] == ["tell me more"]
    assert out["tip"] is None  # empty string normalises to null


def test_assist_swallows_generation_errors(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {}}
    _patch_provider(monkeypatch, _FakeProvider(boom=True))
    out = _run(
        dm_assist.assist(
            _MatchDb(doc), "aaa", "bbb", [{"from": "me", "text": "hello"}]
        )
    )
    assert out == {
        "mode": "coach", "chips": [], "tip": None,
        "safety": {"level": "none", "reason": "", "flags": []},
    }


def test_dm_coach_surface_defaults_to_gemini(monkeypatch):
    # Routing-audit H1: dm_coach defaults to the LiveKit-routed gemini brain
    # when the env is unset (no longer Meta-direct by default).
    import config

    monkeypatch.delenv("LLM_PROVIDER_DM_COACH", raising=False)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    assert config._load().llm_provider_dm_coach == "gemini"


# --- safety red-flag coach (§6.9.1) -------------------------------------- #


def _coach_out(monkeypatch, model_result, messages=None):
    """Run coach-mode assist with ``model_result`` as the faked model reply."""
    doc = {"ai_explanation": "x", "user_explanation": {"aaa": "y"}}
    _patch_provider(monkeypatch, _FakeProvider(model_result))
    msgs = messages or [{"from": "them", "text": "hey"}]
    return _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", msgs))


def test_safety_field_always_present_and_silent_by_default(monkeypatch):
    # A normal coach reply with no safety block → a silent 'none' assessment.
    out = _coach_out(monkeypatch, {"chips": ["nice"], "tip": ""})
    assert out["safety"] == {"level": "none", "reason": "", "flags": []}


def test_opener_includes_silent_safety(monkeypatch):
    doc = {"ai_explanation": "trail running", "user_explanation": {"aaa": "z"}}
    _patch_provider(monkeypatch, _FakeProvider({"chips": ["hi there"]}))
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", []))
    assert out["mode"] == "opener"
    # Opener mode never judges safety (no 'Them' messages yet).
    assert out["safety"] == {"level": "none", "reason": "", "flags": []}


def test_normal_flirting_stays_none(monkeypatch):
    # Even an enthusiastic, warm reply must NOT surface a safety note: the model
    # returns level 'none', and we pass it through silently (low false positive).
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["haha same"],
            "tip": "You're vibing — keep it light.",
            "safety": {"level": "none", "reason": "", "flags": []},
        },
        messages=[{"from": "them", "text": "haha you're so cute, I love this"}],
    )
    assert out["safety"]["level"] == "none"
    assert out["safety"]["reason"] == ""


def test_love_bombing_surfaces_warning(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["that's a lot, let's slow down"],
            "safety": {
                "level": "warning",
                "reason": "They're coming on really strong, really fast. "
                "It's okay to slow things down.",
                "flags": ["love_bombing"],
            },
        },
        messages=[
            {"from": "them", "text": "you're my soulmate, I've never felt this"},
        ],
    )
    assert out["safety"]["level"] == "warning"
    assert "love_bombing" in out["safety"]["flags"]
    assert out["safety"]["reason"]


def test_money_pressure_surfaces_warning(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["I'm not comfortable with that"],
            "safety": {
                "level": "warning",
                "reason": "They keep asking for money — that's a common scam "
                "pattern. Be careful.",
                "flags": ["money_request"],
            },
        },
        messages=[
            {"from": "them", "text": "can you send me $300 in gift cards?"},
        ],
    )
    assert out["safety"]["level"] == "warning"
    assert out["safety"]["flags"] == ["money_request"]


def test_rushing_to_meet_surfaces_caution(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["maybe once we've chatted more"],
            "safety": {
                "level": "caution",
                "reason": "Heads up — they're pushing to meet really fast. "
                "It's okay to take your time.",
                "flags": ["rushing_to_meet"],
            },
        },
    )
    assert out["safety"]["level"] == "caution"


def test_non_none_level_without_reason_is_downgraded(monkeypatch):
    # A bare alarm with nothing to say protects no one — fail quiet to 'none'.
    out = _coach_out(
        monkeypatch,
        {"chips": ["ok"], "safety": {"level": "warning", "flags": ["x"]}},
    )
    assert out["safety"] == {"level": "none", "reason": "", "flags": []}


def test_unknown_safety_level_fails_quiet(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["ok"],
            "safety": {"level": "DANGER", "reason": "boom", "flags": []},
        },
    )
    assert out["safety"]["level"] == "none"


def test_malformed_safety_block_fails_quiet(monkeypatch):
    out = _coach_out(
        monkeypatch, {"chips": ["ok"], "safety": "not-an-object"}
    )
    assert out["safety"] == {"level": "none", "reason": "", "flags": []}


def test_safety_flags_are_capped_and_cleaned(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["ok"],
            "safety": {
                "level": "caution",
                "reason": "A few things to watch.",
                "flags": ["a", " b ", "", 5, "c", "d", "e", "f", "g"],
            },
        },
    )
    # Blanks/non-strings dropped, trimmed, capped at _MAX_FLAGS (6).
    assert out["safety"]["flags"] == ["a", "b", "c", "d", "e", "f"]


def test_safety_silent_on_generation_error(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {}}
    _patch_provider(monkeypatch, _FakeProvider(boom=True))
    out = _run(
        dm_assist.assist(
            _MatchDb(doc), "aaa", "bbb", [{"from": "them", "text": "hi"}]
        )
    )
    assert out["safety"] == {"level": "none", "reason": "", "flags": []}


def test_response_schema_requests_safety():
    # The single Muse call also asks for the safety assessment (one call, not
    # a separate round-trip).
    props = dm_assist._RESPONSE_SCHEMA["properties"]
    assert "safety" in props
    assert props["safety"]["properties"]["level"]["enum"] == [
        "none", "caution", "warning",
    ]


# --- tip hygiene: short, clean, never raw reasoning/JSON (regression) ---- #


def test_short_clean_tip_passes_through(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {"chips": ["tell me more"], "tip": "Nice, you opened up — keep that going."},
    )
    assert out["tip"] == "Nice, you opened up — keep that going."


def test_rambling_tip_is_dropped(monkeypatch):
    # A paragraph-long run-on with no sentence break is not a tip — drop it, but
    # keep the chips (the bar still works).
    ramble = (
        "You are doing really well here and should keep the conversation flowing "
        "smoothly naturally quietly comfortably easily without issue and just stay "
        "relaxed and warm and curious and open and genuine throughout the whole thing"
    )
    out = _coach_out(monkeypatch, {"chips": ["so what's next?"], "tip": ramble})
    assert out["tip"] is None
    assert out["chips"] == ["so what's next?"]


def test_leaked_reasoning_and_json_tip_is_dropped(monkeypatch):
    # The exact failure mode from the bug report: the model's chain-of-thought
    # and raw JSON leaked verbatim into the tip. It must NEVER reach the UI.
    leaked = (
        'Wait, what about safety? Them said nothing concerning. Guardrails: Base '
        'every flag on something Them actually said. JSON shape: '
        '{"chips":["hey"],"tip":"...","safety":{"flags":[],"level":"none","reason":""}}'
    )
    out = _coach_out(monkeypatch, {"chips": ["nice"], "tip": leaked})
    assert out["tip"] is None


def test_tip_trimmed_to_its_first_sentence(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["ok"],
            "tip": "Great question. Now also tell them about yourself.",
        },
    )
    assert out["tip"] == "Great question."


def test_safety_reason_with_leaked_json_fails_quiet(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {
            "chips": ["ok"],
            "safety": {
                "level": "warning",
                "reason": 'warning because {"level":"warning"} they pushed',
                "flags": ["x"],
            },
        },
    )
    assert out["safety"] == {"level": "none", "reason": "", "flags": []}


# --- endpoint ------------------------------------------------------------ #


def test_endpoint_rejects_self_as_other(monkeypatch):
    resp = client.post(
        "/dm/assist", json={"other": "aaa", "messages": []},
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 400


def test_endpoint_opener(monkeypatch):
    async def _fake_assist(db, uid, other, messages):
        assert (uid, other) == ("aaa", "bbb")
        assert messages == []
        return {"mode": "opener", "chips": ["chip one", "chip two"], "tip": None}

    monkeypatch.setattr(main.dm_assist, "assist", _fake_assist)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/dm/assist", json={"other": "bbb", "messages": []},
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "mode": "opener", "chips": ["chip one", "chip two"], "tip": None,
    }


def test_endpoint_coach_passes_messages(monkeypatch):
    async def _fake_assist(db, uid, other, messages):
        assert messages == [
            {"from": "me", "text": "hi"},
            {"from": "them", "text": "hey you"},
        ]
        return {"mode": "coach", "chips": ["nice"], "tip": "keep going"}

    monkeypatch.setattr(main.dm_assist, "assist", _fake_assist)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/dm/assist",
        json={
            "other": "bbb",
            "messages": [
                {"from": "me", "text": "hi"},
                {"from": "them", "text": "hey you"},
            ],
        },
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 200
    assert resp.json() == {"mode": "coach", "chips": ["nice"], "tip": "keep going"}


# --- one-sided coach threads + generation retry (founder bug, 2026-11-07) - #


def test_coach_one_sided_thread_asks_for_followup_coaching(monkeypatch):
    """The founder case: Me has written (Hi, two voice notes, hello) and the
    match has not replied. Coach mode must be told the match has not replied
    yet, so the model coaches a follow-up instead of offering first-ever
    greetings as if the thread were brand new."""
    doc = {
        "ai_explanation": "Both love the outdoors.",
        "user_explanation": {"aaa": "You both love hiking."},
    }
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "chips": ["No rush at all, just wanted to say hi."],
                "tip": "Give them some room to reply before sending more.",
            }
        ),
    )
    messages = [
        {"from": "me", "text": "Hi"},
        {"from": "me", "text": "[voice message]"},
        {"from": "me", "text": "[voice message]"},
        {"from": "me", "text": "hello"},
    ]
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", messages))
    assert out["mode"] == "coach"
    assert out["chips"] == ["No rush at all, just wanted to say hi."]
    assert out["tip"] == "Give them some room to reply before sending more."
    sent = provider.calls[0][0]
    assert "MODE: coach" in sent
    assert "the match has not replied yet" in sent
    assert "never a first-ever greeting" in sent
    # Coaching runs at 0.7: at the 0.2 default the model repetition-loops
    # its tip into a run-on that hygiene then has to drop (measured live).
    assert provider.calls[0][1]["temperature"] == 0.7


def test_coach_two_sided_thread_has_no_one_sided_note(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {"aaa": "y"}}
    provider = _patch_provider(
        monkeypatch, _FakeProvider({"chips": ["nice"], "tip": ""})
    )
    messages = [
        {"from": "me", "text": "hey!"},
        {"from": "them", "text": "hey, just got back from climbing"},
    ]
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", messages))
    assert out["mode"] == "coach"
    assert "the match has not replied yet" not in provider.calls[0][0]


class _FlakyProvider:
    """Raises on the first call (the truncated-JSON failure surfacing from
    generate_json), then returns a good result — the intermittent shape the
    retry exists for."""

    def __init__(self, result, failures=1):
        self._result = result
        self._failures = failures
        self.calls = []

    async def generate_json(self, contents, **kwargs):
        self.calls.append((contents, kwargs))
        if len(self.calls) <= self._failures:
            raise ValueError("Unterminated string starting at: line 7")
        return self._result


def test_coach_retries_once_when_generation_fails(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {}}
    provider = _patch_provider(
        monkeypatch,
        _FlakyProvider({"chips": ["tell me more"], "tip": "keep going"}),
    )
    out = _run(
        dm_assist.assist(
            _MatchDb(doc), "aaa", "bbb", [{"from": "me", "text": "hello"}]
        )
    )
    assert out["mode"] == "coach"
    assert out["chips"] == ["tell me more"]
    assert out["tip"] == "keep going"
    assert len(provider.calls) == 2


def test_coach_gives_up_after_two_generation_failures(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {}}
    provider = _patch_provider(
        monkeypatch, _FlakyProvider(None, failures=99)
    )
    out = _run(
        dm_assist.assist(
            _MatchDb(doc), "aaa", "bbb", [{"from": "me", "text": "hello"}]
        )
    )
    assert out == {
        "mode": "coach", "chips": [], "tip": None,
        "safety": {"level": "none", "reason": "", "flags": []},
    }
    assert len(provider.calls) == 2  # one attempt + exactly one retry


# --- Leg 3 (NOTE 145): truncated replies are salvaged, one-sided tip ---- #
# Fixtures are the real truncated replies from the staging logs, Nov 7:
# two dm_assist generations cut at 4081/4082 output tokens on the
# Alexander one-sided thread (finish_reason "length"). Both have complete
# chips and a tip that runs on into filler until the budget cuts it.


_TRUNCATED_A = """{"chips": ["how's your week shaping up so far?", "curious what brought you to the app", "no rush on this, just curious how your week is going"], "tip": "Give them a beat to reply to your opener before sending another message, or keep it super low-pressure if you do reach out again soon. Taking your time here makes sense anyway given the mismatch flags you noticed earlier on their profile, so there is no rush at all to push things forward right now anyway in this thread currently today at all indeed truly so just sit tight and relax for now buddy you got this entirely fine naturally without wor"""

_TRUNCATED_B = """{
  "chips": [
    "How's your week treating you so far?",
    "Curious what you usually get up to on weekends around here.",
    "No rush on this, just thought I'd say a proper hello."
  ],
  "tip": "Give it a little time before sending anything else — let them respond first if they want to chat naturally so the conversation stays low-pressure and balanced without overwhelming their inbox right off the bat today either way really nicely played so far though honestly you did great with that simple opener already just relax for now and see what happens naturally here today cheers to you friend """

_ONE_SIDED_MSGS = [{"from": "me", "text": "hey alex, Daniel here. good to see the thread live."}]


class _TruncatingProvider:
    """Raises UnparseableReplyError carrying a truncated reply for the first
    N calls (like live gemini.generate_json on a budget-truncated reply),
    then returns ``result``."""

    def __init__(self, texts, result=None):
        self._texts = list(texts)
        self._result = result
        self.calls = []

    async def generate_json(self, contents, **kwargs):
        self.calls.append((contents, kwargs))
        if len(self.calls) <= len(self._texts):
            raise gemini.UnparseableReplyError(
                self._texts[len(self.calls) - 1], "length"
            )
        return self._result


def test_salvage_recovers_chips_from_truncated_reply():
    out = dm_assist._salvage_partial(_TRUNCATED_A)
    assert out is not None
    assert out["chips"] == [
        "how's your week shaping up so far?",
        "curious what brought you to the app",
        "no rush on this, just curious how your week is going",
    ]
    # The tip's first sentence is the intended nudge; the run-on tail is
    # still in the raw string and _clean_tip trims it away.
    assert dm_assist._clean_tip(out) == (
        "Give them a beat to reply to your opener before sending another "
        "message, or keep it super low-pressure if you do reach out again soon."
    )


def test_salvage_recovers_chips_from_pretty_truncated_reply():
    out = dm_assist._salvage_partial(_TRUNCATED_B)
    assert out is not None
    assert out["chips"] == [
        "How's your week treating you so far?",
        "Curious what you usually get up to on weekends around here.",
        "No rush on this, just thought I'd say a proper hello.",
    ]
    # This tip never reaches a sentence break before the cut, so hygiene
    # drops it — the one-sided fallback (tested below) supplies the nudge.
    assert dm_assist._clean_tip(out) is None


def test_salvage_returns_none_when_chips_truncated():
    # No complete chip survives the cut: nothing to salvage.
    assert dm_assist._salvage_partial('{"chips": ["tw') is None
    assert dm_assist._salvage_partial("") is None
    assert dm_assist._salvage_partial('{"chips": []') is None
    # One complete chip before the cut IS recovered — that is the point.
    out = dm_assist._salvage_partial('{"chips": ["one", "tw')
    assert out is not None and out["chips"] == ["one"]


def test_salvage_keeps_complete_safety():
    out = dm_assist._salvage_partial(
        '{"chips": ["a"], "tip": "t.", "safety": {"level": "caution", '
        '"reason": "pushing to meet", "flags": ["meet"]}}'
    )
    assert out is not None
    assert out["safety"]["level"] == "caution"
    # A safety block cut mid-object is not trusted — stay silent.
    cut = dm_assist._salvage_partial(
        '{"chips": ["a"], "tip": "t.", "safety": {"level": "caution", "re'
    )
    assert cut["safety"]["level"] == "none"


def test_truncated_reply_is_salvaged_without_retry(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {"aaa": "y"}}
    provider = _patch_provider(
        monkeypatch, _TruncatingProvider([_TRUNCATED_A])
    )
    out = _run(
        dm_assist.assist(_MatchDb(doc), "aaa", "bbb", _ONE_SIDED_MSGS)
    )
    assert out["mode"] == "coach"
    assert out["chips"] == [
        "how's your week shaping up so far?",
        "curious what brought you to the app",
        "no rush on this, just curious how your week is going",
    ]
    assert out["tip"] == (
        "Give them a beat to reply to your opener before sending another "
        "message, or keep it super low-pressure if you do reach out again soon."
    )
    # No retry spent: the salvage already recovered the bar.
    assert len(provider.calls) == 1


def test_truncated_reply_with_unusable_tip_gets_fallback_tip(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {"aaa": "y"}}
    provider = _patch_provider(
        monkeypatch, _TruncatingProvider([_TRUNCATED_B])
    )
    out = _run(
        dm_assist.assist(_MatchDb(doc), "aaa", "bbb", _ONE_SIDED_MSGS)
    )
    assert out["chips"][0] == "How's your week treating you so far?"
    assert out["tip"] == dm_assist._ONE_SIDED_FALLBACK_TIP
    assert len(provider.calls) == 1


def test_unrecoverable_truncation_retries_once_then_gives_up(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {"aaa": "y"}}
    provider = _patch_provider(
        monkeypatch, _TruncatingProvider(['{"chips": ["on', '{"chips": ["tw'])
    )
    out = _run(
        dm_assist.assist(_MatchDb(doc), "aaa", "bbb", _ONE_SIDED_MSGS)
    )
    assert out["chips"] == []
    # Total failure keeps the pinned contract (tip None) — the one-sided
    # fallback covers landed generations, not a wholly failed call.
    assert out["tip"] is None
    assert len(provider.calls) == 2  # one attempt + exactly one retry


def test_one_sided_empty_tip_gets_fallback(monkeypatch):
    out = _coach_out(
        monkeypatch,
        {"chips": ["follow up gently"], "tip": ""},
        messages=_ONE_SIDED_MSGS,
    )
    assert out["tip"] == dm_assist._ONE_SIDED_FALLBACK_TIP


def test_two_sided_empty_tip_stays_empty(monkeypatch):
    out = _coach_out(monkeypatch, {"chips": ["nice"], "tip": ""})
    assert out["tip"] is None


def test_dm_assist_caps_completion_budget(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {"aaa": "y"}}
    provider = _patch_provider(
        monkeypatch, _FakeProvider({"chips": ["ok"], "tip": "keep going"})
    )
    _run(
        dm_assist.assist(
            _MatchDb(doc), "aaa", "bbb", [{"from": "them", "text": "hey"}]
        )
    )
    assert provider.calls[0][1]["temperature"] == 0.7
    assert provider.calls[0][1]["max_tokens"] == 1024


def test_prompt_carves_out_one_sided_chip_rule():
    prompt = dm_assist._load_prompt()
    assert "When `Them` has not replied yet there is no last thing `Them` said" in prompt
    assert "never re-greet" in prompt
    assert "Did that come through all right?" in prompt
    assert "build on `Me`'s message itself" in prompt
    assert "the `tip` is never empty" in prompt
