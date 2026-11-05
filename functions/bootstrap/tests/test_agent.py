"""Agent worker wiring checks (Step 13).

The live audio round-trip (worker joins a LiveKit room, audio flows both ways
with Gemini Live) needs a real-time client and is verified manually per the
PLAN Step 13 test line. These checks cover only what can run offline: that the
worker is importable, its entrypoint is async, and the Gemini Live model id +
voice come from ``config.py`` rather than a hardcoded literal (AGENTS.md).

Skipped unless the agent dependency set (``requirements-agent.txt``) is
installed — the Main API venv deliberately does not carry it.
"""

import asyncio
import dataclasses
import inspect
import json

import pytest

pytest.importorskip("livekit.agents")

import agent  # noqa: E402
from config import CONFIG  # noqa: E402


def test_entrypoint_is_async():
    assert inspect.iscoroutinefunction(agent.entrypoint)


def _capture_inference_realtime(monkeypatch):
    """Capture the kwargs ``build_inference_realtime_model`` passes to the
    gateway RealtimeModel (voice runs only through LiveKit Inference)."""
    from livekit.agents import inference

    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(inference, "RealtimeModel", _FakeRealtimeModel)
    return captured


def test_realtime_model_uses_config_model_id(monkeypatch):
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model()

    assert captured["model"] == CONFIG.inference_live_model
    assert captured["voice"] == CONFIG.gemini_live_voice
    # Only the knobs the gateway protocol carries — no temperature,
    # compression, transcription configs or native-audio flags.
    assert set(captured) == {"model", "voice", "turn_detection"}


def test_realtime_model_uses_a_valid_voice_preference(monkeypatch):
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model("Charon")
    assert captured["voice"] == "Charon"


def test_realtime_model_falls_back_for_an_unknown_voice(monkeypatch):
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model("NotARealPreset")
    assert captured["voice"] == CONFIG.gemini_live_voice


def test_cascade_tts_voice_matches_persona_gender(monkeypatch):
    # With default config the cascade (Fish Audio) TTS must pick a gender-matched
    # voice: female personas sound female, male personas sound male. Load a
    # fresh config with the override env vars cleared so we exercise the
    # config.py defaults (Hannah / Adrian), not whatever the ambient env sets.
    # Fish Audio voices are addressed by id, so these are the documented ids.
    import config as config_module

    hannah = "9a9cf47702da476aa4629e2506d4a857"  # feminine
    adrian = "bf322df2096a46f18c579d0baa36f41d"  # masculine

    for var in (
        "META_CASCADE_TTS_VOICE",
        "META_CASCADE_TTS_VOICE_FEMALE",
        "META_CASCADE_TTS_VOICE_MALE",
    ):
        monkeypatch.delenv(var, raising=False)
    default_cfg = config_module._load()
    monkeypatch.setattr(agent, "CONFIG", default_cfg)

    assert agent._cascade_tts_voice_for_gender("female") == hannah
    assert agent._cascade_tts_voice_for_gender("woman") == hannah
    assert agent._cascade_tts_voice_for_gender("male") == adrian
    assert agent._cascade_tts_voice_for_gender("man") == adrian
    # Non-binary / unknown / unset gender falls back to the base default voice,
    # which now defaults to Hannah (the founder's selected default voice).
    assert agent._cascade_tts_voice_for_gender("non-binary") == hannah
    assert agent._cascade_tts_voice_for_gender("") == hannah
    assert agent._cascade_tts_voice_for_gender(None) == hannah


def test_room_seed_carries_the_voice_name():
    seed_json = json.dumps({
        "system_prompt": "p",
        "recent_turns": [],
        "uid": "u1",
        "session_id": "s1",
        "voice_name": "Zephyr",
    })

    class _Room:
        metadata = seed_json

    class _Ctx:
        room = _Room()

    assert agent._read_room_seed(_Ctx()).voice_name == "Zephyr"


_TURN_DETECTION_ENVS = (
    "GEMINI_LIVE_PREFIX_PADDING_MS",
    "GEMINI_LIVE_SILENCE_DURATION_MS",
)


def _clear_turn_detection_envs(monkeypatch):
    for name in _TURN_DETECTION_ENVS:
        monkeypatch.delenv(name, raising=False)


def test_realtime_model_tunes_gateway_server_vad_by_default(monkeypatch):
    """Anti-false-trigger VAD tuning: by default the gateway session carries
    server-VAD with 300ms prefix padding and 700ms end-of-speech silence."""
    _clear_turn_detection_envs(monkeypatch)
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model()

    vad = captured["turn_detection"]
    assert vad.prefix_padding_ms == 300
    assert vad.silence_duration_ms == 700


def test_turn_detection_knobs_are_env_tunable(monkeypatch):
    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_PREFIX_PADDING_MS", "150")
    monkeypatch.setenv("GEMINI_LIVE_SILENCE_DURATION_MS", "1000")
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model()

    vad = captured["turn_detection"]
    assert vad.prefix_padding_ms == 150
    assert vad.silence_duration_ms == 1000


def test_turn_detection_all_defaults_leaves_fields_unset(monkeypatch):
    """Every knob set to "default" leaves the fields unset — the gateway
    server default applies."""
    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_PREFIX_PADDING_MS", "default")
    monkeypatch.setenv("GEMINI_LIVE_SILENCE_DURATION_MS", "default")
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model()

    vad = captured["turn_detection"]
    assert vad.prefix_padding_ms is None
    assert vad.silence_duration_ms is None


def test_turn_detection_invalid_env_values_fall_back(monkeypatch):
    """Garbage env values must never take voice down: bad int values fall
    back to the shipped defaults (with a warning), not raise."""
    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_PREFIX_PADDING_MS", "abc")
    monkeypatch.setenv("GEMINI_LIVE_SILENCE_DURATION_MS", "-5")
    captured = _capture_inference_realtime(monkeypatch)
    agent.build_realtime_model()

    vad = captured["turn_detection"]
    assert vad.prefix_padding_ms == 300
    assert vad.silence_duration_ms == 700



def test_relay_transcripts_publishes_named_data_events():
    import asyncio

    handlers = {}
    published = []

    class _FakeSession:
        def on(self, name):
            def _register(fn):
                handlers[name] = fn
                return fn

            return _register

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _FakeRoom:
        local_participant = _FakeLocalParticipant()

    class _FakeCtx:
        room = _FakeRoom()

    class _Item:
        role = "assistant"
        text_content = "hello there"

    class _UserEv:
        transcript = "hi ayma"
        is_final = True

    class _ItemEv:
        item = _Item()

    async def _run():
        agent.relay_transcripts(_FakeCtx(), _FakeSession())
        handlers["user_input_transcribed"](_UserEv())
        handlers["conversation_item_added"](_ItemEv())
        await asyncio.sleep(0.05)  # let the fire-and-forget tasks run

    asyncio.run(_run())

    topics = {t for t, _, _ in published}
    assert topics == {"user_transcript", "agent_transcript"}
    user = next(p for t, p, _ in published if t == "user_transcript")
    assert user == {"text": "hi ayma", "is_final": True}


def test_relay_agent_state_publishes_speaking_state():
    import asyncio

    handlers = {}
    published = []

    class _FakeSession:
        def on(self, name):
            def _register(fn):
                handlers[name] = fn
                return fn

            return _register

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _FakeCtx:
        class room:  # noqa: N801
            local_participant = _FakeLocalParticipant()

    class _StateEv:
        def __init__(self, new_state):
            self.new_state = new_state

    async def _run():
        agent.relay_agent_state(_FakeCtx(), _FakeSession())
        handlers["agent_state_changed"](_StateEv("speaking"))
        handlers["agent_state_changed"](_StateEv("listening"))
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert published == [
        ("agent_state", {"state": "speaking"}),
        ("agent_state", {"state": "listening"}),
    ]


def test_realtime_model_always_builds_on_livekit_inference(monkeypatch):
    """The direct-Google voice branch is gone (founder rule 2026-11-04):
    ``build_realtime_model`` always delegates to the Inference builder —
    whatever the route override, USE_VERTEX or GEMINI_LIVE_USE_DEV_API say."""
    seen = {}

    def _fake_inference_builder(voice, model=None):
        seen["voice"] = voice
        seen["model"] = model
        return "INFERENCE_MODEL"

    monkeypatch.setattr(
        agent, "build_inference_realtime_model", _fake_inference_builder
    )
    monkeypatch.setattr(
        agent,
        "CONFIG",
        dataclasses.replace(
            CONFIG, use_vertex=True, gemini_live_use_dev_api=True
        ),
    )
    monkeypatch.setenv("GOOGLE_API_KEY", "k-123")

    for route in ("inference", "vertex", None):
        seen.clear()
        assert agent.build_realtime_model("Charon", route=route) == (
            "INFERENCE_MODEL"
        )
        assert seen == {"voice": "Charon", "model": None}

    # An invalid voice preset still resolves to the configured default.
    assert agent.build_realtime_model("Nope") == "INFERENCE_MODEL"
    assert seen["voice"] == CONFIG.gemini_live_voice


def test_realtime_model_has_no_direct_google_auth_left():
    """The google plugin model, the genai types and the Vertex/dev knobs are
    gone from the worker — there is nothing left to aim at Google."""
    assert not hasattr(agent, "RealtimeModel")
    assert not hasattr(agent, "types")
    assert not hasattr(agent, "_turn_detection_config")


def test_worker_health_server_leaves_cloud_run_port_to_keepalive(monkeypatch):
    monkeypatch.setenv("PORT", "8080")
    monkeypatch.delenv("AGENT_WORKER_HEALTH_PORT", raising=False)
    opts = agent.worker_options()
    assert opts.port == 8081
    server = agent.AymaAgentServer.from_server_options(opts)
    assert isinstance(server, agent.AymaAgentServer)


class _NullRoom:
    class local_participant:  # noqa: N801
        @staticmethod
        async def publish_data(*a, **k):
            pass


class _NullCtx:
    room = _NullRoom()


def test_session_tools_come_from_the_shared_registry():
    from livekit.agents import llm

    import skills
    from skills import app_control

    assert agent._session_tools(_NullCtx(), "") == []  # no uid -> no tools

    tools = agent._session_tools(_NullCtx(), "u1")
    # The shared text registry, the always-on story edit/remove tools, plus the
    # voice-only screen-awareness tools.
    assert len(tools) == (
        len(skills.all_skills())
        + len(skills._STORY_MANAGE_REGISTRY)
        + len(app_control.VOICE_SKILLS)
    )
    assert all(llm.is_function_tool(t) for t in tools)
    # Ayma can edit/soft-remove the user's own story on a call, not only in text.
    assert {"edit_story_entry", "remove_story_entry"} <= {t.info.name for t in tools}


def test_voice_tools_include_recall_only_at_level_3(monkeypatch):
    """Cost-program Phase 3: the recall(topic) tool is registered on the Live
    voice session's tool set at CONTEXT_OPT_LEVEL>=3, and absent below."""
    def _names(tools):
        return {t.info.name for t in tools}

    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    assert "recall" not in _names(agent._session_tools(_NullCtx(), "u1"))

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    tools = agent._session_tools(_NullCtx(), "u1")
    assert "recall" in _names(tools)


# --- tool_used data-channel events (§1.7 step 3) --------------------------


def test_publish_tool_event_uses_the_working_and_settled_labels():
    import asyncio

    from tool_labels import tool_label, working_label

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    async def _run():
        agent._publish_tool_event(_Ctx(), "start", "deep_dive")
        agent._publish_tool_event(_Ctx(), "end", "deep_dive")
        await asyncio.sleep(0.05)  # let the fire-and-forget tasks run

    asyncio.run(_run())

    assert published == [
        (
            "tool_used",
            {"name": "deep_dive", "label": working_label("deep_dive"), "phase": "start"},
            True,
        ),
        (
            "tool_used",
            {"name": "deep_dive", "label": tool_label("deep_dive"), "phase": "end"},
            True,
        ),
    ]


def test_publish_tool_event_end_prefers_the_outcome_label():
    import asyncio

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append(json.loads(payload)["label"])

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    async def _run():
        agent._publish_tool_event(_Ctx(), "end", "send_dm_message", 'Sent to Jo: "hi"')
        await asyncio.sleep(0.05)

    asyncio.run(_run())
    assert published == ['Sent to Jo: "hi"']


def test_publish_tool_event_swallows_a_publish_failure():
    import asyncio

    class _FailingParticipant:
        @staticmethod
        async def publish_data(*a, **k):
            raise RuntimeError("data channel closed")

    class _Room:
        local_participant = _FailingParticipant()

    class _Ctx:
        room = _Room()

    async def _run():
        agent._publish_tool_event(_Ctx(), "start", "deep_dive")
        await asyncio.sleep(0.05)

    asyncio.run(_run())  # must not raise


def test_session_tools_wire_every_tool_call_to_a_tool_used_event(monkeypatch):
    """agent._session_tools passes an on_call hook into
    skills.make_livekit_tools; verify it publishes a matching start/end
    tool_used event for whichever tool actually calls it — exercising the
    real wiring end to end without needing a live LiveKit tool invocation."""
    import asyncio

    import skills
    from tool_labels import tool_label, working_label

    captured = {}

    def _fake_make_livekit_tools(
        db, uid, *, on_call=None, on_voice_change=None, voice_pref=None,
        guard=None, session_id="", turns=None, dedupe=None,
    ):
        captured["on_call"] = on_call
        captured["session_id"] = session_id
        captured["turns"] = turns
        captured["dedupe"] = dedupe
        return ["tool-stub"]

    monkeypatch.setattr(skills, "make_livekit_tools", _fake_make_livekit_tools)

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    window = [agent.Turn("user", "hi")]
    tools = agent._session_tools(_Ctx(), "u1", session_id="s-1", window=window)
    assert tools == ["tool-stub"]
    on_call = captured["on_call"]
    assert on_call is not None
    # send_dm_message gets the session and the live window (it grows).
    assert captured["session_id"] == "s-1"
    window.append(agent.Turn("user", "yes"))
    assert [t.text for t in captured["turns"]()] == ["hi", "yes"]

    async def _run():
        on_call("start", "record_feedback", None)
        on_call("end", "record_feedback", None)
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert [p[1]["phase"] for p in published] == ["start", "end"]
    assert published[0][1] == {
        "name": "record_feedback",
        "label": working_label("record_feedback"),
        "phase": "start",
    }
    assert published[1][1] == {
        "name": "record_feedback",
        "label": tool_label("record_feedback"),
        "phase": "end",
    }


class _FakeRoom:
    def __init__(self, metadata):
        self.metadata = metadata


class _FakeCtx:
    def __init__(self, metadata):
        self.room = _FakeRoom(metadata)


def test_read_room_seed_builds_chat_ctx_and_ids():
    raw = json.dumps(
        {
            "system_prompt": "PERSONA + history",
            "uid": "u1",
            "session_id": "sess-abc",
            "recent_turns": [
                {"role": "user", "text": "started by voice"},
                {"role": "ayma", "text": "keep going"},
            ],
        }
    )
    seed = agent._read_room_seed(_FakeCtx(raw))

    assert seed.system_prompt == "PERSONA + history"
    assert seed.uid == "u1"
    assert seed.session_id == "sess-abc"
    assert [m.role for m in seed.chat_ctx.items] == ["user", "assistant"]
    assert [t.role for t in seed.seed_turns] == ["user", "ayma"]


def _forty_turn_seed_json():
    return json.dumps(
        {
            "system_prompt": "PERSONA",
            "uid": "u1",
            "session_id": "sess-abc",
            "recent_turns": [
                {
                    "role": "user" if i % 2 == 0 else "ayma",
                    "text": f"voice turn {i}",
                }
                for i in range(40)
            ],
        }
    )


def test_read_room_seed_trims_the_chat_ctx_at_level_2(monkeypatch):
    """Cost-program Phase 2 voice seed diet: the Live model's chat context is
    seeded with only the last CONTEXT_OPT_VOICE_TAIL_TURNS turns, while
    seed_turns — the raw_turns persistence base — still carries the full
    window (shrinking it would overwrite the session doc with less history)."""
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    seed = agent._read_room_seed(_FakeCtx(_forty_turn_seed_json()))
    assert len(seed.chat_ctx.items) == 10
    assert seed.chat_ctx.items[-1].text_content == "voice turn 39"
    assert seed.chat_ctx.items[0].text_content == "voice turn 30"
    assert len(seed.seed_turns) == 40  # persistence base untouched


def test_read_room_seed_keeps_the_full_chat_ctx_at_level_0(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    seed = agent._read_room_seed(_FakeCtx(_forty_turn_seed_json()))
    assert len(seed.chat_ctx.items) == 40
    assert len(seed.seed_turns) == 40


def test_read_room_seed_falls_back_without_metadata():
    seed = agent._read_room_seed(_FakeCtx(None))
    assert seed.chat_ctx is None
    assert seed.system_prompt and not seed.uid

    seed2 = agent._read_room_seed(_FakeCtx("not json"))
    assert seed2.chat_ctx is None
    assert seed2.system_prompt


# --- shutdown-persist skipped for a room nothing new was said in ----------


def test_has_new_turns_false_when_window_is_only_the_seed():
    """A room a client never really connected to (e.g. an ICE-handshake
    timeout, or an abandoned retry) still has `window` seeded from
    `/bootstrap`'s `recent_turns` — this must read as "nothing new" so
    `entrypoint`'s shutdown hook skips re-ingesting already-persisted history."""
    from transcript import ROLE_AYMA, ROLE_USER, Turn

    seed_turns = [Turn(ROLE_USER, "hi"), Turn(ROLE_AYMA, "hey there")]
    window = list(seed_turns)
    assert agent._has_new_turns(window, len(seed_turns)) is False

    # A real turn actually exchanged in this room's own conversation flips it.
    window.append(Turn(ROLE_USER, "actually said something this time"))
    assert agent._has_new_turns(window, len(seed_turns)) is True


def test_has_new_turns_true_from_a_fresh_room_with_no_seed():
    from transcript import ROLE_USER, Turn

    window: list[Turn] = []
    assert agent._has_new_turns(window, 0) is False
    window.append(Turn(ROLE_USER, "first thing ever said"))
    assert agent._has_new_turns(window, 0) is True


# --- leaked tool-call artifact stripped from the spoken transcript --------


def test_strip_leaked_tool_artifact_removes_the_glued_prefix():
    # The exact founder-reported garble: a real, verbatim tool name
    # (read_dm_thread) glued into unrelated tokens, immediately followed by
    # Ayma's real, intended reply with no separator.
    leaked = (
        "activalerts_read_dm_threadactivationspeech Ah, you know, my voice "
        "is more for talking, not singing. I wouldn't want to scare you off."
    )
    cleaned = agent._strip_leaked_tool_artifact(leaked)
    assert cleaned == (
        "Ah, you know, my voice is more for talking, not singing. I "
        "wouldn't want to scare you off."
    )


def test_strip_leaked_tool_artifact_leaves_genuine_text_alone():
    normal = "Ah, you know, my voice is more for talking, not singing."
    assert agent._strip_leaked_tool_artifact(normal) == normal
    # A long leading word alone isn't enough — it must also contain a real
    # registered tool name, or genuine text could get clipped by mistake.
    long_word = "supercalifragilisticexpialidocious is a fun word to say."
    assert agent._strip_leaked_tool_artifact(long_word) == long_word


def test_strip_leaked_tool_artifact_removes_the_structured_prefix():
    # The exact founder-reported garble: a structured "key:value" narration
    # of the function call/response, punctuated rather than one glued word.
    leaked = (
        "response:set_voice_preference{output:saved default voice:Ah, "
        "okay! My ears are playing tricks on me. What's up, though?"
    )
    cleaned = agent._strip_leaked_tool_artifact(leaked)
    assert cleaned == (
        "Ah, okay! My ears are playing tricks on me. What's up, though?"
    )


def test_strip_leaked_tool_artifact_structured_needs_a_real_tool_name():
    # Same colon-then-capital shape, but no registered tool name in it —
    # must be left alone (a genuine reply could plausibly look like this).
    normal = "quick note:Something worth flagging for later."
    assert agent._strip_leaked_tool_artifact(normal) == normal


def test_relay_transcripts_strips_a_leaked_tool_artifact_before_relay():
    import asyncio

    handlers = {}
    published = []

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn

            return _reg

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _FakeRoom:
        local_participant = _FakeLocalParticipant()

    class _FakeCtx:
        room = _FakeRoom()

    class _Item:
        role = "assistant"
        text_content = (
            "activalerts_read_dm_threadactivationspeech Ah, you know, my "
            "voice is more for talking, not singing."
        )

    class _ItemEv:
        item = _Item()

    collected: list = []

    async def _run():
        agent.relay_transcripts(_FakeCtx(), _FakeSession(), collector=collected)
        handlers["conversation_item_added"](_ItemEv())
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    expected = "Ah, you know, my voice is more for talking, not singing."
    payload = next(p for t, p in published if t == "agent_transcript")
    assert payload["text"] == expected
    assert "read_dm_thread" not in payload["text"]
    assert [t.text for t in collected] == [expected]


# --- "shut up" muting -------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "shut up",
        "Ayma shut up",
        "shut up please",
        "be quiet",
        "stay quiet",
        "quiet please",
        "stop talking",
        "stop talking now",
        "stop speaking",
        "stop responding",
        "go silent",
        "silence",
        "shush",
        "shhh",
        "hush",
        "zip it",
        "could you please just stop talking now",  # 7 words, still short
    ],
)
def test_is_mute_trigger_matches_short_imperatives(text):
    assert agent._is_mute_trigger(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "",
        "   ",
        "I need some quiet time at home this weekend",
        "I told him to shut up but he wouldn't listen to me at all",
        "what's your favorite quiet place to relax",
        "hello there",
        "tell me about silent movies from the 1920s",
    ],
)
def test_is_mute_trigger_ignores_unrelated_or_long_sentences(text):
    assert agent._is_mute_trigger(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "Ayma",
        "ayma",
        "AYMA are you there",
        "okay Ayma you can talk now",
        "sorry, Ayma, are you there?",
        "hey ayma",
        "Aima",
        "okay Aimma you can talk now",
        "Aymar are you there",
        "aimar",
        "aymma",
        "hey ayema",
        "ayuma",
        "amya come back",
        "a ima, you can talk",
        "hey ima",
        "ay ma can you hear me",
        "Emma, you can talk now",
        "ema",
        "amma",
    ],
)
def test_addresses_ayma_matches_direct_mentions(text):
    assert agent._addresses_ayma(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "",
        "hello there",
        "what time is it",
        "aymara is a language spoken in the Andes",  # substring, not the word
        "I aim to send an image of my mama",
        "she said I'm a man",
        "that is a map of the area",
        "ok please be quiet for a while",
    ],
)
def test_addresses_ayma_ignores_non_mentions(text):
    assert agent._addresses_ayma(text) is False


