"""Offline unit tests for the voice-actions skill (no model, no network —
``inference_llm.complete`` is stubbed wherever the pass itself is covered).
The real-model eval lives in ``test_voice_actions_eval.py`` (live-gated).
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

import app_registry
from skills import voice_actions
from skills.voice_actions import CallContext, Verdict


def test_guidance_loads_and_carries_the_models_fact():
    text = voice_actions.load_guidance()
    assert len(text) > 1000
    # The Models destination is the Models page itself, never its parents.
    assert "voice_preference" in text
    assert "/settings/voice" in text
    assert "never Settings" in text or "Never to Settings" in text


def test_guidance_includes_the_shipped_cases_as_examples():
    text = voice_actions.load_guidance()
    for phrase in (
        "Can you open up Explore?",
        "open up the AMA models page",
        "Can we start a simulated conversation with her?",
        "Start an agent to agent conversation with her.",
        "Can I talk to her in practice?",
        "Can you open an agent to agent simulation with Sophia?",
        "goodbye Ayma",
    ):
        assert phrase in text, phrase


def test_guidance_has_no_refusal_outcome():
    # Outcomes are only execute, clarify, or none — "refus*" may appear in
    # the guidance and the module doc only to state that no refusal exists.
    for text in (voice_actions.load_guidance(), voice_actions.__doc__):
        denied = text.lower().replace("no refusal", "")
        assert "refus" not in denied, text[:120]


def test_guidance_resolution_rules_are_stated():
    text = voice_actions.load_guidance()
    assert "NAME always beats context" in text
    assert "nobody salient" in text
    assert "who with" in text.lower()


def test_parse_verdict_accepts_every_action_shape():
    assert voice_actions.parse_verdict(
        {"action": "navigate", "page": "explore"}
    ) == Verdict(action="navigate", page="explore")
    assert voice_actions.parse_verdict(
        {"action": "open_profile", "member": "Sofia"}
    ) == Verdict(action="open_profile", member="Sofia")
    assert voice_actions.parse_verdict(
        {"action": "launch_sim", "partner": "Dillu"}
    ) == Verdict(action="launch_sim", partner="Dillu")
    assert voice_actions.parse_verdict(
        {"action": "set_stack", "tool": "set_brain", "value": "meta"}
    ) == Verdict(action="set_stack", tool="set_brain", value="meta")
    assert voice_actions.parse_verdict(
        {"action": "set_voice", "voice_kind": "language",
         "voice_value": "Spanish"}
    ) == Verdict(
        action="set_voice", voice_kind="language", voice_value="Spanish"
    )
    assert voice_actions.parse_verdict({"action": "start_tour"}).action == (
        "start_tour"
    )
    assert voice_actions.parse_verdict({"action": "end_call"}).action == (
        "end_call"
    )
    assert voice_actions.parse_verdict(
        {"action": "clarify", "for": "launch_sim"}
    ) == Verdict(action="clarify", clarify_for="launch_sim")
    assert voice_actions.parse_verdict({"action": "none"}) == Verdict()


@pytest.mark.parametrize("raw", [
    {"action": "refuse"},
    {"action": "bogus"},
    {"action": ""},
    {},
    {"page": "explore"},
    "navigate",
    None,
    [{"action": "none"}],
])
def test_parse_verdict_degrades_anything_unknown_to_none(raw):
    assert voice_actions.parse_verdict(raw) == Verdict()


def test_verdict_to_command_maps_navigate_by_key_and_by_words():
    assert voice_actions.verdict_to_command(
        Verdict(action="navigate", page="explore")
    ) == ("open_screen", {"screen": "explore"})
    # The Models page resolves to itself even in the user's own words.
    assert voice_actions.verdict_to_command(
        Verdict(action="navigate", page="the models page")
    ) == ("open_screen", {"screen": "voice_preference"})
    assert voice_actions.verdict_to_command(
        Verdict(action="navigate", page="no such page xyz")
    ) is None
    assert voice_actions.verdict_to_command(
        Verdict(action="navigate", page="")
    ) is None


def test_verdict_to_command_maps_open_profile():
    assert voice_actions.verdict_to_command(
        Verdict(action="open_profile", member="Sofia")
    ) == ("open_profile", {"name": "Sofia"})
    assert voice_actions.verdict_to_command(
        Verdict(action="open_profile", member="")
    ) is None


def test_verdict_to_command_maps_launches_and_keeps_empty_partner():
    assert voice_actions.verdict_to_command(
        Verdict(action="launch_practice", partner="Dillu")
    ) == ("open_practice_date", {"name": "Dillu"})
    assert voice_actions.verdict_to_command(
        Verdict(action="launch_sim", partner="Sophia")
    ) == ("open_date_sim", {"name": "Sophia"})
    # An empty partner flows into the relay's existing partner-less branch
    # (the "who with?" clarification), never a launch.
    assert voice_actions.verdict_to_command(
        Verdict(action="launch_sim", partner="")
    ) == ("open_date_sim", {"name": ""})


def test_verdict_to_command_practice_voice_modality_carries_the_flag():
    # Bug DC2eUbckGA6J0ufDZpRG: modality voice -> the launch carries
    # voice=True so the practice voice call auto-starts; modality text
    # (or none) keeps the plain text launch.
    assert voice_actions.verdict_to_command(
        Verdict(action="launch_practice", partner="Dillu", modality="voice")
    ) == ("open_practice_date", {"name": "Dillu", "voice": True})
    assert voice_actions.verdict_to_command(
        Verdict(action="launch_practice", partner="Dillu", modality="text")
    ) == ("open_practice_date", {"name": "Dillu"})
    parsed = voice_actions.parse_verdict(
        {"action": "launch_practice", "partner": "Sofia",
         "modality": "voice"}
    )
    assert parsed.modality == "voice"
    assert voice_actions.verdict_to_command(parsed) == (
        "open_practice_date", {"name": "Sofia", "voice": True}
    )


@pytest.mark.parametrize("tool,value,kwarg,want", [
    ("set_brain", "meta", "brain", "meta"),
    ("set_brain", "switch to Muse Spark", "brain", "meta"),
    ("set_brain", "Gemini", "brain", "gemini"),
    ("set_voice_mode", "cascade", "mode", "cascade"),
    ("set_voice_mode", "realtime", "mode", "realtime"),
    ("set_realtime_model", "openai realtime", "model", "openai-realtime"),
    ("set_realtime_model", "gemini live", "model", "gemini-live"),
])
def test_verdict_to_command_maps_stack_values(tool, value, kwarg, want):
    assert voice_actions.verdict_to_command(
        Verdict(action="set_stack", tool=tool, value=value)
    ) == (tool, {kwarg: want})


def test_verdict_to_command_resolves_engines_from_config():
    import voice_catalog

    stt_models = voice_catalog.CONFIG.voice_cascade_stt_models
    tts_models = voice_catalog.CONFIG.voice_cascade_tts_models
    assert stt_models and tts_models  # the test below needs real entries
    stt_provider = stt_models[0].partition("/")[0]
    tts_provider = tts_models[0].partition("/")[0]
    assert voice_actions.verdict_to_command(
        Verdict(action="set_stack", tool="set_stt", value=stt_provider)
    ) == ("set_stt", {"engine": stt_models[0]})
    assert voice_actions.verdict_to_command(
        Verdict(action="set_stack", tool="set_tts", value=tts_provider)
    ) == ("set_tts", {"engine": tts_models[0]})
    # A generic word matches no engine: the turn stays conversation.
    assert voice_actions.verdict_to_command(
        Verdict(action="set_stack", tool="set_stt", value="default")
    ) is None


@pytest.mark.parametrize("tool,value", [
    ("set_brain", "something unresolvable xyz"),
    ("set_voice_mode", "party mode"),
    ("set_realtime_model", "some model"),
    ("set_brain", ""),
    ("not_a_tool", "gemini"),
    ("", ""),
])
def test_verdict_to_command_rejects_unresolvable_stack(tool, value):
    assert voice_actions.verdict_to_command(
        Verdict(action="set_stack", tool=tool, value=value)
    ) is None


def test_verdict_to_command_maps_explain_page():
    assert voice_actions.verdict_to_command(
        Verdict(action="explain_page")
    ) == ("explain_this_page", {})


def test_verdict_to_command_maps_set_voice_and_start_tour():
    assert voice_actions.verdict_to_command(
        Verdict(
            action="set_voice", voice_kind="language",
            voice_value="Spanish",
        )
    ) == ("set_voice_preference", {"accent_language": "Spanish"})
    assert voice_actions.verdict_to_command(
        Verdict(
            action="set_voice", voice_kind="accent",
            voice_value="southern American accent",
        )
    ) == (
        "set_voice_preference", {"accent": "southern American accent"}
    )
    assert voice_actions.verdict_to_command(
        Verdict(
            action="set_voice", voice_kind="character",
            voice_value="sound like a man",
        )
    ) == ("set_voice_preference", {"request": "sound like a man"})
    # An unknown kind or an empty value stays conversation — a misrouted
    # value could otherwise write the WRONG voice setting.
    assert voice_actions.verdict_to_command(
        Verdict(
            action="set_voice", voice_kind="bogus", voice_value="Spanish"
        )
    ) is None
    assert voice_actions.verdict_to_command(
        Verdict(action="set_voice", voice_kind="language", voice_value="")
    ) is None
    assert voice_actions.verdict_to_command(Verdict(action="set_voice")) is None
    assert voice_actions.verdict_to_command(
        Verdict(action="start_tour")
    ) == ("start_guided_tour", {})


def test_verdict_to_command_maps_end_call_and_clarify():
    assert voice_actions.verdict_to_command(
        Verdict(action="end_call")
    ) == ("end_call", {})
    assert voice_actions.verdict_to_command(
        Verdict(action="clarify", clarify_for="launch_sim")
    ) == ("open_date_sim", {"name": ""})
    assert voice_actions.verdict_to_command(
        Verdict(action="clarify", clarify_for="launch_practice")
    ) == ("open_practice_date", {"name": ""})
    assert voice_actions.verdict_to_command(
        Verdict(action="clarify", clarify_for="navigate")
    ) is None
    assert voice_actions.verdict_to_command(Verdict()) is None
    assert voice_actions.verdict_to_command(None) is None


def _ok_response(text: str):
    return SimpleNamespace(
        text=text, usage_metadata=SimpleNamespace(
            input_tokens=10, output_tokens=5, total_tokens=15,
        ),
    )


def test_interpret_runs_one_configured_livekit_pass(monkeypatch):
    import inference_llm
    from config import CONFIG

    calls = []

    async def fake_complete(**kwargs):
        calls.append(kwargs)
        return _ok_response('{"action": "navigate", "page": "explore"}')

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    recorded = []
    monkeypatch.setattr(
        voice_actions.token_ledger, "record",
        lambda *a, **k: recorded.append((a, k)),
    )
    verdict = asyncio.run(
        voice_actions.interpret_voice_action(
            "open explore", CallContext(), uid="u1", session_id="s1",
        )
    )
    assert verdict == Verdict(action="navigate", page="explore")
    assert len(calls) == 1  # exactly one model pass
    (call,) = calls
    assert call["model"] == CONFIG.inference_json_model
    assert call["temperature"] == 0.0
    assert call["response_schema"] == voice_actions.RESPONSE_SCHEMA
    roles = [m["role"] for m in call["messages"]]
    assert roles == ["system", "user"]
    assert "open explore" in call["messages"][1]["content"]
    # The spend is metered to the voice ledger on the inference provider.
    assert len(recorded) == 1
    ((uid, feature, _resp), kwargs) = recorded[0]
    assert uid == "u1" and feature == "voice"
    assert kwargs["session_id"] == "s1"
    assert kwargs["provider"] == voice_actions.token_ledger.PROVIDER_LIVEKIT_INFERENCE


def test_interpret_tolerates_fenced_and_empty_answers(monkeypatch):
    import inference_llm

    async def fenced(**kwargs):
        return _ok_response('```json\n{"action": "end_call"}\n```')

    async def empty(**kwargs):
        return _ok_response("   ")

    monkeypatch.setattr(
        voice_actions.token_ledger, "record", lambda *a, **k: None
    )
    monkeypatch.setattr(inference_llm, "complete", fenced)
    assert asyncio.run(
        voice_actions.interpret_voice_action("goodbye Ayma")
    ) == Verdict(action="end_call")
    monkeypatch.setattr(inference_llm, "complete", empty)
    assert asyncio.run(
        voice_actions.interpret_voice_action("goodbye Ayma")
    ) == Verdict()


def test_interpret_unparseable_answer_is_none_but_failure_raises(monkeypatch):
    import inference_llm

    async def garbage(**kwargs):
        return _ok_response("not json at all")

    async def boom(**kwargs):
        raise RuntimeError("gateway down")

    monkeypatch.setattr(
        voice_actions.token_ledger, "record", lambda *a, **k: None
    )
    monkeypatch.setattr(inference_llm, "complete", garbage)
    assert asyncio.run(
        voice_actions.interpret_voice_action("open explore")
    ) == Verdict()
    # A transport failure propagates — the relay falls back to the net.
    monkeypatch.setattr(inference_llm, "complete", boom)
    with pytest.raises(RuntimeError):
        asyncio.run(voice_actions.interpret_voice_action("open explore"))


def test_build_user_message_carries_transcript_context_and_pages():
    msg = voice_actions.build_user_message(
        "talk to her in practice",
        CallContext(
            member="Dillu", page="profile",
            turns=(("user", "I matched with Dillu"),),
        ),
    )
    assert "talk to her in practice" in msg
    assert "Dillu" in msg
    assert "profile" in msg
    assert "I matched with Dillu" in msg
    for key in ("explore", "voice_preference", "messages"):
        assert key in msg
    bare = voice_actions.build_user_message("hi", CallContext())
    assert "(nobody in particular)" in bare
    assert "(none)" in bare


class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return self._data


def _mirror_data(monkeypatch, data):
    import datetime

    if data is not None and "updated_at" not in data:
        data = dict(
            data,
            updated_at=datetime.datetime.now(datetime.timezone.utc),
        )
    calls = {}

    def fake_doc(db, uid):
        calls["uid"] = uid

        class _D:
            @staticmethod
            def get():
                return _Snap(data)

        return _D()

    import skills.app_control_mirror as mirror

    monkeypatch.setattr(mirror, "_voice_context_doc", fake_doc)
    return calls


def test_read_call_context_reads_the_fresh_mirror_and_turns(monkeypatch):
    calls = _mirror_data(monkeypatch, {
        "screen": "profile", "subject_name": "Dillu",
    })
    window = [
        SimpleNamespace(role="user", text="I matched with Dillu"),
        SimpleNamespace(role="assistant", text="Nice!"),
    ]
    ctx = voice_actions.read_call_context(object(), "u9", window)
    assert calls == {"uid": "u9"}
    assert ctx.member == "Dillu"
    assert ctx.page == "profile"
    assert ctx.turns == (
        ("user", "I matched with Dillu"), ("assistant", "Nice!"),
    )


def test_read_call_context_degrades_on_stale_mirror_and_db_failure(
    monkeypatch,
):
    import datetime

    stale = _mirror_data(monkeypatch, {
        "screen": "profile", "subject_name": "Dillu",
        "updated_at": datetime.datetime(2000, 1, 1),
    })
    window = [SimpleNamespace(role="user", text="hello")]
    ctx = voice_actions.read_call_context(object(), "u9", window)
    assert stale == {"uid": "u9"}
    assert (ctx.member, ctx.page) == ("", "")
    assert ctx.turns == (("user", "hello"),)

    import skills.app_control_mirror as mirror

    def boom(_db, _uid):
        raise RuntimeError("firestore down")

    monkeypatch.setattr(mirror, "_voice_context_doc", boom)
    ctx = voice_actions.read_call_context(object(), "u9", window)
    assert (ctx.member, ctx.page) == ("", "")
    assert ctx.turns == (("user", "hello"),)
    # And a broken window still yields a context, never an error.
    ctx = voice_actions.read_call_context(object(), "u9", None)
    assert ctx.turns == ()


def test_response_schema_pins_the_closed_action_enum():
    schema = voice_actions.RESPONSE_SCHEMA
    assert schema["required"] == ["action"]
    assert schema["properties"]["action"]["enum"] == list(
        voice_actions.ACTIONS
    )
    assert "refuse" not in " ".join(voice_actions.ACTIONS)


def test_registry_models_destination_is_the_page_itself():
    """The Models-fact guard at the registry level: the models aliases
    resolve to ``voice_preference`` (/settings/voice) — never to its
    Settings parents. If this ever fails, the registry (not the skill)
    needs the correction the chunk calls for."""
    for phrase in (
        "open up the AMA models page",
        "open the models page",
        "take me to Ayma's models",
    ):
        dest = app_registry.find_destination(phrase)
        assert dest is not None and dest["key"] == "voice_preference", phrase
        assert dest["path"] == "/settings/voice"