class _FakeSpeechHandle:
    def __init__(self):
        self.interrupted = False
        self.interrupt_calls = []

    def interrupt(self, *, force=False):
        self.interrupted = True
        self.interrupt_calls.append(force)
        return self


class _SpeechCreatedEv:
    def __init__(self, speech_handle):
        self.speech_handle = speech_handle


class _UserFinalEv:
    def __init__(self, transcript, is_final=True):
        self.transcript = transcript
        self.is_final = is_final


class _FakeMuteSession:
    def __init__(self):
        self._handlers = {}

    def on(self, name):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register

    def user_turn(self, transcript, is_final=True):
        self._handlers["user_input_transcribed"](_UserFinalEv(transcript, is_final))

    def speech_created(self):
        handle = _FakeSpeechHandle()
        self._handlers["speech_created"](_SpeechCreatedEv(handle))
        return handle


def test_relay_mute_control_mutes_on_trigger_and_suppresses_the_reply():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("Ayma, shut up")
    assert state.muted is True

    handle = session.speech_created()
    assert handle.interrupted is True
    assert handle.interrupt_calls == [True]


def test_relay_mute_control_unmutes_only_on_direct_callout():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("shut up")
    assert state.muted is True

    # An unrelated turn while muted stays muted and its reply is suppressed.
    session.user_turn("what's the weather like")
    assert state.muted is True
    handle = session.speech_created()
    assert handle.interrupted is True

    # Calling her out by name unmutes.
    session.user_turn("okay Ayma, you there?")
    assert state.muted is False

    # The unmuting turn's own reply is NOT suppressed.
    handle2 = session.speech_created()
    assert handle2.interrupted is False


def test_relay_mute_control_publishes_every_mute_transition():
    import asyncio

    published = []

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _FakeCtx:
        class room:  # noqa: N801
            local_participant = _FakeLocalParticipant()

            @staticmethod
            def on(_name, _fn):
                return _fn

    async def _run():
        state = agent.MuteState()
        session = _FakeMuteSession()
        agent.relay_mute_control(session, state, _FakeCtx())
        session.user_turn("what's the weather")
        session.user_turn("Ayma, shut up")
        session.user_turn("unrelated chatter while muted")
        session.user_turn("Ayma, are you there?")
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert published == [
        ("agent_mute", {"muted": True}),
        ("agent_mute", {"muted": False}),
    ]


class _FakeMuteRoom:
    """Room double for the app -> agent ``agent_mute_control`` path: records
    every ``agent_mute`` publish and lets a test fire room events."""

    def __init__(self):
        self.published = []
        self.handlers = {}
        room = self

        class _LocalParticipant:
            async def publish_data(self, payload, *, reliable, topic):
                room.published.append((topic, json.loads(payload)))

        self.local_participant = _LocalParticipant()

    def on(self, name, fn):
        self.handlers[name] = fn
        return fn


class _Packet:
    def __init__(self, topic, payload):
        self.topic = topic
        self.data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()


def _mute_ctx():
    room = _FakeMuteRoom()

    class _Ctx:
        pass

    ctx = _Ctx()
    ctx.room = room
    return ctx, room


def test_mute_control_message_unmutes_and_echoes_the_state():
    import asyncio

    async def _run():
        ctx, room = _mute_ctx()
        state = agent.MuteState()
        session = _FakeMuteSession()
        agent.relay_mute_control(session, state, ctx)
        session.user_turn("shut up")
        assert state.muted is True

        room.handlers["data_received"](
            _Packet("agent_mute_control", {"muted": False})
        )
        assert state.muted is False
        # Her next reply plays again.
        assert session.speech_created().interrupted is False
        await asyncio.sleep(0.05)
        return room.published

    assert asyncio.run(_run()) == [
        ("agent_mute", {"muted": True}),
        ("agent_mute", {"muted": False}),
    ]


def test_mute_control_ignores_other_topics_bad_payloads_and_mute_requests():
    import asyncio

    async def _run():
        ctx, room = _mute_ctx()
        state = agent.MuteState()
        session = _FakeMuteSession()
        agent.relay_mute_control(session, state, ctx)
        session.user_turn("shut up")
        on_data = room.handlers["data_received"]
        on_data(_Packet("user_transcript", {"muted": False}))
        on_data(_Packet("agent_mute_control", b"not json"))
        on_data(_Packet("agent_mute_control", {"other": 1}))
        assert state.muted is True
        # Muting is a spoken command only; a tap request to mute is refused
        # but the authoritative state is still echoed.
        on_data(_Packet("agent_mute_control", {"muted": True}))
        assert state.muted is True
        assert session.speech_created().interrupted is True
        await asyncio.sleep(0.05)
        return room.published

    assert asyncio.run(_run()) == [
        ("agent_mute", {"muted": True}),
        ("agent_mute", {"muted": True}),
    ]


def test_mute_state_is_republished_when_a_participant_rejoins():
    import asyncio

    async def _run():
        ctx, room = _mute_ctx()
        state = agent.MuteState()
        session = _FakeMuteSession()
        agent.relay_mute_control(session, state, ctx)
        session.user_turn("be quiet")
        room.handlers["participant_connected"](object())
        await asyncio.sleep(0.05)
        return room.published

    assert asyncio.run(_run()) == [
        ("agent_mute", {"muted": True}),
        ("agent_mute", {"muted": True}),
    ]


def test_say_ayma_still_unmutes_with_the_control_channel_wired():
    import asyncio

    async def _run():
        ctx, room = _mute_ctx()
        state = agent.MuteState()
        session = _FakeMuteSession()
        agent.relay_mute_control(session, state, ctx)
        session.user_turn("shut up")
        session.user_turn("Ayma, come back")
        assert state.muted is False
        await asyncio.sleep(0.05)
        return room.published

    assert asyncio.run(_run())[-1] == ("agent_mute", {"muted": False})


def test_relay_mute_control_ignores_interim_transcripts():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("shut", is_final=False)
    assert state.muted is False


def test_relay_mute_control_normal_conversation_is_never_touched():
    """No trigger, never muted: speech_created must not be interrupted —
    normal (non-muted) voice behavior is completely unaffected."""
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("hey Ayma, how's it going")
    assert state.muted is False
    handle = session.speech_created()
    assert handle.interrupted is False
    assert handle.interrupt_calls == []


def test_relay_mute_control_long_sentence_containing_trigger_words_does_not_mute():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("I told him to shut up but he wouldn't listen to me at all")
    assert state.muted is False


def test_relay_transcripts_collects_finalized_turns():
    import asyncio

    handlers = {}

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn

            return _reg

    class _FakeCtx:
        class room:  # noqa: N801
            class local_participant:  # noqa: N801
                @staticmethod
                async def publish_data(*a, **k):
                    pass

    class _UserEv:
        def __init__(self, transcript, is_final):
            self.transcript = transcript
            self.is_final = is_final

    class _Item:
        role = "assistant"
        text_content = "hi from ayma"

    class _ItemEv:
        item = _Item()

    collected: list = []

    async def _run():
        agent.relay_transcripts(_FakeCtx(), _FakeSession(), collector=collected)
        handlers["user_input_transcribed"](_UserEv("partial", False))
        handlers["user_input_transcribed"](_UserEv("hey ayma", True))
        handlers["conversation_item_added"](_ItemEv())
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    assert [(t.role, t.text) for t in collected] == [
        ("user", "hey ayma"),
        ("ayma", "hi from ayma"),
    ]


# --- Guided-tour narration must not persist (§11.2b, founder/Scout 2026-11-03) ---


def _tour_relay_harness():
    """Shared fakes for the TourNarrationGate relay tests."""
    handlers: dict = {}

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn

            return _reg

    class _FakeCtx:
        class room:  # noqa: N801
            class local_participant:  # noqa: N801
                @staticmethod
                async def publish_data(*a, **k):
                    pass

    class _UserEv:
        def __init__(self, transcript, is_final):
            self.transcript = transcript
            self.is_final = is_final

    def _item(text):
        class _I:
            role = "assistant"
            text_content = text

        class _Ev:
            item = _I()

        return _Ev()

    return handlers, _FakeSession, _FakeCtx, _UserEv, _item


def test_relay_transcripts_drops_guided_tour_narration():
    """A guided-tour tool ran (gate.pending), so the assistant turn it produces
    is ephemeral tour narration — it must NOT be relayed or collected into the
    raw_turns window; a normal turn right after is kept."""
    import asyncio

    handlers, _FakeSession, _FakeCtx, _UserEv, _item = _tour_relay_harness()
    collected: list = []
    gate = agent.TourNarrationGate()

    async def _run():
        agent.relay_transcripts(
            _FakeCtx(), _FakeSession(), collector=collected, tour_gate=gate)
        gate.pending = True  # a guided-tour tool just ran this turn
        handlers["conversation_item_added"](
            _item("Now tap Explore to meet people."))  # narration -> dropped
        handlers["conversation_item_added"](
            _item("Sure, here's that."))  # normal reply -> kept
        await asyncio.sleep(0.01)

    asyncio.run(_run())
    assert [(t.role, t.text) for t in collected] == [("ayma", "Sure, here's that.")]
    assert gate.pending is False


def test_a_new_user_turn_resets_the_tour_gate():
    """If a tour tool ran but produced no narration, a new user turn resets the
    latch so a later normal reply is not wrongly dropped."""
    import asyncio

    handlers, _FakeSession, _FakeCtx, _UserEv, _item = _tour_relay_harness()
    collected: list = []
    gate = agent.TourNarrationGate()

    async def _run():
        agent.relay_transcripts(
            _FakeCtx(), _FakeSession(), collector=collected, tour_gate=gate)
        gate.pending = True
        handlers["user_input_transcribed"](_UserEv("ok what now", True))  # resets
        handlers["conversation_item_added"](_item("Here's the thing."))  # kept
        await asyncio.sleep(0.01)

    asyncio.run(_run())
    assert gate.pending is False
    assert [(t.role, t.text) for t in collected] == [
        ("user", "ok what now"),
        ("ayma", "Here's the thing."),
    ]


def test_session_tools_latch_tour_gate_only_on_guided_tour_tools(monkeypatch):
    """_session_tools' on_call hook arms the TourNarrationGate on a guided-tour
    tool start and leaves it alone for any other tool."""
    import asyncio

    import skills

    def _fake_make_livekit_tools(db, uid, *, on_call=None, **k):
        _fake_make_livekit_tools.on_call = on_call
        return ["tool-stub"]

    monkeypatch.setattr(skills, "make_livekit_tools", _fake_make_livekit_tools)

    class _Ctx:
        class room:  # noqa: N801
            class local_participant:  # noqa: N801
                @staticmethod
                async def publish_data(*a, **k):
                    pass

    gate = agent.TourNarrationGate()
    agent._session_tools(_Ctx(), "u1", tour_gate=gate)
    on_call = _fake_make_livekit_tools.on_call

    async def _run():
        on_call("start", "record_feedback", None)  # a normal tool — no latch
        assert gate.pending is False
        on_call("start", "advance_guided_tour", None)  # tour tool — latch armed
        await asyncio.sleep(0.01)

    asyncio.run(_run())
    assert gate.pending is True


def test_tour_tapped_handler_drives_advance_on_the_topic_only():
    """The voice tap bridge (§11.2b): a `tour_tapped` data packet fires one
    generate_reply (which makes the model call advance_guided_tour); any other
    topic is ignored."""
    import asyncio

    calls = []

    class _FakeSession:
        def generate_reply(self, *, instructions):
            calls.append(instructions)

            async def _noop():
                return None

            return _noop()

    class _Packet:
        def __init__(self, topic):
            self.topic = topic
            self.data = b'{"index": 1}'

    async def _run():
        handler = agent.tour_tapped_handler(_FakeSession())
        handler(_Packet("some_other_topic"))  # ignored
        assert calls == []
        handler(_Packet(agent.TOPIC_TOUR_TAPPED))  # drives the advance
        await asyncio.sleep(0.01)

    asyncio.run(_run())
    assert len(calls) == 1
    assert "advance_guided_tour" in calls[0]


# --- §F3 mid-call credit cap (founder cost bug, 2026-09-21) ----------------
#
# Root cause: credits were checked only once, at /bootstrap (session token
# mint) — nothing during the live call ever checked again, so a call that
# started in the black could run unbounded once usage crossed into zero/
# negative mid-call. `relay_token_usage` now re-checks the same
# `token_ledger.check` every other credit-gated call site already uses, right
# after each turn's usage is recorded, and fires `on_credits_exhausted` once.


class _FakeAggValue:
    def __init__(self, n):
        self.value = n


class _FakeEventsCol:
    """The `users/{uid}/spend_events` subcollection slice token_ledger.add
    touches: add(), count().get(), order_by().limit().stream()."""

    def __init__(self):
        self.added = []

    def add(self, data):
        self.added.append(dict(data))

    def count(self):
        col = self

        class _Agg:
            def get(self):
                return [[_FakeAggValue(len(col.added))]]

        return _Agg()

    def order_by(self, *_a, **_k):
        return self

    def limit(self, _n):
        return self

    def stream(self):
        return iter(())


class _FakeDocRef:
    def __init__(self):
        self.sets = []
        self.events = _FakeEventsCol()

    def set(self, payload, merge=False):  # noqa: FBT002 - matches real API
        self.sets.append((payload, merge))

    def collection(self, _name):
        return self.events


class _FakeCollRef:
    def __init__(self):
        self.doc = _FakeDocRef()

    def document(self, _uid):
        return self.doc


class _FakeDb:
    """Stands in for the Firestore client in these tests — the real ledger
    write inside `relay_token_usage` (now `token_ledger.add`) is exercised in
    test_token_ledger; here we only need it to not touch the network while we
    drive the credit-cap trigger via a monkeypatched `token_ledger.check`.
    Patched onto BOTH `agent.get_db` and `token_ledger.get_db` since the
    per-turn write goes through token_ledger.add."""

    def __init__(self):
        self.coll = _FakeCollRef()

    def collection(self, _name):
        return self.coll


def _fake_metrics(*, total=150, input_tokens=100, output_tokens=50):
    from livekit.agents.metrics import RealtimeModelMetrics

    return RealtimeModelMetrics(
        request_id="r1",
        timestamp=0.0,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total,
        input_token_details=RealtimeModelMetrics.InputTokenDetails(),
        output_token_details=RealtimeModelMetrics.OutputTokenDetails(),
    )


class _FakeMetricsSession:
    def __init__(self):
        self._handlers = {}

    def on(self, name):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register

    def fire(self, metrics):
        class _Ev:
            pass

        ev = _Ev()
        ev.metrics = metrics
        self._handlers["metrics_collected"](ev)


def test_relay_token_usage_triggers_callback_once_credits_are_exhausted(
    monkeypatch,
):
    import asyncio

    import token_ledger

    _db = _FakeDb()
    monkeypatch.setattr(agent, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "get_db", lambda: _db)

    def _raise_capped(_uid):
        raise token_ledger.TokenCapExceeded("out of credits (uid=u1)")

    monkeypatch.setattr(token_ledger, "check", _raise_capped)

    session = _FakeMetricsSession()
    calls = []

    async def _on_exhausted():
        calls.append(True)

    agent.relay_token_usage(
        session, "u1", on_credits_exhausted=_on_exhausted
    )

    async def _run():
        session.fire(_fake_metrics())
        # A second turn landing before the async callback above is awaited
        # elsewhere must not fire it again.
        session.fire(_fake_metrics())
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert calls == [True]


def test_relay_token_usage_does_not_trigger_while_credits_remain(monkeypatch):
    import asyncio

    import token_ledger

    _db = _FakeDb()
    monkeypatch.setattr(agent, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "check", lambda _uid: None)

    session = _FakeMetricsSession()
    calls = []

    async def _on_exhausted():
        calls.append(True)

    agent.relay_token_usage(
        session, "u1", on_credits_exhausted=_on_exhausted
    )

    async def _run():
        session.fire(_fake_metrics())
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert calls == []


def test_relay_token_usage_without_callback_is_unaffected(monkeypatch):
    """No `on_credits_exhausted` passed (e.g. the pre-sign-in welcome room,
    which never carries a uid) — same as before this change, no crash."""
    import asyncio

    import token_ledger

    _db = _FakeDb()
    monkeypatch.setattr(agent, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "get_db", lambda: _db)

    session = _FakeMetricsSession()
    agent.relay_token_usage(session, "u1")

    async def _run():
        session.fire(_fake_metrics())
        await asyncio.sleep(0.05)

    asyncio.run(_run())  # must not raise


def test_relay_token_usage_records_each_turn_through_the_ledger_with_session_id(
    monkeypatch,
):
    """Each Live turn's write goes through token_ledger.add carrying this
    call's session_id and the actual Live model — that's what groups a voice
    call's spend events into one "Voice call" row on the Credits screen's
    Real money tab (founder request 2026-09-26)."""
    import asyncio

    import token_ledger

    recorded = []
    monkeypatch.setattr(
        token_ledger, "add",
        lambda uid, feature, tokens, **kw: recorded.append(
            (uid, feature, tokens, kw)
        ),
    )

    session = _FakeMetricsSession()
    agent.relay_token_usage(session, "u1", session_id="room-42")

    async def _run():
        session.fire(
            _fake_metrics(total=150, input_tokens=100, output_tokens=50)
        )
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    assert recorded == [(
        "u1", token_ledger.FEATURE_VOICE, 150,
        {
            "input_tokens": 100,
            "output_tokens": 50,
            "model": token_ledger.live_model_id(),
            "session_id": "room-42",
            "provider": token_ledger.provider_for(token_ledger.FEATURE_VOICE),
        },
    )]


def test_publish_call_ending_sends_the_reason():
    import asyncio

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    asyncio.run(agent._publish_call_ending(_Ctx(), "out_of_credits"))

    assert published == [
        ("call_ending", {"reason": "out_of_credits"}, True)
    ]


def test_publish_call_ending_swallows_a_publish_failure():
    import asyncio

    class _FailingParticipant:
        @staticmethod
        async def publish_data(*a, **k):
            raise RuntimeError("data channel closed")

    class _Room:
        local_participant = _FailingParticipant()

    class _Ctx:
        room = _Room()

    asyncio.run(agent._publish_call_ending(_Ctx(), "out_of_credits"))  # no raise


def test_out_of_credits_instructions_match_the_shared_text_chat_wording():
    """Voice's spoken goodbye reuses the exact same sentence the text-chat
    `showOutOfCreditsSnack`/out-of-credits surfaces already use, instead of a
    separately hand-typed line that could drift from it."""
    import token_ledger

    expected = token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT)
    assert expected in agent._OUT_OF_CREDITS_INSTRUCTIONS


# --- SessionFlush (exactly-once memory write) + end_call_out_of_credits ---


def test_session_flush_calls_persist_and_ingest_exactly_once(monkeypatch):
    import asyncio

    from transcript import ROLE_USER, Turn

    calls = []

    async def _fake_persist_and_ingest(db, uid, session_id, turns, **_kw):
        calls.append((db, uid, session_id, list(turns)))

    monkeypatch.setattr(agent, "persist_and_ingest", _fake_persist_and_ingest)

    window = [Turn(ROLE_USER, "hi")]
    flush = agent.SessionFlush(object(), "u1", "sess-1", window)

    async def _run():
        await flush.run()
        await flush.run()  # second call is a no-op — no second LLM spend

    asyncio.run(_run())

    assert len(calls) == 1
    assert calls[0][1:3] == ("u1", "sess-1")
    assert flush.done is True


def test_session_flush_is_a_noop_without_uid_session_or_turns(monkeypatch):
    import asyncio

    calls = []

    async def _fake_persist_and_ingest(*a, **k):
        calls.append(a)

    monkeypatch.setattr(agent, "persist_and_ingest", _fake_persist_and_ingest)

    asyncio.run(agent.SessionFlush(object(), "", "sess-1", []).run())
    asyncio.run(agent.SessionFlush(object(), "u1", "", []).run())
    asyncio.run(agent.SessionFlush(object(), "u1", "sess-1", []).run())

    assert calls == []


def test_session_flush_started_on_close_is_awaited_by_the_shutdown_run(
    monkeypatch,
):
    """2026-10-25 production kill: the flush starts the moment the session
    closes, and the later shutdown callback (``run``) must wait for that
    same in-flight write, not return early and let the process exit."""
    import asyncio

    from transcript import ROLE_USER, Turn

    release = None
    calls = []

    async def _slow_persist_and_ingest(*a, **_kw):
        calls.append(a[1:3])
        await release.wait()

    monkeypatch.setattr(agent, "persist_and_ingest", _slow_persist_and_ingest)
    flush = agent.SessionFlush(object(), "u1", "sess-1", [Turn(ROLE_USER, "hi")])

    async def _run():
        nonlocal release
        release = asyncio.Event()
        flush.start()  # session "close" event
        shutdown = asyncio.create_task(flush.run())  # job shutdown callback
        await asyncio.sleep(0.01)
        assert not shutdown.done()  # still waiting on the in-flight flush
        release.set()
        await asyncio.wait_for(shutdown, timeout=1)

    asyncio.run(_run())
    assert calls == [("u1", "sess-1")]


def test_session_flush_logs_start_and_end_even_when_the_flush_raises(
    monkeypatch, caplog,
):
    import asyncio
    import logging

    from transcript import ROLE_USER, Turn

    async def _boom(*a, **k):
        raise RuntimeError("firestore down")

    monkeypatch.setattr(agent, "persist_and_ingest", _boom)
    flush = agent.SessionFlush(object(), "u1", "sess-1", [Turn(ROLE_USER, "hi")])
    with caplog.at_level(logging.INFO):
        asyncio.run(flush.run())  # must not raise during shutdown
    text = caplog.text
    assert "session-flush start uid=u1 session=sess-1" in text
    assert "session-flush end uid=u1 session=sess-1 duration_ms=" in text


def test_worker_options_give_the_flush_a_safe_shutdown_window(monkeypatch):
    monkeypatch.delenv("AGENT_SHUTDOWN_PROCESS_TIMEOUT", raising=False)
    opts = agent.worker_options()
    # The library default (10 s) killed the flush mid wiki ingest.
    assert opts.shutdown_process_timeout >= 60
    assert opts.prewarm_fnc is agent.prewarm


def test_prewarm_imports_modules_and_tolerates_a_missing_one(monkeypatch):
    import sys

    monkeypatch.setattr(
        agent, "_PREWARM_MODULES", ("json", "definitely_not_a_module_xyz")
    )
    agent.prewarm(object())  # must not raise
    assert "json" in sys.modules


def test_end_call_out_of_credits_flushes_speaks_signals_then_shuts_down(
    monkeypatch,
):
    """The founder-required sequence (2026-09-21): memory write -> spoken
    goodbye -> tell the client why -> disconnect. Never an abrupt cutoff."""
    import asyncio

    order = []

    async def _flush():
        order.append("flush")

    class _FakeHandle:
        def __await__(self):
            async def _impl():
                order.append("goodbye_played")
                return self

            return _impl().__await__()

    class _FakeSession:
        def generate_reply(self, *, instructions, allow_interruptions):
            order.append(("generate_reply", allow_interruptions))
            assert "out of credits" in instructions.lower()
            return _FakeHandle()

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            order.append("call_ending_published")
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _FakeCtx:
        room = _Room()

        @staticmethod
        def shutdown(reason):
            order.append(("shutdown", reason))

    asyncio.run(
        agent.end_call_out_of_credits(_FakeCtx(), _FakeSession(), "u1", _flush)
    )

    assert order == [
        "flush",
        ("generate_reply", False),
        "goodbye_played",
        "call_ending_published",
        ("shutdown", "out_of_credits"),
    ]
    assert published == [("call_ending", {"reason": "out_of_credits"}, True)]


def test_end_call_out_of_credits_still_ends_the_call_if_the_goodbye_fails(
    monkeypatch,
):
    """A stuck/failed TTS goodbye must never leave a broke user's call
    running — the call still ends and the client still gets told why."""
    import asyncio

    class _FakeSession:
        def generate_reply(self, **_kwargs):
            raise RuntimeError("Live session already closing")

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    shutdown_calls = []

    class _FakeCtx:
        room = _Room()

        @staticmethod
        def shutdown(reason):
            shutdown_calls.append(reason)

    flushed = []

    async def _flush():
        flushed.append(True)

    asyncio.run(
        agent.end_call_out_of_credits(_FakeCtx(), _FakeSession(), "u1", _flush)
    )

    assert flushed == [True]
    assert shutdown_calls == ["out_of_credits"]
    assert published == [("call_ending", {"reason": "out_of_credits"}, True)]


def test_end_call_out_of_credits_still_ends_the_call_if_the_flush_fails():
    """A failed memory write is logged, not fatal — the call must still end
    rather than hang open because Firestore hiccupped."""
    import asyncio

    async def _flush():
        raise RuntimeError("firestore write failed")

    class _FakeHandle:
        def __await__(self):
            async def _impl():
                return self

            return _impl().__await__()

    class _FakeSession:
        def generate_reply(self, **_kwargs):
            return _FakeHandle()

    class _Participant:
        @staticmethod
        async def publish_data(*a, **k):
            pass

    class _Room:
        local_participant = _Participant()

    shutdown_calls = []

    class _FakeCtx:
        room = _Room()

        @staticmethod
        def shutdown(reason):
            shutdown_calls.append(reason)

    asyncio.run(
        agent.end_call_out_of_credits(_FakeCtx(), _FakeSession(), "u1", _flush)
    )

    assert shutdown_calls == ["out_of_credits"]


_UNSET = object()


class _OpenerSession(_FakeMuteSession):
    def __init__(self):
        super().__init__()
        self.replies = []
        self.reply_chat_ctxs = []
        self.reply_user_inputs = []
        self.said = []

    async def generate_reply(self, instructions=None, chat_ctx=_UNSET,
                             user_input=_UNSET):
        self.replies.append(instructions)
        self.reply_chat_ctxs.append(chat_ctx)
        self.reply_user_inputs.append(user_input)

    def say(self, text):
        self.said.append(text)
        return _SpeechHandleStub(None)


class _SpeechHandleStub:
    """Mimics livekit-agents' SpeechHandle: awaiting it never raises, even on
    failure — a generation error only surfaces via exception()."""

    def __init__(self, error=None):
        self._error = error

    def __await__(self):
        async def _done():
            return None

        return _done().__await__()

    def exception(self):
        return self._error


class _StateEv:
    def __init__(self, new_state):
        self.new_state = new_state


def _opener_seed(**kw):
    return agent.RoomSeed(system_prompt="p", **kw)


async def _run_opener(session, seed, window, user_event=None):
    import asyncio

    task = asyncio.create_task(
        agent.maybe_open_conversation(
            session, seed, window=window, grace_seconds=0.05
        )
    )
    await asyncio.sleep(0.01)
    if user_event:
        user_event()
    return await task


class _ProfileDb:
    """Minimal Firestore fake: every collection/document hop returns self,
    and the terminal get() yields a snapshot over the canned profile."""

    def __init__(self, data):
        self._data = data

    def collection(self, _name):
        return self

    def document(self, _id):
        return self

    def get(self):
        data = self._data

        class _Snap:
            def to_dict(self):
                return data

        return _Snap()


def _arm_profile(monkeypatch, data):
    monkeypatch.setattr(agent, "get_db", lambda: _ProfileDb(data))


def test_opener_fires_when_user_is_silent(monkeypatch):
    """Fresh session, silent caller: the opener fires exactly once — the
    spoken name greeting — and generates NO reply at all."""
    import asyncio

    _arm_profile(monkeypatch, {"name": "Suhail Pallath Sulaiman"})
    s = _OpenerSession()
    assert asyncio.run(_run_opener(s, _opener_seed(uid="u1"), [])) is True
    assert s.said == ["Hey Suhail."]
    assert s.replies == []


def test_opener_suppressed_when_user_speaks_first_by_vad():
    import asyncio

    s = _OpenerSession()
    fired = asyncio.run(
        _run_opener(s, _opener_seed(), [],
                    lambda: s._handlers["user_state_changed"](_StateEv("speaking")))
    )
    assert fired is False and s.replies == []


def test_opener_suppressed_when_user_transcript_arrives_first():
    import asyncio

    s = _OpenerSession()
    fired = asyncio.run(
        _run_opener(s, _opener_seed(), [], lambda: s.user_turn("hey", is_final=False))
    )
    assert fired is False and s.replies == []


def test_opener_skipped_for_welcome_greeting():
    import asyncio

    s = _OpenerSession()
    seed = _opener_seed(greeting_instructions="say hi")
    assert asyncio.run(_run_opener(s, seed, [])) is False
    assert s.replies == []


def test_opener_prior_context_never_recapped(monkeypatch):
    """Founder ruling (2026-11-03 23:06): even WITH a prior conversation,
    a fresh session opens with just the name greeting — no "pick up where
    we left off", no topic reference, no generated text of any kind."""
    import asyncio

    _arm_profile(monkeypatch, {"name": "Suhail Pallath Sulaiman"})
    s = _OpenerSession()
    seed = _opener_seed(
        uid="u1",
        seed_turns=[
            agent.Turn(role=agent.ROLE_USER, text="should I text Priya back"),
            agent.Turn(role=agent.ROLE_AYMA, text="whether to text Priya back"),
        ],
    )
    assert asyncio.run(_run_opener(s, seed, [])) is True
    assert s.said == ["Hey Suhail."]
    assert s.replies == []


def test_opener_dangling_tail_still_opens_with_name_greeting(monkeypatch):
    """A history ending on an UNANSWERED caller turn used to open by
    answering it (founder behaviour 2026-11-02); the 2026-11-03 ruling
    supersedes that for the opening line — the dangling message stays in
    context for the caller's first real turn, unanswered by the opener."""
    import asyncio

    _arm_profile(monkeypatch, {"name": "Suhail Pallath Sulaiman"})
    s = _OpenerSession()
    turns = [agent.Turn(role=agent.ROLE_USER, text="so about friday")]
    seed = _opener_seed(uid="u1", seed_turns=turns)
    assert asyncio.run(_run_opener(s, seed, list(turns))) is True
    assert s.said == ["Hey Suhail."]
    assert s.replies == []


def test_opener_greets_when_dangling_tail_is_blank():
    """A blank trailing caller turn takes the same greeting path — one
    spoken greeting, no generated reply, never silence."""
    import asyncio

    s = _OpenerSession()
    turns = [agent.Turn(role=agent.ROLE_USER, text="   ")]
    seed = _opener_seed(seed_turns=turns)
    assert asyncio.run(_run_opener(s, seed, list(turns))) is True
    assert s.said == ["Hey there."]
    assert s.replies == []


def test_opener_greeting_falls_back_without_a_profile_name(monkeypatch):
    """No name on the profile: the greeting degrades to a plain
    "Hey there." — never a fabricated name, never silence."""
    import asyncio

    _arm_profile(monkeypatch, {})
    s = _OpenerSession()
    assert asyncio.run(_run_opener(s, _opener_seed(uid="u1"), [])) is True
    assert s.said == ["Hey there."]


def test_opener_greeting_survives_a_profile_read_error(monkeypatch):
    """A failing profile read cannot cost the greeting (or the call)."""
    import asyncio

    class _BoomDb:
        def collection(self, _name):
            raise RuntimeError("firestore down")

    monkeypatch.setattr(agent, "get_db", lambda: _BoomDb())
    s = _OpenerSession()
    assert asyncio.run(_run_opener(s, _opener_seed(uid="u1"), [])) is True
    assert s.said == ["Hey there."]


_SAY_UNSUPPORTED = (
    "trying to generate speech from text without a TTS model or a "
    "RealtimeSession that supports say(); add a TTS model to "
    "AgentSession to enable say()"
)


class _RealtimeOpenerSession(_OpenerSession):
    """A Gemini Live-shaped session (founder bug, 2026-11-03): no TTS and
    a realtime model whose capabilities.supports_say is False, so
    session.say() raises the livekit-agents RuntimeError synchronously -
    exactly what a fresh Gemini Live start hits in the opener."""

    def say(self, text):
        raise RuntimeError(_SAY_UNSUPPORTED)


class _HandleErrorOpenerSession(_OpenerSession):
    """say() returns a handle whose failure only surfaces via
    exception() - the swallowed-failure shape."""

    def say(self, text):
        return _SpeechHandleStub(RuntimeError(_SAY_UNSUPPORTED))


def test_opener_falls_back_to_generate_reply_when_say_raises(monkeypatch):
    """Fresh realtime start path: say() is unsupported, so the name
    greeting rides generate_reply under the say-exactly-this instruction.
    Without this the call produces no first response at all - and the app
    holds the caller's mic until one lands, so the call never connects
    (it sits on "Connecting..." until the first-response guard fires)."""
    import asyncio

    _arm_profile(monkeypatch, {"name": "Daniel Reyes"})
    s = _RealtimeOpenerSession()
    assert asyncio.run(_run_opener(s, _opener_seed(uid="u1"), [])) is True
    assert len(s.replies) == 1
    assert '"Hey Daniel."' in s.replies[0]
    assert "word for word" in s.replies[0]


def test_opener_falls_back_when_say_handle_carries_the_error(monkeypatch):
    """The say() failure can also arrive only via the handle's
    exception() - same fallback."""
    import asyncio

    _arm_profile(monkeypatch, {"name": "Daniel Reyes"})
    s = _HandleErrorOpenerSession()
    assert asyncio.run(_run_opener(s, _opener_seed(uid="u1"), [])) is True
    assert len(s.replies) == 1
    assert '"Hey Daniel."' in s.replies[0]


def test_opener_fails_only_when_say_and_generate_reply_both_fail(monkeypatch):
    """Both speech paths dead: the opener reports failure (and the call's
    own guards take it from there) instead of pretending it spoke."""
    import asyncio

    class _DeadSession(_RealtimeOpenerSession):
        async def generate_reply(self, instructions=None, chat_ctx=_UNSET,
                                 user_input=_UNSET):
            raise RuntimeError("realtime session not established")

    _arm_profile(monkeypatch, {"name": "Daniel Reyes"})
    s = _DeadSession()
    assert asyncio.run(_run_opener(s, _opener_seed(uid="u1"), [])) is False


def test_command_claim_gate_speaks_via_generate_reply_when_say_raises():
    """Same root cause mid-call: on a say()-less realtime session the
    claim gate's honest line falls back to generate_reply under the
    say-exactly-this instruction instead of being silently dropped."""

    class _Sess:
        def __init__(self):
            self.replies = []

        def say(self, _text):
            raise RuntimeError(_SAY_UNSUPPORTED)

        def generate_reply(self, instructions=None, **_k):
            self.replies.append(instructions)

    s = _Sess()
    gate = agent._CommandClaimGate(s)
    gate.note_failure()
    assert len(s.replies) == 1
    assert agent._COMMAND_NOT_CONFIRMED_LINE in s.replies[0]


def test_opener_skipped_when_someone_already_spoke():
    import asyncio

    s = _OpenerSession()
    window = []

    async def go():
        import asyncio as a

        t = a.create_task(
            agent.maybe_open_conversation(
                s, _opener_seed(), window=window, grace_seconds=0.05
            )
        )
        await a.sleep(0.01)
        window.append(agent.Turn(role=agent.ROLE_AYMA, text="hi"))
        return await t

    assert asyncio.run(go()) is False
    assert s.replies == []


def test_opener_disabled_by_zero_grace():
    import asyncio

    s = _OpenerSession()

    async def go():
        return await agent.maybe_open_conversation(
            s, _opener_seed(), window=[], grace_seconds=0
        )

    assert asyncio.run(go()) is False


def test_welcome_greeting_seeds_user_turn_on_cascade():
    """The pre-sign-in welcome greeting takes the same cascade guard: its
    generate_reply carries the synthetic user turn so it is never a system-only
    request, while its instruction is unchanged."""
    import asyncio
    from prompt import load_voice_session_seed

    s = _OpenerSession()
    seed = _opener_seed(greeting_instructions="greet warmly")
    asyncio.run(
        agent._open_main_call(s, seed, window=[], seed_user_turn=True)
    )
    assert s.replies == ["greet warmly"]
    assert s.reply_user_inputs == [load_voice_session_seed()]


def test_welcome_greeting_not_seeded_on_realtime():
    """Welcome greeting on a realtime session (seed_user_turn left False) stays
    unseeded — the realtime protocol accepts an opener with no user turn."""
    import asyncio

    s = _OpenerSession()
    seed = _opener_seed(greeting_instructions="greet warmly")
    asyncio.run(agent._open_main_call(s, seed, window=[]))
    assert s.replies == ["greet warmly"]
    assert s.reply_user_inputs == [_UNSET]


def _arm_reconnect_claim(monkeypatch, claimed):
    """Point the opener's reconnect claim at a canned answer."""
    import skills

    monkeypatch.setattr(agent, "get_db", lambda: object())
    monkeypatch.setattr(
        skills.set_model_stack, "claim_reconnect_announcement",
        lambda db, uid: claimed,
    )


def _recording_opener(monkeypatch):
    calls = []

    async def _fake_open(*args, **kwargs):
        calls.append((args, kwargs))

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)
    return calls


def test_reconnect_continuation_opens_with_the_back_line(monkeypatch):
    """A session that claims the reconnect announcement opens with the one
    "I'm back" line naming the stack it is running — and the generic
    opener never runs, so the line is spoken exactly once."""
    import asyncio

    _arm_reconnect_claim(monkeypatch, True)
    opener_calls = _recording_opener(monkeypatch)
    s = _OpenerSession()
    seed = _opener_seed(uid="u1")  # realtime, Gemini Live by default
    asyncio.run(agent._open_main_call(s, seed, window=[]))
    assert len(s.replies) == 1
    assert "reconnected" in s.replies[0]
    assert "Gemini Live" in s.replies[0]
    assert opener_calls == []


def test_reconnect_continuation_on_cascade_names_the_brain(monkeypatch):
    """Cascade continuation: the line names the brain and — like every
    cascade opener — carries the synthetic user turn so the chat LLM
    never gets a system-only request."""
    import asyncio
    from prompt import load_voice_session_seed

    _arm_reconnect_claim(monkeypatch, True)
    _recording_opener(monkeypatch)
    s = _OpenerSession()
    seed = _opener_seed(uid="u1", brain_id="meta-muse-spark")
    asyncio.run(
        agent._open_main_call(s, seed, window=[], seed_user_turn=True)
    )
    assert len(s.replies) == 1
    assert "Meta Muse Spark" in s.replies[0]
    assert s.reply_user_inputs == [load_voice_session_seed()]


def test_fresh_call_never_opens_with_the_back_line(monkeypatch):
    """No pending announcement (an ordinary fresh call): the claim declines
    and the normal opener path runs untouched — no "I'm back" line."""
    import asyncio

    _arm_reconnect_claim(monkeypatch, False)
    opener_calls = _recording_opener(monkeypatch)
    s = _OpenerSession()
    seed = _opener_seed(uid="u1")
    asyncio.run(agent._open_main_call(s, seed, window=[]))
    assert s.replies == []
    assert len(opener_calls) == 1


def test_reconnect_setup_label_names_the_running_stack():
    import voice_catalog

    seed = _opener_seed()
    assert agent._reconnect_setup_label(seed, cascade=False) == "Gemini Live"
    seed = _opener_seed(realtime_model_id=voice_catalog.REALTIME_OPENAI)
    assert agent._reconnect_setup_label(seed, cascade=False) == "OpenAI Realtime"
    seed = _opener_seed(brain_id=voice_catalog.BRAIN_META)
    assert agent._reconnect_setup_label(seed, cascade=True) == "Meta Muse Spark"
    seed = _opener_seed(brain_id=voice_catalog.BRAIN_OPEN_WEIGHTS)
    assert (
        agent._reconnect_setup_label(seed, cascade=True)
        == "Llama 3.1 8B (open weights)"
    )


def test_opener_prior_context_helper():
    """has-prior / last-topic-hint derivation for the opener signal."""
    assert agent._opener_prior_context([]) == (False, "")
    # Blank-text turns don't count as prior conversation.
    assert agent._opener_prior_context(
        [agent.Turn(role=agent.ROLE_AYMA, text="   ")]
    ) == (False, "")
    # The hint is the most recent real turn, whitespace-collapsed.
    has_prior, hint = agent._opener_prior_context(
        [
            agent.Turn(role=agent.ROLE_USER, text="tell me about her"),
            agent.Turn(role=agent.ROLE_AYMA, text="Priya  seemed\n keen"),
        ]
    )
    assert has_prior is True and hint == "Priya seemed keen"
    # A very long last turn is truncated to a one-line hint, not dumped whole.
    long_turn = [agent.Turn(role=agent.ROLE_AYMA, text="x " * 400)]
    has_prior, hint = agent._opener_prior_context(long_turn)
    assert has_prior is True
    assert len(hint) <= agent._OPENER_HINT_MAX_CHARS + 1  # +1 for the ellipsis


def test_opener_say_failure_falls_back_to_generate_reply():
    """A say that raises outright no longer fails the opener: the
    greeting falls back to generate_reply (the realtime-shaped failure -
    a fresh call produces no first response without it)."""
    import asyncio

    s = _OpenerSession()

    def boom(text):
        raise RuntimeError("x")

    s.say = boom
    assert asyncio.run(_run_opener(s, _opener_seed(), [])) is True
    assert len(s.replies) == 1
    assert '"Hey there."' in s.replies[0]


def test_opener_say_handle_error_falls_back_to_generate_reply():
    """A swallowed handle failure on the greeting say is not a successful
    open either - it falls back to generate_reply (exactly one say
    attempt, then the fallback speaks)."""
    import asyncio

    s = _OpenerSession()
    calls = []

    def say(text):
        calls.append(text)
        return _SpeechHandleStub(RuntimeError("timed out"))

    s.say = say
    assert asyncio.run(_run_opener(s, _opener_seed(), [])) is True
    assert calls == ["Hey there."]
    assert len(s.replies) == 1
    assert '"Hey there."' in s.replies[0]


# --- idle-timeout wiring -----------------------------------------------------


class _IdleRoom:
    def __init__(self):
        self.handlers = {}
        self.published = []
        self.local_participant = self

    def on(self, name, fn):
        self.handlers[name] = fn

    async def publish_data(self, payload, reliable=True, topic=""):
        self.published.append((topic, json.loads(payload)))


class _IdleCtx:
    def __init__(self):
        self.room = _IdleRoom()
        self.callbacks = []
        self.deleted = False
        self.shutdown_reason = None

    def add_shutdown_callback(self, fn):
        self.callbacks.append(fn)

    async def delete_room(self):
        self.deleted = True

    def shutdown(self, reason=""):
        self.shutdown_reason = reason


def test_watch_for_idle_ends_call_with_idle_timeout_reason():
    import asyncio

    async def _run():
        ctx, flushed = _IdleCtx(), []

        async def flush():
            flushed.append(True)

        agent.watch_for_idle(
            ctx, _FakeMuteSession(), "u1", flush, timeout_seconds=0.05
        )
        await asyncio.sleep(0.3)
        return ctx, flushed

    ctx, flushed = asyncio.run(_run())
    assert flushed == [True]
    assert ("call_ending", {"reason": "idle_timeout"}) in ctx.room.published
    assert ctx.deleted
    assert ctx.shutdown_reason == "idle_timeout"


def test_watch_for_idle_user_activity_keeps_call_alive():
    import asyncio

    async def _run():
        ctx, session = _IdleCtx(), _FakeMuteSession()

        async def flush():
            pass

        agent.watch_for_idle(ctx, session, "u1", flush, timeout_seconds=0.2)
        for _ in range(6):
            await asyncio.sleep(0.05)
            session.user_turn("hello", is_final=False)
        return ctx

    ctx = asyncio.run(_run())
    assert ctx.shutdown_reason is None


def test_watch_for_idle_disabled_when_timeout_is_zero():
    assert agent.watch_for_idle(_IdleCtx(), _FakeMuteSession(), "u1", None, 0) is None


def test_relay_token_usage_meters_inference_voice_with_provider(monkeypatch):
    """The Inference adapter emits the same RealtimeModelMetrics from
    response.done usage; the ledger write is priced on the Inference model id
    (the only voice model) and tagged per the session's provider flag."""
    import token_ledger

    for inference, want_provider in (
        (True, "livekit_inference"),
        (False, token_ledger.provider_for("voice")),
    ):
        want_model = token_ledger.live_model_id()
        assert want_model == CONFIG.inference_live_model
        seen = {}
        monkeypatch.setattr(
            token_ledger, "add", lambda *a, **kw: seen.update(kw=kw, args=a)
        )
        monkeypatch.setattr(token_ledger, "check", lambda _u: None)
        session = _FakeMetricsSession()
        agent.relay_token_usage(session, "u1", session_id="s1", inference=inference)
        session.fire(_fake_metrics(total=0, input_tokens=100, output_tokens=50))
        assert seen["args"][2] == 150
        assert seen["kw"]["provider"] == want_provider
        assert seen["kw"]["model"] == want_model
        assert seen["kw"]["input_tokens"] == 100


def test_build_realtime_model_route_override_selects_inference(monkeypatch):
    chosen = {}
    monkeypatch.setattr(
        agent, "build_inference_realtime_model",
        lambda v: chosen.setdefault("v", v) or "m",
    )
    agent.build_realtime_model("Charon", route="inference")
    assert chosen["v"] == "Charon"


# --- misheard-fragment tool guard (founder test 2026-10-26) ---------------


def test_misheard_fragment_guard_refuses_only_on_a_fresh_garbled_line():
    from transcript import ROLE_AYMA, ROLE_USER, Turn

    window = [Turn(ROLE_USER, "el número")]  # seeded from an earlier call
    guard = agent.misheard_fragment_guard(window, len(window), lambda: "")
    assert guard() is None  # nothing said in this call yet

    window.append(Turn(ROLE_USER, "murió"))
    assert guard() == agent._MISHEARD_TOOL_REFUSAL

    window.append(Turn(ROLE_AYMA, "Sorry, I didn't catch that."))
    assert guard() is None  # Ayma already answered since

    window.append(Turn(ROLE_USER, "Yeah, do it."))
    assert guard() is None  # a plain short confirmation still works


def test_misheard_fragment_guard_follows_the_callers_language():
    from transcript import ROLE_USER, Turn

    window: list = []
    language = {"pref": ""}
    guard = agent.misheard_fragment_guard(window, 0, lambda: language["pref"])
    window.append(Turn(ROLE_USER, "അതെ, ചെയ്യൂ"))
    assert guard() == agent._MISHEARD_TOOL_REFUSAL
    language["pref"] = "Malayalam mixed with English"
    assert guard() is None


def _drain_server(monkeypatch, active_jobs):
    from livekit.agents import AgentServer

    drained = []

    async def fake_drain(self, timeout=None):
        drained.append(timeout)

    monkeypatch.setattr(AgentServer, "drain", fake_drain)
    monkeypatch.setattr(
        agent.AymaAgentServer, "active_jobs", property(lambda self: active_jobs)
    )
    return agent.AymaAgentServer.from_server_options(agent.worker_options()), drained


def test_drain_with_active_calls_logs_and_reports(monkeypatch, caplog):
    reported = []
    monkeypatch.setattr(
        agent, "capture_message", lambda msg, **kw: reported.append((msg, kw))
    )
    server, drained = _drain_server(monkeypatch, ["job-a", "job-b"])
    asyncio.run(server.drain())
    assert drained, "the library drain (stop new jobs, finish active) must still run"
    assert "shutdown signal with active calls: active_jobs=2" in caplog.text
    assert reported == [(
        "ayma-agent got SIGTERM with active calls",
        {"tags": {"active_jobs": "2", "keepalive_holds": "0"}},
    )]


def test_drain_without_calls_does_not_report(monkeypatch):
    reported = []
    monkeypatch.setattr(
        agent, "capture_message", lambda msg, **kw: reported.append(msg)
    )
    server, drained = _drain_server(monkeypatch, [])
    asyncio.run(server.drain())
    assert drained and reported == []


def test_entrypoint_starts_keepalive_and_releases_it_on_shutdown(monkeypatch):
    events = []

    class FakeKeepAlive:
        def start(self):
            events.append("start")

        async def release(self):
            events.append("release")

    keepalive = FakeKeepAlive()
    monkeypatch.setattr(
        agent.CallKeepAlive, "for_job", classmethod(lambda cls, job_id: keepalive)
    )

    async def fake_run(ctx, ka):
        assert ka is keepalive and events == ["start"]
        raise RuntimeError("room seed timeout")

    monkeypatch.setattr(agent, "_run_session", fake_run)
    monkeypatch.setattr(agent, "capture_exception", lambda exc: None)

    class Ctx:
        class job:  # noqa: N801
            id = "job-1"

        def __init__(self):
            self.callbacks = []

        def add_shutdown_callback(self, cb):
            self.callbacks.append(cb)

    ctx = Ctx()
    with pytest.raises(RuntimeError):
        asyncio.run(agent.entrypoint(ctx))
    assert ctx.callbacks == [keepalive.release]
    asyncio.run(ctx.callbacks[0]())
    assert events == ["start", "release"]


# --- Practice Date voice (hackathon B) ------------------------------------- #
def test_read_room_seed_parses_practice_flag_and_persona():
    """The practice gate + persona identity travel on the room metadata; a
    normal (non-practice) seed leaves the flag off so the standard path runs."""
    raw = json.dumps(
        {
            "system_prompt": "PERSONA PROMPT",
            "uid": "u1",
            "session_id": "practice_abc",
            "recent_turns": [],
            "practice": True,
            "persona_name": "Maya",
            "persona_gender": "woman",
            "target_uid": "demo_practice_maya",
        }
    )
    seed = agent._read_room_seed(_FakeCtx(raw))
    assert seed.practice is True
    assert seed.persona_name == "Maya"
    assert seed.persona_gender == "woman"
    assert seed.target_uid == "demo_practice_maya"

    normal = agent._read_room_seed(
        _FakeCtx(json.dumps({"system_prompt": "AYMA", "uid": "u1", "recent_turns": []}))
    )
    assert normal.practice is False
    assert normal.persona_name == "" and normal.target_uid == ""
    assert normal.persona_gender == ""


def test_relay_practice_coach_publishes_a_side_hint_and_persists_turns(monkeypatch):
    """As the user speaks, an out-of-character coach nudge is published on the
    dedicated ``practice_coach`` topic (never spoken by the persona), and each
    finalized turn is appended to the practice session store for the debrief."""
    import practice_core
    import practice_llm
    import practice_seed
    from fake_firestore import FakeDb

    db = FakeDb()
    practice_seed.seed(db)
    session_id = practice_core.start_session(db, "viewer_uid", "demo_practice_maya")
    monkeypatch.setattr(agent, "get_db", lambda: db)

    async def fake_json(system, contents, schema, uid, feature):
        assert "Maya" in contents  # the name-only coach context is used
        return {"hint": "warm opener — now ask about her ceramics"}

    practice_llm.set_override(json=fake_json)

    handlers = {}
    published = []

    class _FakeSession:
        def on(self, name):
            def _register(fn):
                handlers[name] = fn
                return fn

            return _register

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _FakeCtxRoom:
        class room:  # noqa: N801
            local_participant = _FakeLocalParticipant()

    class _UserEv:
        transcript = "hey, your pottery is gorgeous"
        is_final = True

    class _Item:
        role = "assistant"
        text_content = "haha thanks!"

    class _ItemEv:
        item = _Item()

    try:
        async def _run():
            agent.relay_practice_coach(
                _FakeCtxRoom(),
                _FakeSession(),
                uid="viewer_uid",
                session_id=session_id,
                persona_name="Maya",
                persona_gender="woman",
                target_uid="demo_practice_maya",
            )
            handlers["user_input_transcribed"](_UserEv())
            handlers["conversation_item_added"](_ItemEv())
            await asyncio.sleep(0.05)  # let the fire-and-forget coach task run

        asyncio.run(_run())
    finally:
        practice_llm.clear_override()

    coach = [p for t, p in published if t == agent.TOPIC_PRACTICE_COACH]
    assert coach and "ceramics" in coach[0]["text"]

    stored = (
        db.collection("users")
        .document("viewer_uid")
        .collection(practice_core.PRACTICE_SESSIONS_COLLECTION)
        .document(session_id)
        .get()
        .to_dict()["turns"]
    )
    roles = [t["role"] for t in stored]
    assert practice_core.ROLE_USER in roles and practice_core.ROLE_MATCH in roles


# --- Practice-voice Meta cascade (LLM_PROVIDER_VOICE=meta, off by default) --- #


def _install_fake_cascade_plugins(monkeypatch):
    """Patch the livekit openai plugin + inference module the cascade builder
    imports, plus ``agent.AgentSession``, with constructor-recording fakes.
    Returns the dict every fake writes its kwargs into."""
    from livekit.plugins import openai as lk_openai
    from livekit.agents import inference

    captured: dict = {}

    class _FakeSTT:
        def __init__(self, **kwargs):
            captured["stt"] = kwargs

    class _FakeLLM:
        def __init__(self, **kwargs):
            captured["llm"] = kwargs

    class _FakeTTS:
        def __init__(self, **kwargs):
            captured["tts"] = kwargs

    class _FakeVAD:
        def __init__(self, **kwargs):
            captured["vad"] = kwargs

    class _FakeSession:
        def __init__(self, **kwargs):
            captured["session"] = kwargs

    # STT, TTS and VAD all ride the LiveKit Inference gateway; only the LLM leg
    # is Meta (via livekit-plugins-openai).
    monkeypatch.setattr(lk_openai, "LLM", _FakeLLM)
    monkeypatch.setattr(inference, "STT", _FakeSTT)
    monkeypatch.setattr(inference, "TTS", _FakeTTS)
    monkeypatch.setattr(inference, "VAD", _FakeVAD)
    # The inference-route brain (§13.9) builds via inference.LLM; capture it too.
    monkeypatch.setattr(inference, "LLM", _FakeLLM)
    monkeypatch.setattr(agent, "AgentSession", _FakeSession)
    return captured


def test_meta_cascade_requires_the_api_key(monkeypatch):
    monkeypatch.delenv("META_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="META_API_KEY"):
        agent.build_meta_cascade_session()


def test_meta_cascade_wires_config_models_and_reasoning(monkeypatch):
    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    agent.build_meta_cascade_session()

    # STT rides LiveKit Inference (Meta serves no working REST STT) with the
    # config model id — no Meta base_url/key, never Gemini.
    assert captured["stt"]["model"] == CONFIG.meta_cascade_stt_model
    assert "base_url" not in captured["stt"]
    assert "api_key" not in captured["stt"]
    # The LLM leg points at the Meta Model API with the config model id (no
    # hardcoded strings) and the real key; never Gemini.
    assert captured["llm"]["model"] == CONFIG.meta_chat_model
    assert captured["llm"]["base_url"] == CONFIG.meta_api_base_url
    assert captured["llm"]["api_key"] == "test-key"
    # Muse Spark is reasoning-only — minimal effort must be passed or replies
    # come back empty.
    assert captured["llm"]["reasoning_effort"] == CONFIG.meta_reasoning_effort
    # TTS vendor + VAD come from config, so the flag can reach them.
    assert captured["tts"]["model"] == CONFIG.meta_cascade_tts_model
    assert captured["vad"]["model"] == CONFIG.meta_cascade_vad_model
    # A full cascade: STT + LLM + TTS + VAD, not a RealtimeModel.
    assert set(captured["session"]) == {
        "stt", "llm", "tts", "vad", "allow_interruptions"
    }


def test_open_weights_cascade_brain_wires_endpoint(monkeypatch):
    import voice_catalog

    # Opt-in endpoint configured (prod leaves these unset → brain never offered).
    cfg = dataclasses.replace(
        CONFIG,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="meta-llama/Llama-3.1-8B-Instruct",
    )
    monkeypatch.setattr(agent, "CONFIG", cfg)
    monkeypatch.setattr(voice_catalog, "CONFIG", cfg)
    voice_catalog.clear_cache()
    monkeypatch.setenv("OPEN_WEIGHTS_API_KEY", "ow-secret")
    captured = _install_fake_cascade_plugins(monkeypatch)

    agent._build_cascade_brain(voice_catalog.BRAIN_OPEN_WEIGHTS)

    # LLM leg points at the self-hosted endpoint with the config model id (no
    # hardcoded strings), the env key, and NO reasoning_effort (not Muse Spark).
    assert captured["llm"]["base_url"] == "https://modal.example/v1"
    assert captured["llm"]["model"] == "meta-llama/Llama-3.1-8B-Instruct"
    assert captured["llm"]["api_key"] == "ow-secret"
    assert "reasoning_effort" not in captured["llm"]


def test_open_weights_cascade_brain_keyless_uses_sentinel(monkeypatch):
    import voice_catalog

    cfg = dataclasses.replace(
        CONFIG,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="llama",
    )
    monkeypatch.setattr(agent, "CONFIG", cfg)
    monkeypatch.setattr(voice_catalog, "CONFIG", cfg)
    voice_catalog.clear_cache()
    monkeypatch.delenv("OPEN_WEIGHTS_API_KEY", raising=False)
    captured = _install_fake_cascade_plugins(monkeypatch)

    agent._build_cascade_brain(voice_catalog.BRAIN_OPEN_WEIGHTS)
    # Keyless server: a non-credential sentinel so the OpenAI client is happy.
    assert captured["llm"]["api_key"] == "not-needed"


def test_open_weights_cascade_brain_throws_without_model(monkeypatch):
    import voice_catalog

    # Base URL set but OPEN_WEIGHTS_MODEL empty → throw (never substitute a
    # hardcoded id), so the caller falls safely back to Gemini Live.
    cfg = dataclasses.replace(
        CONFIG,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="",
    )
    monkeypatch.setattr(agent, "CONFIG", cfg)
    monkeypatch.setattr(voice_catalog, "CONFIG", cfg)
    voice_catalog.clear_cache()
    with pytest.raises(RuntimeError, match="OPEN_WEIGHTS_MODEL"):
        agent._build_cascade_brain(voice_catalog.BRAIN_OPEN_WEIGHTS)


def test_open_weights_cascade_session_survives_cold_start_and_warms(monkeypatch):
    """The open-weights cascade LLM leg must cover Modal's ~100s cold start:
    an explicit ``conn_options`` with the configured cold-start timeout (not the
    10s default that made the call never reply), fewer retries, and a warm-up
    fired on session build so the cold start begins at setup, not the first turn.
    """
    import voice_catalog

    cfg = dataclasses.replace(
        CONFIG,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="meta-llama/Llama-3.1-8B-Instruct",
        open_weights_cold_start_timeout_s=120.0,
    )
    monkeypatch.setattr(agent, "CONFIG", cfg)
    monkeypatch.setattr(voice_catalog, "CONFIG", cfg)
    voice_catalog.clear_cache()
    monkeypatch.setenv("OPEN_WEIGHTS_API_KEY", "ow-secret")
    captured = _install_fake_cascade_plugins(monkeypatch)
    warmed: list[bool] = []
    monkeypatch.setattr(
        agent, "_warm_open_weights_endpoint", lambda: warmed.append(True)
    )

    agent.build_cascade_session(
        voice_catalog.BRAIN_OPEN_WEIGHTS, "deepgram/nova-3", "fishaudio/s2.1-pro"
    )

    from livekit.agents.types import DEFAULT_API_CONNECT_OPTIONS

    conn = captured["session"]["conn_options"]
    assert conn.llm_conn_options.timeout == 120.0
    # Fewer attempts against a cold endpoint than the wasteful 4× default churn.
    assert conn.llm_conn_options.max_retry <= 1
    # STT/TTS legs are untouched — only the open-weights LLM leg gets the budget.
    assert conn.stt_conn_options.timeout == DEFAULT_API_CONNECT_OPTIONS.timeout
    assert warmed == [True]


def test_meta_cascade_session_keeps_default_conn_options(monkeypatch):
    """The Meta/Inference legs are always-on gateways — they must NOT get the
    open-weights cold-start timeout, and no Modal warm-up is fired for them."""
    import voice_catalog

    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)
    warmed: list[bool] = []
    monkeypatch.setattr(
        agent, "_warm_open_weights_endpoint", lambda: warmed.append(True)
    )

    agent.build_cascade_session(
        voice_catalog.BRAIN_META, "deepgram/nova-3", "fishaudio/s2.1-pro"
    )

    assert "conn_options" not in captured["session"]
    assert warmed == []


def test_publish_voice_status_sends_warming_on_its_topic():
    """The honest open-weights status rides its own data-channel topic with the
    warming state the client renders (not a silent 'Listening…')."""
    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    asyncio.run(
        agent._publish_voice_status(
            _Ctx(), agent.VOICE_STATUS_OPEN_WEIGHTS_WARMING
        )
    )
    assert published == [
        ("voice_status", {"state": "open_weights_warming"})
    ]


def test_meta_cascade_adds_tts_voice_only_when_configured(monkeypatch):
    import config

    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    # Explicitly empty voice → no "voice" key is added (the vendor default).
    # CONFIG is a frozen dataclass — reload it from env and swap agent.CONFIG.
    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "")
    monkeypatch.setattr(agent, "CONFIG", config._load())
    agent.build_meta_cascade_session()
    assert "voice" not in captured["tts"]

    # The config default voice (Hannah) IS passed through when the env is unset.
    monkeypatch.delenv("META_CASCADE_TTS_VOICE", raising=False)
    monkeypatch.setattr(agent, "CONFIG", config._load())
    agent.build_meta_cascade_session()
    assert captured["tts"]["voice"] == "9a9cf47702da476aa4629e2506d4a857"

    # A configured non-default voice is passed through — but it must be VALID for
    # the active TTS provider (the default model here is fishaudio/s2.1-pro), so
    # use a real Fish Audio voice id ("Adrian"); a cross-provider id is dropped to
    # the vendor default (see test_cascade_drops_cross_provider_voice_to_vendor_default).
    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "bf322df2096a46f18c579d0baa36f41d")
    monkeypatch.setattr(agent, "CONFIG", config._load())
    agent.build_meta_cascade_session()
    assert captured["tts"]["voice"] == "bf322df2096a46f18c579d0baa36f41d"


def test_meta_cascade_picks_the_gender_matched_tts_voice(monkeypatch):
    """A Practice Date persona's gender selects the matching cascade TTS voice
    from config (never a voice id hardcoded in agent.py); the MAIN path (no
    gender) and an unset gender voice both fall back to the configured default."""
    import config

    monkeypatch.setenv("META_API_KEY", "test-key")
    # Gender voices must be VALID for the active TTS provider, so this test runs
    # the cascade on Inworld (staging's TTS) with real Inworld voice names.
    monkeypatch.setenv("META_CASCADE_TTS_MODEL", "inworld/inworld-tts-1")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "Ashley")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE_FEMALE", "Olivia")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE_MALE", "Mark")
    monkeypatch.setattr(agent, "CONFIG", config._load())
    captured = _install_fake_cascade_plugins(monkeypatch)

    # Mirrors the entrypoint wiring: the persona gender resolves to a voice via
    # ``_cascade_tts_voice_for_gender`` which is forwarded as ``tts_voice``.
    def _session_for_gender(gender):
        return agent.build_meta_cascade_session(
            tts_voice=agent._cascade_tts_voice_for_gender(gender)
        )

    _session_for_gender("woman")
    assert captured["tts"]["voice"] == "Olivia"
    _session_for_gender("man")
    assert captured["tts"]["voice"] == "Mark"
    # Non-binary / unknown and the MAIN path (no gender) → the default voice.
    _session_for_gender("non-binary")
    assert captured["tts"]["voice"] == "Ashley"
    agent.build_meta_cascade_session()
    assert captured["tts"]["voice"] == "Ashley"


def test_meta_cascade_gender_voice_falls_back_when_unconfigured(monkeypatch):
    """When the gender-specific voice is explicitly blanked, gender matching
    falls back safely to the configured default voice rather than an invented
    id. (The config.py defaults are non-empty — Hannah / Adrian — so "unset"
    here means the operator cleared the env var to force the fallback.)"""
    import config

    monkeypatch.setenv("META_API_KEY", "test-key")
    monkeypatch.setenv("META_CASCADE_TTS_MODEL", "inworld/inworld-tts-1")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "Ashley")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE_FEMALE", "")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE_MALE", "")
    monkeypatch.setattr(agent, "CONFIG", config._load())
    captured = _install_fake_cascade_plugins(monkeypatch)

    agent.build_meta_cascade_session(
        tts_voice=agent._cascade_tts_voice_for_gender("woman")
    )
    assert captured["tts"]["voice"] == "Ashley"


def test_practice_gemini_session_uses_a_gender_matched_voice(monkeypatch):
    """The default (Gemini Live) practice path speaks in a voice matching the
    persona's gender; unknown gender falls back to the user's preference."""
    import voices

    captured = {}

    def _fake_build_realtime_model(voice_name=None, voice_language=None, route=None):
        captured["voice_name"] = voice_name
        return object()

    monkeypatch.setattr(agent, "build_realtime_model", _fake_build_realtime_model)
    monkeypatch.setattr(agent, "AgentSession", lambda **kw: kw)
    monkeypatch.setattr(agent.llm_routing, "route_for", lambda *a, **k: "gemini")

    female_seed = agent.RoomSeed(system_prompt="P", persona_gender="woman", practice=True)
    agent._build_practice_gemini_session(female_seed)
    assert captured["voice_name"] == voices.voice_for_gender("woman")

    # Unknown gender → fall back to the user's own saved preference.
    unknown_seed = agent.RoomSeed(
        system_prompt="P", persona_gender="", voice_name="Kore", practice=True
    )
    agent._build_practice_gemini_session(unknown_seed)
    assert captured["voice_name"] == "Kore"


class _FakePracticeSession:
    """A practice ``AgentSession`` stand-in: records the greeting and the
    ``close`` handler so a test can fire it."""

    def __init__(self):
        self._handlers = {}
        self.started = False
        self.greetings = []
        self.greeting_user_inputs = []

    def on(self, name, callback=None):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register(callback) if callback else _register

    async def start(self, **_kwargs):
        self.started = True

    async def generate_reply(self, instructions=None, user_input=None):
        self.greetings.append(instructions)
        self.greeting_user_inputs.append(user_input)

    def close(self, ev):
        self._handlers["close"](ev)


def _practice_ctx():
    class _Room:
        def __init__(self):
            self.handlers: dict = {}

        def on(self, event, cb=None):
            self.handlers.setdefault(event, []).append(cb)
            return cb

    class _Ctx:
        def __init__(self):
            self.room = _Room()

    return _Ctx()


def _stub_practice_relays(monkeypatch):
    for name in (
        "relay_transcripts", "relay_agent_state", "relay_cascade_usage",
        "relay_token_usage", "relay_practice_coach",
    ):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)


def test_start_practice_session_greets_first_in_character(monkeypatch):
    """The simulated match "picks up the phone" — an initial agent turn fires
    from the practice-greeting prompt file, not a hardcoded string."""
    _stub_practice_relays(monkeypatch)
    session = _FakePracticeSession()
    seed = agent.RoomSeed(system_prompt="persona", uid="u1", practice=True)

    asyncio.run(
        agent._start_practice_session(
            _practice_ctx(), seed, session, meta_cascade=True, use_inference=False
        )
    )

    assert session.started is True
    from prompt import load_practice_greeting, load_voice_session_seed
    assert session.greetings == [load_practice_greeting()]
    # Cascade (text LLM): the greeting carries a synthetic user turn so it is
    # never a system-only inference request (Sentry 400 regression).
    assert session.greeting_user_inputs == [load_voice_session_seed()]


def test_start_practice_session_greeting_not_seeded_on_realtime(monkeypatch):
    """On the Gemini Live / Inference realtime practice path the greeting is left
    unseeded — the realtime protocol accepts an opener with no prior user turn."""
    _stub_practice_relays(monkeypatch)
    session = _FakePracticeSession()
    seed = agent.RoomSeed(system_prompt="persona", uid="u1", practice=True)

    asyncio.run(
        agent._start_practice_session(
            _practice_ctx(), seed, session, meta_cascade=False, use_inference=True
        )
    )

    from prompt import load_practice_greeting
    assert session.greetings == [load_practice_greeting()]
    assert session.greeting_user_inputs == [None]


def test_cascade_runtime_error_falls_back_to_gemini_live(monkeypatch):
    """A built cascade that dies mid-call (CloseReason.ERROR) switches to a
    fresh Gemini Live practice session on the same room — no dead air."""
    from livekit.agents.voice.events import CloseEvent, CloseReason

    gemini = _FakePracticeSession()
    monkeypatch.setattr(
        agent, "_build_practice_gemini_session", lambda seed: (gemini, False)
    )
    started = []

    async def _fake_start(ctx, seed, session, *, meta_cascade, use_inference):
        started.append((session, meta_cascade))

    monkeypatch.setattr(agent, "_start_practice_session", _fake_start)

    cascade = _FakePracticeSession()
    seed = agent.RoomSeed(system_prompt="persona", uid="u1", practice=True)
    ctx = _practice_ctx()
    agent._arm_practice_cascade_fallback(ctx, seed, cascade)

    async def _drive(reason):
        cascade.close(CloseEvent(reason=reason))
        await asyncio.sleep(0)  # let the scheduled fallback task run

    # A clean close (user hung up) must NOT spin up a fallback.
    asyncio.run(_drive(CloseReason.USER_INITIATED))
    assert started == []

    # An error close switches to Gemini Live exactly once.
    asyncio.run(_drive(CloseReason.ERROR))
    assert started == [(gemini, False)]

    # A second error close does not fire a second fallback.
    asyncio.run(_drive(CloseReason.ERROR))
    assert started == [(gemini, False)]


def test_relay_cascade_usage_meters_llm_turns(monkeypatch):
    import token_ledger
    from livekit.agents.metrics import LLMMetrics

    recorded: dict = {}

    def _fake_add(uid, feature, tokens, **kwargs):
        recorded.update(
            uid=uid, feature=feature, tokens=tokens,
            model=kwargs.get("model"), session_id=kwargs.get("session_id"),
        )

    monkeypatch.setattr(token_ledger, "add", _fake_add)

    handlers: dict = {}

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn
            return _reg

    agent.relay_cascade_usage(
        _FakeSession(), "viewer_uid", session_id="s-practice", model="muse-spark-x",
    )

    class _Ev:
        metrics = LLMMetrics(
            type="llm_metrics", label="meta", request_id="r1",
            timestamp=0.0, duration=0.1, ttft=0.05, cancelled=False,
            completion_tokens=12, prompt_tokens=30, prompt_cached_tokens=0,
            total_tokens=42, tokens_per_second=10.0,
        )

    handlers["metrics_collected"](_Ev())
    assert recorded["feature"] == token_ledger.FEATURE_VOICE
    assert recorded["tokens"] == 42
    assert recorded["model"] == "muse-spark-x"
    assert recorded["session_id"] == "s-practice"


# --- MAIN voice provider switch (LLM_PROVIDER_VOICE_MAIN, default gemini) --- #


def _drive_main_run_session(
    monkeypatch, provider, *, build_raises=False, seed=None
):
    """Drive ``_run_session`` for a normal (non-practice) call with the MAIN
    voice flag set to ``provider``, stubbing the shared setup + both path
    builders so the test observes only which stack is selected. ``seed`` lets a
    test drive a per-user voice-stack selection (§13.9) instead of the flag."""
    import config
    import llm_routing
    import token_ledger

    monkeypatch.setenv("LLM_PROVIDER_VOICE_MAIN", provider)
    monkeypatch.setattr(agent, "CONFIG", config._load())

    if seed is None:
        seed = agent.RoomSeed(system_prompt="sys", uid="u1", session_id="s1")

    async def _fake_seed(_ctx):
        return seed

    monkeypatch.setattr(agent, "_await_room_seed", _fake_seed)
    monkeypatch.setattr(agent, "get_db", lambda: object())
    monkeypatch.setattr(llm_routing, "route_for", lambda *a, **k: "vertex")
    monkeypatch.setattr(
        token_ledger, "provider_for", lambda _f: "google_live"
    )

    class _FakeFlush:
        def __init__(self, *a, **k):
            pass

        async def run(self):
            pass

    monkeypatch.setattr(agent, "SessionFlush", _FakeFlush)

    calls: dict = {}

    def _build_cascade(*a, **_k):
        calls["built"] = True
        calls["cascade_args"] = a
        if build_raises:
            raise RuntimeError("META_API_KEY is not set")
        return "CASCADE_SESSION"

    monkeypatch.setattr(agent, "build_cascade_session", _build_cascade)
    monkeypatch.setattr(
        agent, "_arm_main_cascade_fallback",
        lambda *a, **k: calls.__setitem__("armed", True),
    )

    async def _fake_cascade_start(ctx, s, session, **k):
        calls["started"] = "cascade"
        calls["cascade_session"] = session

    async def _fake_gemini_start(ctx, s, **k):
        calls["started"] = "gemini"

    monkeypatch.setattr(agent, "_start_main_cascade_session", _fake_cascade_start)
    monkeypatch.setattr(agent, "_start_main_gemini_session", _fake_gemini_start)

    class _Ctx:
        async def connect(self):
            pass

        def add_shutdown_callback(self, _cb):
            pass

    class _KeepAlive:
        def hold_for(self, _cb):
            pass

    asyncio.run(agent._run_session(_Ctx(), _KeepAlive()))
    return calls


def test_main_voice_defaults_to_gemini_live(monkeypatch):
    """Default flag (gemini) → the main call still builds the Gemini Live path
    and never touches the Meta cascade: zero behaviour change."""
    calls = _drive_main_run_session(monkeypatch, "gemini")
    assert calls["started"] == "gemini"
    assert "built" not in calls
    assert "armed" not in calls


def test_main_voice_meta_builds_the_cascade(monkeypatch):
    """LLM_PROVIDER_VOICE_MAIN=meta → the main call builds the Meta cascade,
    arms the runtime fallback, and starts on the cascade session."""
    calls = _drive_main_run_session(monkeypatch, "meta")
    assert calls["built"] is True
    assert calls.get("armed") is True
    assert calls["started"] == "cascade"
    assert calls["cascade_session"] == "CASCADE_SESSION"


def test_main_voice_meta_build_failure_falls_back_to_gemini(monkeypatch):
    """A cascade that can't be built (no META_API_KEY) falls through to Gemini
    Live at start — a flip can never take the main voice down."""
    calls = _drive_main_run_session(monkeypatch, "meta", build_raises=True)
    assert calls["built"] is True
    assert calls["started"] == "gemini"
    assert "armed" not in calls


def test_start_main_cascade_session_meters_and_opens(monkeypatch):
    """The main cascade start meters via relay_cascade_usage (with the mid-call
    credit-cap callback), starts the session, and opens the call."""
    used: dict = {}

    def _fake_cascade_usage(session, uid, *, session_id="", model="",
                            on_credits_exhausted=None):
        used["model"] = model
        used["cap"] = on_credits_exhausted is not None

    monkeypatch.setattr(agent, "relay_cascade_usage", _fake_cascade_usage)
    for name in (
        "relay_transcripts", "relay_agent_state", "relay_mute_control",
        "watch_for_idle", "_session_tools", "relay_voice_commands",
    ):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)

    async def _fake_open(*_a, **_k):
        used["opened"] = True

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)
    monkeypatch.setattr(agent, "Agent", lambda **k: object())

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    session = _FakePracticeSession()
    seed = agent.RoomSeed(system_prompt="sys", uid="u1", session_id="s1")

    asyncio.run(
        agent._start_main_cascade_session(
            _practice_ctx(), seed, session, flush=_FakeFlush(), window=[],
        )
    )

    assert session.started is True
    assert used["model"] == CONFIG.meta_chat_model
    assert used["cap"] is True
    assert used["opened"] is True


def test_voice_stack_seed_cascade_overrides_default_flag(monkeypatch):
    """A per-user cascade selection (§13.9) builds the cascade with the user's
    component ids even though the deploy default (gemini) would be realtime."""
    seed = agent.RoomSeed(
        system_prompt="sys", uid="u1", session_id="s1",
        voice_mode="cascade", brain_id="google/gemini-3.7-flash",
        stt_id="deepgram/nova-3", tts_id="cartesia/sonic-3", tts_voice="Olivia",
    )
    calls = _drive_main_run_session(monkeypatch, "gemini", seed=seed)
    assert calls["started"] == "cascade"
    # build_cascade_session(brain, stt, tts, tts_voice, voice_language)
    assert calls["cascade_args"][:4] == (
        "google/gemini-3.7-flash", "deepgram/nova-3", "cartesia/sonic-3", "Olivia",
    )


def test_voice_stack_seed_realtime_openai_inert_falls_back(monkeypatch):
    """Selecting OpenAI Realtime while it's inert (flag off / no key) falls back
    to Gemini Live — a selection can never take the main voice down."""
    seed = agent.RoomSeed(
        system_prompt="sys", uid="u1", session_id="s1",
        voice_mode="realtime", realtime_model_id="openai-realtime",
    )
    calls = _drive_main_run_session(monkeypatch, "gemini", seed=seed)
    assert calls["started"] == "gemini"
    assert "built" not in calls


def test_build_openai_realtime_model_inert_without_flag_or_key(monkeypatch):
    import config

    monkeypatch.delenv("VOICE_OPENAI_REALTIME", raising=False)
    monkeypatch.setattr(agent, "CONFIG", config._load())
    assert agent.build_openai_realtime_model("echo") is None  # flag off

    monkeypatch.setenv("VOICE_OPENAI_REALTIME", "true")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(agent, "CONFIG", config._load())
    assert agent.build_openai_realtime_model("echo") is None  # key missing


def test_build_cascade_session_inference_brain_needs_no_meta_key(monkeypatch):
    """An inference-route brain builds via inference.LLM with no META_API_KEY —
    so the Gemini/LiveKit brains work on the project's LiveKit credits alone."""
    monkeypatch.delenv("META_API_KEY", raising=False)
    captured = _install_fake_cascade_plugins(monkeypatch)
    agent.build_cascade_session(
        "google/gemini-3.7-flash", "deepgram/nova-3", "inworld/inworld-tts-1",
    )
    # LLM leg is the inference model id, with no Meta base_url/key.
    assert captured["llm"]["model"] == "google/gemini-3.7-flash"
    assert "base_url" not in captured["llm"]
    assert "api_key" not in captured["llm"]
    assert captured["stt"]["model"] == "deepgram/nova-3"
    assert captured["tts"]["model"] == "inworld/inworld-tts-1"


def test_main_cascade_runtime_error_falls_back_to_gemini(monkeypatch):
    """A built main cascade that dies mid-call (CloseReason.ERROR) switches to a
    fresh Gemini Live main session on the same room — no dead air — exactly
    once, and never on a clean (user-initiated) close."""
    from livekit.agents.voice.events import CloseEvent, CloseReason

    started = []

    async def _fake_gemini_start(ctx, seed, **kwargs):
        started.append(kwargs.get("voice_provider"))

    monkeypatch.setattr(agent, "_start_main_gemini_session", _fake_gemini_start)

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    cascade = _FakePracticeSession()
    seed = agent.RoomSeed(system_prompt="sys", uid="u1", session_id="s1")
    agent._arm_main_cascade_fallback(
        _practice_ctx(), seed, cascade,
        flush=_FakeFlush(), window=[], route="vertex",
        use_inference=False, voice_provider="google_live",
    )

    async def _drive(reason):
        cascade.close(CloseEvent(reason=reason))
        await asyncio.sleep(0)

    asyncio.run(_drive(CloseReason.USER_INITIATED))
    assert started == []

    asyncio.run(_drive(CloseReason.ERROR))
    assert started == ["google_live"]

    asyncio.run(_drive(CloseReason.ERROR))
    assert started == ["google_live"]


# --- boot-time accent routing (§13.9) ----------------------------------------
def _rv(mode, **kw):
    import voice_catalog
    return voice_catalog.runtime_voices(mode=mode, **kw)


def test_accent_block_only_for_accent_capable_provider():
    import voice_catalog
    gemini = _rv(voice_catalog.MODE_REALTIME,
                 realtime_model_id=voice_catalog.REALTIME_GEMINI)
    block = agent._accent_block(gemini, "a southern American accent")
    assert "southern American accent" in block  # routed into the instruction

    fish = _rv(voice_catalog.MODE_CASCADE, tts_id="fishaudio/s2.1-pro")
    # Fixed-voice cascade: accent is NOT routed (ignored gracefully, no effect).
    assert agent._accent_block(fish, "a southern American accent") == ""
    # Empty accent -> nothing, even on an accent-capable provider.
    assert agent._accent_block(gemini, "") == ""


def test_gemini_session_instructions_carry_accent_cascade_does_not(monkeypatch):
    captured: dict = {}
    monkeypatch.setattr(agent, "Agent", lambda **k: captured.update(k) or object())
    for name in ("relay_transcripts", "relay_agent_state", "relay_mute_control",
                 "relay_token_usage", "relay_cascade_usage", "watch_for_idle",
                 "relay_voice_commands", "_session_tools"):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)

    async def _fake_open(*_a, **_k):
        pass

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)
    monkeypatch.setattr(agent, "build_realtime_model", lambda *a, **k: object())

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    class _Sess:
        def __init__(self):
            self._h = {}

        def on(self, n, cb=None):
            return (lambda f: f) if cb is None else cb

        async def start(self, **_k):
            pass

    # Gemini realtime path (llm=None) with a saved accent -> accent in the prompt.
    monkeypatch.setattr(agent, "AgentSession", lambda **k: _Sess())
    seed = agent.RoomSeed(system_prompt="SYS", uid="u1", session_id="s1",
                          voice_accent="a southern American accent")
    asyncio.run(agent._start_main_gemini_session(
        _practice_ctx(), seed, flush=_FakeFlush(), window=[], route="vertex",
        use_inference=False, voice_provider="p"))
    assert "a southern American accent" in captured["instructions"]

    # Cascade (fishaudio TTS) with the same saved accent -> NOT in the prompt.
    captured.clear()
    seed_c = agent.RoomSeed(system_prompt="SYS", uid="u1", session_id="s1",
                            voice_accent="a southern American accent",
                            tts_id="fishaudio/s2.1-pro")
    asyncio.run(agent._start_main_cascade_session(
        _practice_ctx(), seed_c, _Sess(), flush=_FakeFlush(), window=[]))
    assert "a southern American accent" not in captured["instructions"]


def test_realtime_accent_reaches_build_realtime_model_as_bcp47(monkeypatch):
    """Founder bug 2026-11-01: a free-text accent ("indian") did nothing on a
    Gemini Live native-audio call because ``seed.voice_accent`` was never passed
    as the BCP-47 ``language`` to ``build_realtime_model`` (native audio ignores
    the prompt-text accent for pronunciation). With ``voice_accent="indian"`` and
    an empty ``voice_language``, the realtime model must be built with language
    "en-IN" — AND the prompt accent directive must still be present."""
    captured: dict = {}
    build_args: dict = {}
    monkeypatch.setattr(agent, "Agent", lambda **k: captured.update(k) or object())
    for name in ("relay_transcripts", "relay_agent_state", "relay_mute_control",
                 "relay_token_usage", "relay_cascade_usage", "watch_for_idle",
                 "relay_voice_commands", "_session_tools"):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)

    async def _fake_open(*_a, **_k):
        pass

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)

    def _fake_build(*a, **k):
        build_args["args"] = a
        build_args["kwargs"] = k
        return object()

    monkeypatch.setattr(agent, "build_realtime_model", _fake_build)

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    class _Sess:
        def on(self, n, cb=None):
            return (lambda f: f) if cb is None else cb

        async def start(self, **_k):
            pass

    monkeypatch.setattr(agent, "AgentSession", lambda **k: _Sess())

    # Gemini realtime path (llm=None): free-text accent, no explicit language.
    seed = agent.RoomSeed(system_prompt="SYS", uid="u1", session_id="s1",
                          voice_accent="indian", voice_language="")
    asyncio.run(agent._start_main_gemini_session(
        _practice_ctx(), seed, flush=_FakeFlush(), window=[], route="vertex",
        use_inference=False, voice_provider="p"))
    # language is the 2nd positional arg to build_realtime_model.
    assert build_args["args"][1] == "en-IN", build_args
    # The prompt-text accent directive still rides along.
    assert "indian" in captured["instructions"].lower()

    # Explicit saved voice_language still wins over the accent-derived hint.
    build_args.clear()
    captured.clear()
    seed2 = agent.RoomSeed(system_prompt="SYS", uid="u1", session_id="s1",
                           voice_accent="indian", voice_language="fr-FR")
    asyncio.run(agent._start_main_gemini_session(
        _practice_ctx(), seed2, flush=_FakeFlush(), window=[], route="vertex",
        use_inference=False, voice_provider="p"))
    assert build_args["args"][1] == "fr-FR", build_args


def test_boot_wires_accent_into_hot_swapper_and_listens_for_settings_changes(
    monkeypatch,
):
    """Mid-call accent hot-swap (founder follow-up 2026-11-01): the live
    swapper must start from the same accent the boot session plays (raw system
    prompt + a builder for the accent block, not the block baked in), and the
    agent must listen for the settings screen's ``voice_accent_control`` data
    message so a save mid-call reaches the live session."""
    created: dict = {}
    real_swapper = agent.VoiceSwapper

    def _recording(session, **kwargs):
        created.update(kwargs)
        return real_swapper(session, **kwargs)

    monkeypatch.setattr(agent, "VoiceSwapper", _recording)
    monkeypatch.setattr(agent, "Agent", lambda **k: object())
    for name in ("relay_transcripts", "relay_agent_state", "relay_mute_control",
                 "relay_token_usage", "relay_cascade_usage", "watch_for_idle",
                 "relay_voice_commands", "_session_tools"):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)

    async def _fake_open(*_a, **_k):
        pass

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)
    monkeypatch.setattr(
        agent, "build_realtime_model", lambda *a, **k: object()
    )

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    class _Sess:
        def on(self, n, cb=None):
            return (lambda f: f) if cb is None else cb

        async def start(self, **_k):
            pass

    monkeypatch.setattr(agent, "AgentSession", lambda **k: _Sess())

    ctx = _practice_ctx()
    seed = agent.RoomSeed(system_prompt="SYS", uid="u1", session_id="s1",
                          voice_accent="indian", voice_language="")
    asyncio.run(agent._start_main_gemini_session(
        ctx, seed, flush=_FakeFlush(), window=[], route="vertex",
        use_inference=False, voice_provider="p"))
    # The swapper holds the RAW prompt plus the boot accent and a builder, so
    # a later accent rebuilds the instructions instead of replaying the old.
    assert created["system_prompt"] == "SYS", created
    assert created["voice_accent"] == "indian", created
    assert "indian" not in created["system_prompt"]
    assert "southern" in created["accent_block"]("a southern accent")
    # The settings screen's mid-call save has a listener on this call, and so
    # does the guided-tour tap bridge (§11.2b) — two data_received handlers now.
    assert "data_received" in ctx.room.handlers
    assert len(ctx.room.handlers["data_received"]) == 2


# --- cascade must not act on a stale seeded user turn (founder bug 2026-10-27)-
def _ctx_with(*turns):
    from livekit.agents import llm
    c = llm.ChatContext.empty()
    for role, text in turns:
        c.add_message(role=role, content=text)
    return c


def test_cascade_seed_chat_ctx_drops_trailing_user_turns():
    ctx = _ctx_with(("user", "earlier"), ("assistant", "reply"),
                    ("user", "stale tail"))
    out = agent._cascade_seed_chat_ctx(ctx)
    roles = [getattr(i, "role", None) for i in out.items]
    assert roles == ["user", "assistant"]  # trailing stale user turn removed
    # A context already ending in assistant is returned unchanged.
    ok = _ctx_with(("user", "hi"), ("assistant", "yo"))
    assert agent._cascade_seed_chat_ctx(ok) is ok
    assert agent._cascade_seed_chat_ctx(None) is None


def test_cascade_start_does_not_seed_a_trailing_stale_user_turn(monkeypatch):
    captured: dict = {}
    monkeypatch.setattr(agent, "Agent", lambda **k: captured.update(k) or object())
    for name in ("relay_transcripts", "relay_agent_state", "relay_mute_control",
                 "relay_cascade_usage", "watch_for_idle", "relay_voice_commands",
                 "_session_tools"):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)
    opened: dict = {}

    async def _fake_open(*_a, **_k):
        opened["via_opener"] = True

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)

    class _Sess:
        def on(self, n, cb=None):
            return (lambda f: f) if cb is None else cb

        async def start(self, **_k):
            pass

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    seed = agent.RoomSeed(
        system_prompt="SYS", uid="u1", session_id="s1",
        chat_ctx=_ctx_with(("assistant", "prev reply"), ("user", "stale tail")),
    )
    asyncio.run(agent._start_main_cascade_session(
        _practice_ctx(), seed, _Sess(), flush=_FakeFlush(), window=[]))
    # The cascade is seeded WITHOUT the trailing stale user turn, so the pipeline
    # cannot answer it on connect; the call opens via the normal opener instead.
    seeded = captured["chat_ctx"]
    assert [getattr(i, "role", None) for i in seeded.items] == ["assistant"]
    assert opened.get("via_opener") is True


def test_cascade_cold_start_opener_runs_against_history_free_context(monkeypatch):
    """Founder cold-start bug, 2026-10-28 (path B — the opener).

    The previous conversation ended with Ayma's reply, so the opener fires on a
    silent caller. The cascade forwards a history-free chat_ctx to the opener as a
    SECONDARY guard (the greet+choice behaviour itself is driven by the opener
    instruction + has-prior signal; see the opener-path tests above), while the
    agent's own chat_ctx still carries the whole prior exchange for later turns so
    "yeah, continue" works."""
    captured: dict = {}
    monkeypatch.setattr(agent, "Agent", lambda **k: captured.update(k) or object())
    for name in ("relay_transcripts", "relay_agent_state", "relay_mute_control",
                 "relay_cascade_usage", "watch_for_idle", "relay_voice_commands",
                 "_session_tools"):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)
    opener_calls: dict = {}

    async def _fake_open(session, seed, *, window, opener_chat_ctx,
                         seed_user_turn=False):
        opener_calls["opener_chat_ctx"] = opener_chat_ctx
        opener_calls["seed_user_turn"] = seed_user_turn

    monkeypatch.setattr(agent, "maybe_open_conversation", _fake_open)

    class _Sess:
        def on(self, n, cb=None):
            return (lambda f: f) if cb is None else cb

        async def start(self, **_k):
            pass

    class _FakeFlush:
        def start(self):
            pass

        async def run(self):
            pass

    seed = agent.RoomSeed(
        system_prompt="SYS", uid="u1", session_id="s1",
        chat_ctx=_ctx_with(("user", "I had a date last night"),
                           ("assistant", "ooh, tell me everything")),
    )
    asyncio.run(agent._start_main_cascade_session(
        _practice_ctx(), seed, _Sess(), flush=_FakeFlush(), window=[]))

    # The agent keeps the full prior exchange for genuine later turns ...
    assert [getattr(i, "role", None) for i in captured["chat_ctx"].items] == [
        "user", "assistant",
    ]
    # ... but the cold-start opener is generated against a history-free context,
    # so there is no "I had a date last night" turn for the LLM to answer first.
    opener_ctx = opener_calls["opener_chat_ctx"]
    assert opener_ctx is not agent.NOT_GIVEN
    assert list(opener_ctx.items) == []
    # The cascade is a text chat LLM, so the opener is seeded a synthetic user
    # turn (Sentry inference 400 fix) rather than sent system-only.
    assert opener_calls["seed_user_turn"] is True


def test_voice_tool_use_prompt_has_call_before_confirm_directive():
    """Voice tool-use directive (founder voice bug, 2026-10-28): the prompt must
    tell the agent to CALL the tool for an app action and only confirm from its
    actual result — never narrate an action as done without invoking the tool."""
    text = agent.load_voice_tool_use()
    assert text  # loaded from prompts/voice_tool_use.md, not inline
    low = text.lower()
    assert "must call" in low
    assert "never" in low  # never claim an action that wasn't actually taken
    # the result-grounded confirm rule
    assert "returned" in low or "result" in low


def test_main_voice_instructions_carry_the_tool_use_directive():
    """Both main voice paths (Gemini Live and the Meta cascade) compose their
    instructions through one composer, which always appends the tool-use
    directive — Gemini Live no longer goes without it (founder, prod 2284).
    """
    directive = agent.load_voice_tool_use()
    composed = agent._compose_instructions("SYS", "ACCENT", "VOCAB")
    assert directive in composed
    assert composed == "SYS\n\nACCENT\n\nVOCAB\n\n" + directive


# --- deterministic pre-model voice commands (prod 2284 fix) -------------------
#
# A finalized in-call user turn matching a stack / navigation / tour-start
# command executes through the session's own tools WITHOUT the model emitting
# anything; the model's own same-turn call to that tool then replays the
# result instead of running the side effect a second time. These tests drive
# the real relay plus the real session tools against a fake Firestore.


class _CmdSnap:
    def __init__(self, data, doc_id=""):
        self._data = data
        self.exists = data is not None
        self.id = doc_id

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _CmdStore(dict):
    """Tuple-keyed fake Firestore that acks every queued app command at once
    (a healthy client), recording profile writes and queued commands."""

    def __init__(self, uid):
        super().__init__()
        self._pending = ("users", uid, "app_commands", "pending")
        self._ack = ("users", uid, "app_commands", "ack")
        self.profile_writes = []
        self.queued = []

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == self._pending and isinstance(value, dict) and value.get("id"):
            self.queued.append(dict(value))
            super().__setitem__(self._ack, {"id": value["id"], "ok": True})
        if len(key) == 4 and key[2:] == ("profile", "main"):
            self.profile_writes.append(dict(value))


class _CmdDoc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _CmdCol(self.store, (*self.key, name))

    def get(self):
        return _CmdSnap(self.store.get(self.key))

    def set(self, patch, merge=False):
        cur = self.store.get(self.key) if merge else None
        self.store[self.key] = {**(cur or {}), **patch}

    def delete(self):
        self.store.pop(self.key, None)


class _CmdCol:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _CmdDoc(self.store, (*self.key, doc_id))

    def stream(self):
        # Enough for _resolve_person's roster scan (users collection only).
        seen = []
        d = len(self.key)
        for k in list(self.store):
            if len(k) == d + 1 and k[:d] == self.key:
                seen.append(_CmdSnap(self.store[k], k[-1]))
        return iter(seen)


class _CmdDb:
    def __init__(self, uid="u1"):
        self.store = _CmdStore(uid)

    def collection(self, name):
        return _CmdCol(self.store, (name,))

    def seed_user(self, uid, name):
        self.store[("users", uid)] = {"x": 1}
        self.store[("users", uid, "profile", "main")] = {"name": name}


class _CmdSession:
    """Fake AgentSession: captures @session.on handlers and records any
    generate_reply — a deterministic turn must never ask the model anything."""

    def __init__(self):
        self._handlers = {}
        self.generate_replies = []

    def on(self, name):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register

    def user_turn(self, transcript, is_final=True):
        self._handlers["user_input_transcribed"](
            _UserFinalEv(transcript, is_final)
        )

    def generate_reply(self, **kwargs):
        self.generate_replies.append(kwargs)


class _CmdParticipant:
    def __init__(self):
        self.published = []

    async def publish_data(self, payload, *, reliable, topic):
        self.published.append((topic, json.loads(payload), reliable))


class _CmdRoom:
    def __init__(self):
        self.local_participant = _CmdParticipant()


class _CmdCtx:
    def __init__(self):
        self.room = _CmdRoom()
        self.deleted_rooms = 0
        self.shutdown_reasons = []

    async def delete_room(self):
        self.deleted_rooms += 1

    def shutdown(self, reason):
        self.shutdown_reasons.append(reason)


async def _drain_until(predicate, timeout=5.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        assert asyncio.get_running_loop().time() < deadline, (
            "timed out waiting for the deterministic voice turn"
        )
        await asyncio.sleep(0.01)
    await asyncio.sleep(0.05)  # let fire-and-forget publishes land


def _voice_command_harness(
    monkeypatch, uid="u1", *, end_call=None, interpret=None,
    get_context=None,
):
    """The real session tools plus the real relay on fakes: returns
    ``(db, session, ctx, by_name, dedupe)``. ``end_call`` wires the relay's
    goodbye teardown, ``interpret``/``get_context`` the voice-actions skill
    (all None runs the deterministic net alone, exactly as before)."""
    import skills

    db = _CmdDb(uid)
    monkeypatch.setattr(agent, "get_db", lambda: db)
    dedupe = skills.VoiceTurnDedupe()
    ctx = _CmdCtx()
    session = _CmdSession()
    tools = agent._session_tools(ctx, uid, dedupe=dedupe)
    by_name = agent._tools_by_name(tools)
    agent.relay_voice_commands(
        session, tools, dedupe, end_call=end_call, interpret=interpret,
        get_context=get_context,
    )
    return db, session, ctx, by_name, dedupe


def _skill_stub(verdict):
    """A voice-actions ``interpret`` stub settling ``verdict`` (or raising
    it when it is an exception)."""

    async def _interpret(transcript, context, *, uid="", session_id=""):
        if isinstance(verdict, Exception):
            raise verdict
        return verdict

    return _interpret


@pytest.mark.parametrize("phrase,tool,keys", [
    ("switch my brain to Gemini", "set_brain", ["brain"]),
    ("switch to Gemini Live", "set_realtime_model", ["model"]),
    ("change the speech-to-text to deepgram", "set_stt", ["engine"]),
    ("switch my text-to-speech to inworld", "set_tts", ["engine"]),
    ("switch my voice mode to cascade", "set_voice_mode", ["mode"]),
    ("open the models page", "open_screen", ["screen"]),
    ("switch to explore", "open_screen", ["screen"]),
    # Text-lane order: a stack match wins over navigation on one turn.
    ("switch my brain to gemini and open the models page", "set_brain", ["brain"]),
    ("start the guided tour", "start_guided_tour", []),
    ("open the guided tour", "start_guided_tour", []),
])
def test_detect_voice_command_routes_each_family(phrase, tool, keys):
    match = agent.detect_voice_command(phrase)
    assert match is not None
    name, kwargs = match
    assert name == tool
    assert sorted(kwargs) == keys
    assert all(isinstance(v, str) and v for v in kwargs.values())


def test_detect_voice_command_passes_text_lane_values_through():
    assert agent.detect_voice_command("switch my brain to Gemini") == (
        "set_brain", {"brain": "gemini"},
    )
    assert agent.detect_voice_command("open the models page") == (
        "open_screen", {"screen": "voice_preference"},
    )
    assert agent.detect_voice_command("start the guided tour") == (
        "start_guided_tour", {},
    )


@pytest.mark.parametrize("phrase", [
    # Ordinary chat.
    "how are you today",
    "what can you do for me?",
    "tell me about the models you use",
    "the models page is my favorite screen",
    # Stack near-misses: no change verb + resolvable target, no switch.
    "my brain is fried today",
    "I use Gemini at work",
    "what brain are you thinking with",
    # Navigation near-misses: a nav verb but no resolvable destination.
    "open up about yourself",
    "show me what you got",
    "switch topics for a second",
    # Tour near-misses: stop / next / questions never start anything.
    "stop the tour",
    "what's next on the tour",
    "tell me about the guided tour",
    "is there a tour of the app",
    "",
])
def test_detect_voice_command_leaves_non_commands_alone(phrase):
    assert agent.detect_voice_command(phrase) is None


def test_voice_stack_command_executes_deterministically(monkeypatch):
    """A stack-switch turn writes the profile through the session's own
    set_brain tool with no model involvement, and the model's same-turn
    duplicate replays instead of writing twice."""
    import schema

    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)

    async def _main():
        session.user_turn("switch my brain to Gemini")
        await _drain_until(lambda: len(db.store.profile_writes) == 1)
        main = db.store[("users", "u1", "profile", "main")]
        assert main[schema.PF_AYMA_BRAIN_MODEL] == "gemini"
        # It ran through the session's own tool: the client saw start/end.
        chips = [
            p[1] for p in ctx.room.local_participant.published
            if p[0] == "tool_used"
        ]
        assert [c["phase"] for c in chips] == ["start", "end"]
        assert chips[0]["name"] == "set_brain"
        # The model was never asked anything on this turn.
        assert session.generate_replies == []
        # The model's own same-turn call replays: no second write.
        deterministic = dedupe.lookup("set_brain").future.result()
        dup = await by_name["set_brain"](brain="gemini")
        assert dup == deterministic
        assert len(db.store.profile_writes) == 1

    asyncio.run(_main())


def test_voice_navigation_command_opens_the_models_page(monkeypatch):
    """A navigation turn queues the navigate through the session's own
    open_screen tool with no model involvement; the model's same-turn
    duplicate — even with its own user-words arg — replays instead of
    queueing a second navigate."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)

    async def _main():
        session.user_turn("open the models page")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["action"] == "navigate"
        assert cmd["screen"] == "voice_preference"
        deterministic = dedupe.lookup("open_screen").future.result()
        assert deterministic.startswith("navigated:")
        dup = await by_name["open_screen"](screen="Models page")
        assert dup == deterministic
        assert len(db.store.queued) == 1
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_tour_start_command_spotlights_deterministically(monkeypatch):
    """A tour-start turn spotlights through the session's own
    start_guided_tour tool (voice-bound, like the model's calls) with no
    model involvement; the model's same-turn duplicate replays instead of
    presenting twice."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)

    async def _main():
        session.user_turn("start the guided tour")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["action"] == "tour_step"
        # Voice-bound, as the session binds it: the composer-only step 0 is
        # skipped and the first spotlight is step 1.
        assert cmd["index"] == 1
        state = db.store[("users", "u1", "app_commands", "tour_state")]
        assert state["active"] is True and state["index"] == 1
        deterministic = dedupe.lookup("start_guided_tour").future.result()
        assert "step 2 of" in deterministic
        dup = await by_name["start_guided_tour"]()
        assert dup == deterministic
        assert len(db.store.queued) == 1
        assert session.generate_replies == []

    asyncio.run(_main())


@pytest.mark.parametrize("phrase", [
    "my brain is fried today",
    "open up about yourself",
    "stop the tour",
    "what's next on the tour",
    "tell me about the guided tour",
    "the models page is my favorite screen",
])
def test_voice_non_command_turn_runs_no_tool(monkeypatch, phrase):
    """A near-miss turn passes through the relay untouched: no write, no
    queued command, no tool chip, nothing asked of the model."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)

    async def _main():
        session.user_turn(phrase)
        await asyncio.sleep(0.05)  # a command would have fired by now
        assert db.store.profile_writes == []
        assert db.store.queued == []
        assert ctx.room.local_participant.published == []
        assert session.generate_replies == []

    asyncio.run(_main())


# --- deterministic pre-model launch commands (prod 2284 follow-on) ---------
#
# Practice Date / Agent Date launches are the asks the founder was refused on
# prod 2284. A named-partner ask executes open_practice_date / open_date_sim
# deterministically through the same relay/dedupe path as the other families;
# a partner-less ask settles the "who with?" clarification instead.


@pytest.mark.parametrize("phrase,tool,name", [
    ("start a practice date with Sofia", "open_practice_date", "Sofia"),
    ("let me practice with Daniel", "open_practice_date", "Daniel"),
    ("practice date with Sofia", "open_practice_date", "Sofia"),
    ("start an agent date with Sofia", "open_date_sim", "Sofia"),
    ("run a date sim with Daniel", "open_date_sim", "Daniel"),
    ("simulate a date with Sofia", "open_date_sim", "Sofia"),
    ("date sim with Sofia", "open_date_sim", "Sofia"),
])
def test_detect_voice_command_routes_a_named_launch(phrase, tool, name):
    assert agent.detect_voice_command(phrase) == (tool, {"name": name})


@pytest.mark.parametrize("phrase,tool", [
    ("start a practice date", "open_practice_date"),
    ("run a date sim for me", "open_date_sim"),
    ("start a practice date with my girlfriend", "open_practice_date"),
])
def test_detect_voice_command_marks_a_partnerless_launch(phrase, tool):
    assert agent.detect_voice_command(phrase) == (tool, {"name": ""})


def test_detect_voice_command_launch_precedence():
    # "open Sofia's profile" stays navigation; a launch phrase is never it.
    assert agent.detect_voice_command("open Sofia's profile") == (
        "open_screen", {"screen": "profile"},
    )
    assert agent.detect_voice_command("practice date with Sofia") == (
        "open_practice_date", {"name": "Sofia"},
    )


@pytest.mark.parametrize("phrase", [
    "my practice date yesterday went well",
    "what is a practice date?",
    "do you think the simulation is accurate?",
    "tell me about my date sim results",
    "my practice date with Sofia went well",
    "open my date sim results",
    "open Sofia's profile",
])
def test_detect_voice_command_leaves_launch_discussion_alone(phrase):
    match = agent.detect_voice_command(phrase)
    if phrase == "open Sofia's profile":
        assert match == ("open_screen", {"screen": "profile"})
    else:
        assert match is None


def _seed_roster(db):
    db.seed_user("u1", "Me")
    db.seed_user("u-sofia", "Sofia Ruiz")
    db.seed_user("u-daniel", "Daniel Fox")


def test_voice_practice_launch_executes_deterministically(monkeypatch):
    """A named practice ask runs open_practice_date through the session's own
    tool (navigation queued for the resolved partner) with zero model
    involvement; the model's same-turn duplicate replays instead of
    queueing a second navigate."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)
    _seed_roster(db)

    async def _main():
        session.user_turn("start a practice date with Sofia")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["action"] == "navigate"
        assert cmd["path"] == "/practice/u-sofia"
        deterministic = dedupe.lookup("open_practice_date").future.result()
        assert deterministic.startswith("navigated:")
        assert "Sofia Ruiz" in deterministic
        dup = await by_name["open_practice_date"](name="Sofia")
        assert dup == deterministic
        assert len(db.store.queued) == 1
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_date_sim_launch_executes_deterministically(monkeypatch):
    """Same exactly-once path for an Agent Date ask."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)
    _seed_roster(db)

    async def _main():
        session.user_turn("run a date sim with Daniel")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["action"] == "navigate"
        assert cmd["path"] == "/date-sim/u-daniel"
        deterministic = dedupe.lookup("open_date_sim").future.result()
        assert deterministic.startswith("navigated:")
        assert "Daniel Fox" in deterministic
        dup = await by_name["open_date_sim"](name="Daniel")
        assert dup == deterministic
        assert len(db.store.queued) == 1
        assert session.generate_replies == []

    asyncio.run(_main())


@pytest.mark.parametrize("phrase,tool", [
    ("start a practice date", "open_practice_date"),
    ("run a date sim for me", "open_date_sim"),
])
def test_voice_partnerless_launch_asks_who_with(monkeypatch, phrase, tool):
    """A partner-less launch launches nothing and relays no "couldn't find
    someone" error: the claimed result is the "who with?" clarification,
    which the model's same-turn call replays."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)
    _seed_roster(db)

    async def _main():
        session.user_turn(phrase)
        await _drain_until(lambda: dedupe.lookup(tool) is not None)
        await asyncio.sleep(0.05)  # a launch would have queued by now
        assert db.store.queued == []
        clarification = dedupe.lookup(tool).future.result()
        low = clarification.lower()
        assert "who" in low and "with" in low
        assert "couldn't find" not in low
        assert "navigated:" not in clarification
        dup = await by_name[tool](name="")
        assert dup == clarification
        assert db.store.queued == []
        assert ctx.room.local_participant.published == []
        assert session.generate_replies == []

    asyncio.run(_main())


@pytest.mark.parametrize("phrase", [
    "my practice date yesterday went well",
    "what is a practice date?",
    "do you think the simulation is accurate?",
    "tell me about my date sim results",
    "my practice date with Sofia went well",
    "open my date sim results",
])
def test_voice_launch_near_miss_runs_no_tool(monkeypatch, phrase):
    """Launch discussion at the relay level: no queued command, no claimed
    tool, no tool chip, nothing asked of the model."""
    db, session, ctx, by_name, dedupe = _voice_command_harness(monkeypatch)
    _seed_roster(db)

    async def _main():
        session.user_turn(phrase)
        await asyncio.sleep(0.05)  # a command would have fired by now
        assert db.store.queued == []
        assert dedupe.lookup("open_practice_date") is None
        assert dedupe.lookup("open_date_sim") is None
        assert ctx.room.local_participant.published == []
        assert session.generate_replies == []

    asyncio.run(_main())


# --- staging/prod environment dispatch guard at the seam (ARCHITECTURE §1.1a) -

import dataclasses as _dataclasses  # noqa: E402
import livekit_token as _livekit_token  # noqa: E402


class _FakeRoom:  # noqa: F811 - local to the dispatch-guard tests below
    def __init__(self, name, metadata=""):
        self.name = name
        self.metadata = metadata


class _FakeJobRequest:
    """Records whether the dispatch seam accepted or rejected the job. A reject
    happens BEFORE any room join or Firestore write (``_request_fnc`` returns on
    reject without touching the entrypoint)."""

    def __init__(self, room):
        self.room = room
        self.accepted = False
        self.rejected = False

    async def accept(self):
        self.accepted = True

    async def reject(self):
        self.rejected = True


def _run_request(monkeypatch, *, agent_prefix, runtime, room_name, metadata=""):
    # Simulate this worker's env: LIVEKIT_ROOM_PREFIX (staging vs prod) and
    # AGENT_RUNTIME (cloudrun = prod default). The env guard reads the room
    # prefix via livekit_token.CONFIG; the cloud guard reads agent.CONFIG.
    monkeypatch.setattr(
        _livekit_token,
        "CONFIG",
        _dataclasses.replace(_livekit_token.CONFIG, livekit_room_prefix=agent_prefix),
    )
    monkeypatch.setattr(
        agent, "CONFIG", _dataclasses.replace(agent.CONFIG, agent_runtime=runtime)
    )
    req = _FakeJobRequest(_FakeRoom(room_name, metadata))
    asyncio.run(agent._request_fnc(req))
    return req


def test_prod_agent_rejects_a_staging_room_before_any_join_or_write(monkeypatch):
    # The 2026-11-01 specimen: the prod agent (cloudrun, ayma- prefix) is offered
    # a staging room on the shared LiveKit project. It MUST reject it, never
    # accept — accepting is what wrote an app_command into PROD Firestore.
    req = _run_request(
        monkeypatch, agent_prefix="ayma-", runtime="cloudrun",
        room_name="ayma-staging-abc",
    )
    assert req.rejected and not req.accepted


def test_prod_agent_accepts_a_normal_prod_room(monkeypatch):
    # A plain prod room (no staging prefix, no routing marker) is served exactly
    # as before — the env guard adds nothing to the prod happy path.
    req = _run_request(
        monkeypatch, agent_prefix="ayma-", runtime="cloudrun",
        room_name="ayma-me-xyz",
    )
    assert req.accepted and not req.rejected


def test_staging_agent_accepts_its_staging_room(monkeypatch):
    req = _run_request(
        monkeypatch, agent_prefix="ayma-staging-", runtime="cloudrun",
        room_name="ayma-staging-abc",
    )
    assert req.accepted and not req.rejected


def test_staging_agent_rejects_a_prod_room(monkeypatch):
    req = _run_request(
        monkeypatch, agent_prefix="ayma-staging-", runtime="cloudrun",
        room_name="ayma-me-xyz",
    )
    assert req.rejected and not req.accepted


def test_env_guard_runs_before_the_cloud_guards_fail_open(monkeypatch):
    # Even if the room marker is unreadable (the cloud guard fails OPEN to
    # accept), the prod agent still rejects a staging room: the env guard runs
    # first and is default-safe.
    req = _run_request(
        monkeypatch, agent_prefix="ayma-", runtime="cloudrun",
        room_name="ayma-staging-abc", metadata="{not json",
    )
    assert req.rejected and not req.accepted


# --- cascade TTS voice validity (staging bug, 2026-11-03) -------------------
#
# The configured cascade default voice is a Fish Audio id. A deploy that
# overrides only the TTS MODEL to another provider (e.g. inworld on staging)
# carried that Fish Audio id onto the Inworld TTS, which raised
# ``APIError: ... Unknown voice ... not found`` → no audio → silent call. The
# builder must drop a voice that isn't valid for the active TTS provider to the
# vendor default rather than hand the gateway an id it will reject.


def test_cascade_drops_cross_provider_voice_to_vendor_default(monkeypatch):
    # The EXACT staging specimen: Inworld TTS + the Fish Audio "Hannah" id.
    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    import voice_catalog
    fish_hannah = "9a9cf47702da476aa4629e2506d4a857"
    assert fish_hannah not in voice_catalog.tts_voice_ids("inworld/inworld-tts-1")

    agent.build_cascade_session(
        voice_catalog.BRAIN_META,
        "deepgram/nova-3",
        "inworld/inworld-tts-1",
        fish_hannah,
    )
    # The invalid cross-provider id must NOT reach the gateway — no voice kwarg
    # means the provider speaks in its own default (audible), not an error.
    assert captured["tts"]["model"] == "inworld/inworld-tts-1"
    assert "voice" not in captured["tts"]


def test_cascade_config_default_voice_dropped_on_model_override(monkeypatch):
    # seed.tts_voice empty → the builder falls back to CONFIG.meta_cascade_tts_voice
    # (a Fish Audio id). On an Inworld TTS that id is invalid, so it must be
    # dropped — reproduces the staging failure where the voice was never passed
    # explicitly, only inherited from config.
    monkeypatch.setenv("META_API_KEY", "test-key")
    cfg = dataclasses.replace(
        CONFIG, meta_cascade_tts_voice="9a9cf47702da476aa4629e2506d4a857"
    )
    monkeypatch.setattr(agent, "CONFIG", cfg)
    captured = _install_fake_cascade_plugins(monkeypatch)

    import voice_catalog
    agent.build_cascade_session(
        voice_catalog.BRAIN_META, "deepgram/nova-3", "inworld/inworld-tts-1", None
    )
    assert "voice" not in captured["tts"]


def test_cascade_keeps_valid_voice_for_its_provider(monkeypatch):
    # A voice that IS valid for the active TTS provider is passed through intact.
    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    import voice_catalog
    fish_hannah = "9a9cf47702da476aa4629e2506d4a857"
    assert fish_hannah in voice_catalog.tts_voice_ids("fishaudio/s2.1-pro")

    agent.build_cascade_session(
        voice_catalog.BRAIN_META, "deepgram/nova-3", "fishaudio/s2.1-pro", fish_hannah
    )
    assert captured["tts"]["voice"] == fish_hannah


def test_cascade_inworld_named_voice_kept(monkeypatch):
    # An Inworld named voice on the Inworld TTS is valid and kept.
    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    import voice_catalog
    agent.build_cascade_session(
        voice_catalog.BRAIN_META, "deepgram/nova-3", "inworld/inworld-tts-1", "Ashley"
    )
    assert captured["tts"]["voice"] == "Ashley"


# --- Cartesia cascade legs (grant-funded plugin, staging-first) --------------


def _install_fake_cartesia_plugin(monkeypatch, captured):
    """Fake the ``livekit-plugins-cartesia`` TTS/STT the cascade builder
    imports lazily, recording kwargs alongside the inference fakes."""
    pytest.importorskip("livekit.plugins.cartesia")
    import livekit.plugins.cartesia as lk_cartesia

    class _FakeCartesiaSTT:
        def __init__(self, **kwargs):
            captured["cartesia_stt"] = kwargs

    class _FakeCartesiaTTS:
        def __init__(self, **kwargs):
            captured["cartesia_tts"] = kwargs

    monkeypatch.setattr(lk_cartesia, "STT", _FakeCartesiaSTT)
    monkeypatch.setattr(lk_cartesia, "TTS", _FakeCartesiaTTS)


def test_cascade_cartesia_legs_use_plugin_when_key_present(monkeypatch):
    # Full Cartesia stack + key: STT builds the plugin with the catalog
    # suffix (ink-2), TTS with the PINNED flagship
    # (CONFIG.cartesia_tts_model, not the catalog's sonic-3), the valid
    # cartesia voice kept, language as the primary subtag — and no
    # Inference STT/TTS is built.
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    captured = _install_fake_cascade_plugins(monkeypatch)
    _install_fake_cartesia_plugin(monkeypatch, captured)

    skylar = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
    agent.build_cascade_session(
        "google/gemini-3.7-flash", "cartesia/ink-2", "cartesia/sonic-3",
        skylar, "en-US",
    )
    assert captured["cartesia_stt"]["model"] == "ink-2"
    assert captured["cartesia_stt"]["language"] == "en"
    assert captured["cartesia_stt"]["api_key"] == "test-cartesia-key"
    assert captured["cartesia_tts"]["model"] == CONFIG.cartesia_tts_model
    assert CONFIG.cartesia_tts_model == "sonic-3.6"  # addendum pin
    assert captured["cartesia_tts"]["voice"] == skylar
    assert captured["cartesia_tts"]["language"] == "en"
    assert captured["cartesia_tts"]["api_key"] == "test-cartesia-key"
    assert "stt" not in captured  # no Inference STT
    assert "tts" not in captured  # no Inference TTS


def test_cascade_cartesia_ink_whisper_passthrough(monkeypatch):
    # Mixed stack: cartesia Ink STT (wide-language fallback id) + an Inference
    # TTS — each leg builds independently, the STT suffix passing through.
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    captured = _install_fake_cascade_plugins(monkeypatch)
    _install_fake_cartesia_plugin(monkeypatch, captured)

    agent.build_cascade_session(
        "google/gemini-3.7-flash",
        "cartesia/ink-whisper",
        "fishaudio/s2.1-pro",
    )
    assert captured["cartesia_stt"]["model"] == "ink-whisper"
    # No voice_language was given, so no language kwarg is passed.
    assert "language" not in captured["cartesia_stt"]
    assert captured["tts"]["model"] == "fishaudio/s2.1-pro"  # Inference leg
    assert "stt" not in captured


def test_cascade_cartesia_falls_back_to_inference_without_key(monkeypatch):
    # Key missing: today's Inference construction with the full catalog ids —
    # no new hard failure, so a missing secret can never take voice down.
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    captured = _install_fake_cascade_plugins(monkeypatch)
    _install_fake_cartesia_plugin(monkeypatch, captured)

    skylar = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
    agent.build_cascade_session(
        "google/gemini-3.7-flash",
        "cartesia/ink-2",
        "cartesia/sonic-3",
        skylar,
    )
    assert captured["stt"]["model"] == "cartesia/ink-2"
    assert captured["tts"]["model"] == "cartesia/sonic-3"
    assert captured["tts"]["voice"] == skylar
    assert "cartesia_stt" not in captured
    assert "cartesia_tts" not in captured


def test_cascade_cartesia_missing_plugin_falls_back_to_inference(monkeypatch):
    # Key present but the plugin unimportable: the same Inference fallthrough
    # with a warning, never a hard failure.
    import sys

    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    captured = _install_fake_cascade_plugins(monkeypatch)
    # Block the lazy `from livekit.plugins import cartesia` however the module
    # was loaded before: None in sys.modules makes the submodule import raise,
    # and the parent attr must go too (`from`-imports try it first).
    monkeypatch.setitem(sys.modules, "livekit.plugins.cartesia", None)
    monkeypatch.delattr("livekit.plugins.cartesia", raising=False)

    agent.build_cascade_session(
        "google/gemini-3.7-flash", "cartesia/ink-2", "cartesia/sonic-3",
    )
    assert captured["stt"]["model"] == "cartesia/ink-2"
    assert captured["tts"]["model"] == "cartesia/sonic-3"


def test_cascade_cartesia_drops_cross_provider_voice(monkeypatch):
    # The configured Fish Audio default carried onto Cartesia TTS: dropped to
    # the vendor default (no voice kwarg) instead of reaching the plugin.
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    captured = _install_fake_cascade_plugins(monkeypatch)
    _install_fake_cartesia_plugin(monkeypatch, captured)

    fish_hannah = "9a9cf47702da476aa4629e2506d4a857"
    agent.build_cascade_session(
        "google/gemini-3.7-flash", "deepgram/nova-3", "cartesia/sonic-3",
        fish_hannah,
    )
    assert captured["cartesia_tts"]["model"] == CONFIG.cartesia_tts_model
    assert "voice" not in captured["cartesia_tts"]


def test_build_cartesia_helpers_ignore_non_cartesia_ids(monkeypatch):
    # Non-Cartesia ids (and a model-less "cartesia/" STT id) return None
    # without touching the key or the plugin, so the caller keeps today's
    # path.
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    assert agent._build_cartesia_stt("deepgram/nova-3", "en") is None
    assert agent._build_cartesia_tts("fishaudio/s2.1-pro", "", None) is None
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    assert agent._build_cartesia_stt("cartesia/", "en") is None


# --- no silent dead air on a cascade TTS error ------------------------------


def _tts_error_harness():
    handlers: dict = {}
    published: list = []

    class _FakeSession:
        def on(self, name):
            def _register(fn):
                handlers[name] = fn
                return fn
            return _register

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _FakeRoom:
        local_participant = _FakeLocalParticipant()

    class _FakeCtx:
        room = _FakeRoom()

    return handlers, published, _FakeSession, _FakeCtx


class _FakeSeed:
    uid = "u1"
    session_id = "s1"


def _err_ev(kind: str):
    class _Err:
        type = kind
        error = f"{kind} detail"

    class _Ev:
        error = _Err()

    return _Ev()


def test_cascade_tts_error_publishes_honest_status():
    handlers, published, _FakeSession, _FakeCtx = _tts_error_harness()

    async def _run():
        agent._arm_cascade_tts_error_status(_FakeCtx(), _FakeSeed(), _FakeSession())
        handlers["error"](_err_ev("tts_error"))
        await asyncio.sleep(0.05)

    asyncio.run(_run())
    assert published, "a TTS error must surface an honest status, never silence"
    topic, payload, reliable = published[0]
    assert topic == agent.TOPIC_VOICE_STATUS
    assert payload == {"state": agent.VOICE_STATUS_TTS_ERROR}


def test_cascade_non_tts_error_does_not_signal_tts_status():
    handlers, published, _FakeSession, _FakeCtx = _tts_error_harness()

    async def _run():
        agent._arm_cascade_tts_error_status(_FakeCtx(), _FakeSeed(), _FakeSession())
        handlers["error"](_err_ev("llm_error"))
        await asyncio.sleep(0.05)

    asyncio.run(_run())
    assert published == []


def test_cascade_tts_error_signals_at_most_once():
    handlers, published, _FakeSession, _FakeCtx = _tts_error_harness()

    async def _run():
        agent._arm_cascade_tts_error_status(_FakeCtx(), _FakeSeed(), _FakeSession())
        handlers["error"](_err_ev("tts_error"))
        handlers["error"](_err_ev("tts_error"))
        handlers["error"](_err_ev("tts_error"))
        await asyncio.sleep(0.05)

    asyncio.run(_run())
    assert len(published) == 1


# --- voice-actions skill first, deterministic net as fallback ----------------
#
# The skill interprets each finalized turn; its verdict executes through the
# session's own tools claim-first, exactly like a detector match. A ``none``
# verdict — or a skill failure — falls back to the untouched deterministic
# net. A skill-interpreted "goodbye Ayma" ends the call through the call's
# own teardown (the end_call_idle sequence with a "user_goodbye" reason).


def test_voice_skill_verdict_executes_through_session_tools(monkeypatch):
    """A skill navigate verdict queues the navigate through the session's
    own open_screen tool with zero model involvement (the founder's
    "Can you open up Explore?" shape)."""
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch,
        interpret=_skill_stub(Verdict(action="navigate", page="explore")),
    )

    async def _main():
        session.user_turn("Can you open up Explore?")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["action"] == "navigate"
        assert cmd["screen"] == "explore"
        deterministic = dedupe.lookup("open_screen").future.result()
        assert deterministic.startswith("navigated:")
        dup = await by_name["open_screen"](screen="explore")
        assert dup == deterministic
        assert len(db.store.queued) == 1
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_first_wins_over_the_net(monkeypatch):
    """The skill is the interpreter: when it disagrees with the net, its
    verdict is what executes — the net never also fires."""
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch,
        interpret=_skill_stub(Verdict(action="navigate", page="messages")),
    )

    async def _main():
        session.user_turn("switch to explore")  # the net alone says explore
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["screen"] == "messages"
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_none_is_authoritative_never_consults_the_net(monkeypatch):
    """An authoritative ``none`` verdict stays conversational: the relay
    never consults the deterministic net — no ``detect_voice_command``
    call — even on a transcript the net would have matched. Nothing is
    claimed, nothing is queued, and the model is asked nothing."""
    from skills.voice_actions import Verdict

    asked = []
    net_calls = []

    async def _interpret(transcript, context, *, uid="", session_id=""):
        asked.append(transcript)
        return Verdict(action="none")

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch, interpret=_interpret
    )
    real_net = agent.detect_voice_command
    assert real_net("switch to explore") is not None  # the net WOULD match

    def _spy(transcript):
        net_calls.append(transcript)
        return real_net(transcript)

    monkeypatch.setattr(agent, "detect_voice_command", _spy)

    async def _main():
        session.user_turn("switch to explore")
        await _drain_until(lambda: len(asked) == 1)
        await asyncio.sleep(0.05)  # a net dispatch would have fired by now
        assert net_calls == []
        assert db.store.queued == []
        assert dedupe.lookup("open_screen") is None
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_failure_falls_back_to_the_net(monkeypatch):
    """A skill failure (gateway down, timeout) degrades to the net — never
    a dead turn, never an error to the user from this layer."""
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch, interpret=_skill_stub(RuntimeError("gateway down"))
    )

    async def _main():
        session.user_turn("switch to explore")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["screen"] == "explore"
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_none_with_no_net_match_runs_nothing(monkeypatch):
    """Pure conversation: a ``none`` verdict on a non-command turn claims
    nothing, queues nothing, and asks the model nothing."""
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch, interpret=_skill_stub(Verdict(action="none"))
    )

    async def _main():
        session.user_turn("I love hiking and long walks on the beach")
        await asyncio.sleep(0.05)  # a command would have fired by now
        assert db.store.queued == []
        assert dedupe.lookup("open_screen") is None
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_clarify_claims_the_launch_tool(monkeypatch):
    """A skill ``clarify`` verdict settles the existing "who with?"
    clarification on the launch tool — nothing launches, and the model's
    same-turn call replays the clarification."""
    import skills
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch,
        interpret=_skill_stub(
            Verdict(action="clarify", clarify_for="launch_sim")
        ),
    )

    async def _main():
        session.user_turn("run a date sim")
        await _drain_until(
            lambda: dedupe.lookup("open_date_sim") is not None
        )
        result = await dedupe.lookup("open_date_sim").future
        assert result == skills.app_control.launch_clarification(
            "open_date_sim"
        )
        assert "who" in result.lower()
        assert db.store.queued == []
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_launch_with_context_partner_navigates(monkeypatch):
    """A skill launch verdict carrying the context-resolved partner ("talk
    to her in practice" → Dillu) navigates to that member's practice page."""
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch,
        interpret=_skill_stub(
            Verdict(action="launch_practice", partner="Sofia Ruiz")
        ),
    )
    _seed_roster(db)

    async def _main():
        session.user_turn("Can I talk to her in practice?")
        await _drain_until(lambda: len(db.store.queued) == 1)
        cmd = db.store[("users", "u1", "app_commands", "pending")]
        assert cmd["action"] == "navigate"
        assert cmd["path"] == "/practice/u-sofia"
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_receives_transcript_context_and_ids(monkeypatch):
    """The relay hands the skill the transcript, the call context, and the
    metering ids — verified on a second session sharing the harness tools."""
    import skills
    from skills.voice_actions import CallContext, Verdict

    seen = {}
    sentinel = CallContext(member="Dillu", page="profile")

    async def _interpret(transcript, context, *, uid="", session_id=""):
        seen["transcript"] = transcript
        seen["context"] = context
        seen["uid"] = uid
        seen["session_id"] = session_id
        return Verdict(action="none")

    db = _CmdDb("u1")
    monkeypatch.setattr(agent, "get_db", lambda: db)
    dedupe = skills.VoiceTurnDedupe()
    ctx = _CmdCtx()
    session = _CmdSession()
    tools = agent._session_tools(ctx, "u1", dedupe=dedupe)
    agent.relay_voice_commands(
        session, tools, dedupe, interpret=_interpret,
        get_context=lambda: sentinel, uid="u9", session_id="s9",
    )

    async def _main():
        session.user_turn("hello there")
        await _drain_until(lambda: "transcript" in seen)

    asyncio.run(_main())
    assert seen == {
        "transcript": "hello there",
        "context": sentinel,
        "uid": "u9",
        "session_id": "s9",
    }


def test_voice_skill_goodbye_ends_the_call(monkeypatch):
    """A skill-interpreted sign-off ends the session through the real
    teardown (memory flush, tell the client why, delete the room, shut
    down) with zero model involvement, and the turn is claimed."""
    from skills.voice_actions import Verdict

    flushed = []

    async def _flush():
        flushed.append(True)

    box = {}

    async def _end_call():
        await agent.end_call_goodbye(box["ctx"], "u1", _flush)

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch, end_call=_end_call,
        interpret=_skill_stub(Verdict(action="end_call")),
    )
    box["ctx"] = ctx

    async def _main():
        session.user_turn("goodbye Ayma")
        await _drain_until(lambda: dedupe.lookup("end_call") is not None)
        result = await dedupe.lookup("end_call").future
        assert result == agent._GOODBYE_RESULT
        assert flushed == [True]
        assert ctx.deleted_rooms == 1
        assert ctx.shutdown_reasons == ["user_goodbye"]
        endings = [
            p for p in ctx.room.local_participant.published
            if p[0] == "call_ending"
        ]
        assert endings == [("call_ending", {"reason": "user_goodbye"}, True)]
        assert db.store.queued == []
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_goodbye_duplicate_tears_down_once(monkeypatch):
    """A duplicated finalized sign-off transcript still runs teardown
    exactly once."""
    from skills.voice_actions import Verdict

    runs = []

    async def _end_call():
        runs.append(True)

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch, end_call=_end_call,
        interpret=_skill_stub(Verdict(action="end_call")),
    )

    async def _main():
        session.user_turn("goodbye Ayma")
        session.user_turn("goodbye Ayma")  # duplicate delivery of one final
        await _drain_until(lambda: dedupe.lookup("end_call") is not None)
        await dedupe.lookup("end_call").future
        await asyncio.sleep(0.05)  # a second teardown would have run by now
        assert runs == [True]
        assert session.generate_replies == []

    asyncio.run(_main())


def test_voice_skill_goodbye_without_teardown_stays_with_model(monkeypatch):
    """An end_call verdict with no teardown callback neither crashes nor
    tears anything down — the turn is left to the model."""
    from skills.voice_actions import Verdict

    db, session, ctx, by_name, dedupe = _voice_command_harness(
        monkeypatch, interpret=_skill_stub(Verdict(action="end_call"))
    )

    async def _main():
        session.user_turn("goodbye Ayma")
        await asyncio.sleep(0.05)
        assert ctx.deleted_rooms == 0
        assert ctx.shutdown_reasons == []
        assert ctx.room.local_participant.published == []
        assert db.store.queued == []

    asyncio.run(_main())


def test_end_call_goodbye_flushes_signals_deletes_then_shuts_down():
    """The user-hang-up sequence: memory write -> tell the client why
    (user_goodbye) -> delete the room -> shut down. The idle stop's shape,
    never an abrupt cutoff."""
    order = []

    async def _flush():
        order.append("flush")

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            order.append("call_ending_published")
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _FakeCtx:
        room = _Room()

        @staticmethod
        async def delete_room():
            order.append("room_deleted")

        @staticmethod
        def shutdown(reason):
            order.append(("shutdown", reason))

    asyncio.run(agent.end_call_goodbye(_FakeCtx(), "u1", _flush))

    assert order == [
        "flush",
        "call_ending_published",
        "room_deleted",
        ("shutdown", "user_goodbye"),
    ]
    assert published == [("call_ending", {"reason": "user_goodbye"}, True)]


# ---------------------------------------------------------------------------
# Ack-gated spoken claims: the command-claim gate.
#
# The app-command tools report "the app did NOT navigate" when the client
# never acks, but the realtime model's narration could claim success anyway
# (founder, 2026-11-03, 22:03 call). While the gate is latched the model's
# speech for the turn is interrupted and the agent speaks the truth itself.
# ---------------------------------------------------------------------------

class _GateSession:
    """Fake AgentSession for the claim gate: keeps every handler per event
    (the real emitter does), and records ``say`` lines."""

    def __init__(self):
        self._handlers = {}
        self.said = []
        self.generate_replies = []

    def on(self, name):
        def _register(fn):
            self._handlers.setdefault(name, []).append(fn)
            return fn

        return _register

    def _fire(self, name, ev):
        for fn in self._handlers.get(name, []):
            fn(ev)

    def user_turn(self, transcript, is_final=True):
        self._fire("user_input_transcribed", _UserFinalEv(transcript, is_final))

    def speech_created(self):
        handle = _FakeSpeechHandle()
        self._fire("speech_created", _SpeechCreatedEv(handle))
        return handle

    def say(self, text, **kwargs):
        self.said.append(text)

    def generate_reply(self, **kwargs):
        self.generate_replies.append(kwargs)


class _GateTool:
    """A stand-in session tool: records calls, settles a canned result (or
    raises it when the result is an exception)."""

    def __init__(self, name, result):
        from types import SimpleNamespace

        self.info = SimpleNamespace(name=name)
        self._result = result
        self.calls = []

    async def __call__(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self._result, Exception):
            raise self._result
        return self._result


def _gate_relay(tools):
    import skills

    session = _GateSession()
    dedupe = skills.VoiceTurnDedupe()
    agent.relay_voice_commands(session, tools, dedupe)
    return session, dedupe


def test_command_unconfirmed_scopes_the_gate_to_unconfirmed_nav_results():
    import skills

    nav = "open_screen"
    assert agent._command_unconfirmed(nav, skills.app_control._NOT_NAVIGATED)
    assert agent._command_unconfirmed(nav, skills.app_control._NOT_APPLIED)
    assert agent._command_unconfirmed(nav, "error: tool exceeded 15.0s")
    # A confirmed success, a truthful miss and a clarification are the
    # model's to narrate — the gate never touches them.
    assert not agent._command_unconfirmed(
        nav, "navigated: screen=voice_preference"
    )
    assert not agent._command_unconfirmed(nav, "no member named Zorblax")
    assert not agent._command_unconfirmed(
        nav, skills.app_control.launch_clarification("open_practice_date")
    )
    # Non-navigation tools are out of scope entirely.
    assert not agent._command_unconfirmed(
        "send_dm_message", skills.app_control._NOT_NAVIGATED
    )
    assert not agent._command_unconfirmed(nav, None)


def test_command_claim_gate_latches_on_an_unconfirmed_navigation():
    import skills

    async def _run():
        tool = _GateTool("open_screen", skills.app_control._NOT_NAVIGATED)
        session, dedupe = _gate_relay([tool])
        session.user_turn("open the models page")
        await _drain_until(lambda: bool(session.said))
        assert session.said == [agent._COMMAND_NOT_CONFIRMED_LINE]
        # The model's own narration for this turn is suppressed.
        assert session.speech_created().interrupted is True
        # The honest result still settles the claim for the model's replay.
        claim = dedupe.lookup("open_screen")
        assert claim is not None
        assert claim.future.result() == skills.app_control._NOT_NAVIGATED
        assert tool.calls == [{"screen": "voice_preference"}]

    asyncio.run(_run())


def test_command_claim_gate_leaves_a_confirmed_navigation_alone():
    async def _run():
        tool = _GateTool(
            "open_screen",
            "navigated: screen=voice_preference — the user is now on Models.",
        )
        session, _dedupe = _gate_relay([tool])
        session.user_turn("open the models page")
        await _drain_until(lambda: bool(tool.calls))
        await asyncio.sleep(0.1)
        assert session.said == []
        assert session.speech_created().interrupted is False

    asyncio.run(_run())


def test_command_claim_gate_rearms_on_the_next_user_turn():
    import skills

    async def _run():
        tool = _GateTool("open_screen", skills.app_control._NOT_NAVIGATED)
        session, _dedupe = _gate_relay([tool])
        session.user_turn("open the models page")
        await _drain_until(lambda: len(session.said) == 1)
        assert session.speech_created().interrupted is True

        # A fresh finalized turn re-arms: ordinary chat is never suppressed.
        session.user_turn("how are you today")
        await asyncio.sleep(0.05)
        assert session.speech_created().interrupted is False

        # And a second unconfirmed command earns its own honest line.
        session.user_turn("open the models page")
        await _drain_until(lambda: len(session.said) == 2)
        assert session.speech_created().interrupted is True

    asyncio.run(_run())


def test_command_claim_gate_latches_when_the_execution_itself_fails():
    async def _run():
        tool = _GateTool("open_screen", RuntimeError("firestore down"))
        session, dedupe = _gate_relay([tool])
        session.user_turn("open the models page")
        await _drain_until(lambda: bool(session.said))
        assert session.said == [agent._COMMAND_NOT_CONFIRMED_LINE]
        assert session.speech_created().interrupted is True
        # The dead claim is dropped, so nothing replays an exception.
        assert dedupe.lookup("open_screen") is None

    asyncio.run(_run())


# ---------------------------------------------------------------------------
# Reconnect silence: once ``reconnect_voice`` has queued the reconnect, the
# old session must say NOTHING about it (founder, 2026-11-03 — its
# "reconnecting now…" narration was cut off mid-sentence by the teardown).
# The claim gate's silence latch suppresses the model's narration for the
# rest of the turn and speaks no line of its own; the continuation session
# confirms the switch after the reconnect (see the _open_main_call tests).
# ---------------------------------------------------------------------------


def test_reconnect_queued_scopes_the_silence_latch():
    import skills

    queued = skills.set_model_stack._RECONNECT_QUEUED_RESULT
    assert agent._reconnect_queued("reconnect_voice", queued)
    # The staying-up outcomes are the model's to narrate.
    assert not agent._reconnect_queued(
        "reconnect_voice",
        "You're already reconnecting onto your updated setup — give it a "
        "moment. No need to reconnect again.",
    )
    assert not agent._reconnect_queued(
        "reconnect_voice",
        "There's no live voice call to reconnect right now — your saved "
        "changes will apply on your next voice call.",
    )
    # Other tools are out of scope entirely.
    assert not agent._reconnect_queued("open_screen", queued)
    assert not agent._reconnect_queued("reconnect_voice", None)


def test_claim_gate_silences_the_turn_a_reconnect_is_queued():
    import skills

    async def _run():
        session, dedupe = _gate_relay([])
        # Exactly what the dedupe wrapper does with a model-initiated call's
        # settled result.
        dedupe.outcome_observer(
            "reconnect_voice", skills.set_model_stack._RECONNECT_QUEUED_RESULT
        )
        # No line from the gate, and the model's narration is suppressed.
        assert session.said == []
        assert session.speech_created().interrupted is True

        # The next finalized turn re-arms: ordinary chat is never suppressed.
        session.user_turn("thanks, that worked")
        await asyncio.sleep(0.05)
        assert session.speech_created().interrupted is False

    asyncio.run(_run())


def test_claim_gate_ignores_other_reconnect_outcomes():
    async def _run():
        session, dedupe = _gate_relay([])
        dedupe.outcome_observer(
            "reconnect_voice",
            "There's no live voice call to reconnect right now — your saved "
            "changes will apply on your next voice call.",
        )
        await asyncio.sleep(0.05)
        assert session.said == []
        assert session.speech_created().interrupted is False

    asyncio.run(_run())


class _NoAckStore(_CmdStore):
    """A dead client: commands queue, acks never land."""

    def __setitem__(self, key, value):
        if key == self._pending and isinstance(value, dict) and value.get("id"):
            self.queued.append(dict(value))
            dict.__setitem__(self, key, value)
            return
        super().__setitem__(key, value)


def test_command_claim_gate_dead_client_end_to_end(monkeypatch):
    """The real tools against a client that never acks — the 22:03 shape:
    the command queues, the ack wait times out, the gate speaks the truth
    and suppresses the model's narration, on the deterministic path AND on
    a fresh model-initiated call alike."""
    import skills

    db = _CmdDb("u1")
    db.store = _NoAckStore("u1")
    monkeypatch.setattr(agent, "get_db", lambda: db)
    monkeypatch.setattr(skills.app_control, "_ACK_TIMEOUT_SECONDS", 0.3)
    monkeypatch.setattr(skills.app_control, "_ACK_POLL_SECONDS", 0.05)
    dedupe = skills.VoiceTurnDedupe()
    session = _GateSession()
    tools = agent._session_tools(_CmdCtx(), "u1", dedupe=dedupe)
    by_name = agent._tools_by_name(tools)
    agent.relay_voice_commands(session, tools, dedupe)

    async def _run():
        session.user_turn("open the models page")
        await _drain_until(lambda: bool(session.said), timeout=10.0)
        assert session.said == [agent._COMMAND_NOT_CONFIRMED_LINE]
        assert session.speech_created().interrupted is True
        assert db.store.queued and db.store.queued[0]["screen"] == "voice_preference"

        # A fresh model-initiated call on the next turn is gated the same
        # way, through the dedupe wrapper's outcome observer.
        session.user_turn("thanks")
        result = await by_name["open_screen"](screen="voice_preference")
        assert result == skills.app_control._NOT_NAVIGATED
        assert session.said == [agent._COMMAND_NOT_CONFIRMED_LINE] * 2
        assert session.speech_created().interrupted is True

    asyncio.run(_run())
