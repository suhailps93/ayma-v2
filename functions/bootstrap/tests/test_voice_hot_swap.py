"""Mid-call voice hot swap (agent.py ``VoiceSwapper``) and the live variant of
``set_voice_preference``: the Live session is rebuilt in the new voice with the
conversation carried over once, a context note + confirmation instruction on the
new agent, and every session-level relay (metrics, transcripts…) untouched."""

import asyncio
import json

import pytest

pytest.importorskip("livekit.agents")
pytest.importorskip("livekit.plugins.google.realtime")

from livekit.agents import Agent, AgentSession, AgentStateChangedEvent, llm  # noqa: E402

import agent  # noqa: E402
import voices  # noqa: E402
from skills import set_voice_preference as svp  # noqa: E402


class _Chain:
    def __init__(self):
        self.written = {}

    def collection(self, _):
        return self

    def document(self, _):
        return self

    def set(self, payload, merge=False):
        self.written.update(payload)


# An unstarted AgentSession only needs a loop reference to exist; it schedules
# nothing on it until start(). One shared, never-run loop keeps the tests free
# of event-loop setup noise.
_LOOP = asyncio.new_event_loop()


class _Factory:
    def __init__(self):
        self.calls = []

    def __call__(self, voice, language, *, route):
        self.calls.append((voice, language, route))
        return _FakeModel(voice, language)


class _FakeModel:
    def __init__(self, voice, language):
        self.voice, self.language = voice, language


def _seeded_session():
    """A real (unstarted) AgentSession running the original Ayma agent: two
    seeded turns, one live exchange and a tool call in its chat context."""
    ctx = llm.ChatContext.empty()
    ctx.add_message(role="user", content="seed: hi from yesterday")
    ctx.add_message(role="assistant", content="seed: good to hear from you")
    ctx.add_message(role="user", content="can you switch to a male voice")
    ctx.insert(
        llm.FunctionCall(
            call_id="c1", name="set_voice_preference", arguments='{"request":"male"}'
        )
    )
    ctx.insert(
        llm.FunctionCallOutput(
            call_id="c1", name="set_voice_preference", output="ok", is_error=False
        )
    )
    ctx.add_message(role="assistant", content="Switching my voice, one second")
    session = AgentSession(loop=_LOOP)
    session.update_agent(Agent(instructions="SYSTEM PROMPT", chat_ctx=ctx))
    return session


def _swapper(
    session, factory, *, route="vertex", voice="Aoede", language="",
    accent="", accent_block=None, muted=False,
):
    sw = agent.VoiceSwapper(
        session,
        system_prompt="SYSTEM PROMPT",
        route=route,
        voice_name=voice,
        voice_language=language,
        voice_accent=accent,
        accent_block=accent_block,
        model_factory=factory,
        session_id="s-1",
        provider="livekit_inference" if route == "inference" else "google",
        is_muted=lambda: muted,
        settle_seconds=0.0,
        verify_seconds=0.1,
    )
    sw.tools = []
    return sw


class _AccentCapable:
    supports_accent = True


def _real_accent_block(accent):
    """The production accent directive, as the boot path builds it."""
    return agent._accent_block(_AccentCapable(), accent)


def _speak(session):
    session.emit(
        "agent_state_changed",
        AgentStateChangedEvent(old_state="listening", new_state="speaking"),
    )


def _new_sessions_speak(session, pattern=None):
    """Make each handoff's new session start speaking (``pattern[i]`` False =
    the i-th new session stays silent, like the hung gateway reply)."""
    real = session.update_agent
    count = [0]

    def _update(new_agent):
        real(new_agent)
        i = count[0]
        count[0] += 1
        if pattern is None or (i < len(pattern) and pattern[i]):
            asyncio.get_running_loop().call_soon(_speak, session)

    session.update_agent = _update
    return count


async def _no_heads_up(_session, *a, **k):
    return None


def test_indian_accent_maps_to_indian_english_hint():
    assert voices.bcp47_hint("an Indian accent") == "en-IN"
    assert voices.bcp47_hint("Hindi with an Indian accent") == "hi-IN"


def test_tool_description_lists_presets_by_gender():
    lean = voices.presets_by_lean()
    assert "feminine: " in lean and "masculine: " in lean
    for name in ("Kore", "Leda", "Zephyr", "Aoede"):
        assert name in lean.split("feminine: ")[1].split(";")[0]
    for name in ("Charon", "Fenrir", "Orus", "Puck"):
        assert name in lean.split("masculine: ")[1].split(";")[0]
    assert lean in svp.DESCRIPTION


def test_live_tool_reports_the_reconnect_and_saves():
    db = _Chain()
    calls = []

    def _hook(preset, accent):
        calls.append((preset, accent))
        return True, "voice → Charon (deep)"

    msg = svp.bind_live(db, "u1", _hook)(request="a male voice")
    assert calls == [("Charon", "")]
    assert db.written["ayma_voice_name"] == "Charon"
    assert "Switching my voice, one second" in msg
    assert "next" not in msg


def test_live_tool_without_reconnect_is_truthful():
    db = _Chain()
    msg = svp.bind_live(db, "u1", lambda p, a: (False, "accent → x"))(
        accent_language="an Irish accent"
    )
    assert msg == "accent → x. Saved as their default."


def test_swap_rebuilds_model_and_carries_history_once(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory)
    tools_before = sw.tools

    async def _run():
        reconnecting, detail = sw.request("Charon", "")
        assert reconnecting and "Charon" in detail
        await sw._task

    asyncio.run(_run())

    assert factory.calls == [("Charon", "", "vertex")]
    new = session.current_agent
    assert isinstance(new, agent.SwappedVoiceAgent)
    assert (new.llm.voice, new.llm.language) == ("Charon", "")
    assert new.tools == tools_before
    texts = [m.text_content for m in new.chat_ctx.messages()]
    assert texts == [
        "seed: hi from yesterday",
        "seed: good to hear from you",
        "can you switch to a male voice",
        "Switching my voice, one second",
    ]
    assert not any(i.type.startswith("function_call") for i in new.chat_ctx.items)


def test_swap_note_and_confirmation_in_new_session(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    sw = _swapper(session, _Factory())

    async def _run():
        sw.request("Charon", "")
        await sw._task

    asyncio.run(_run())
    new = session.current_agent
    assert new.instructions.startswith("SYSTEM PROMPT")
    assert "You just reconnected to change your voice to the Charon voice" in (
        new.instructions
    )
    assert "the user asked for this" in new.instructions
    assert "do not restart with an opener" in new.instructions

    replies = []

    class _S:
        async def generate_reply(self, *, instructions):
            replies.append(instructions)

    monkeypatch.setattr(agent.SwappedVoiceAgent, "session", property(lambda s: _S()))
    asyncio.run(new.on_enter())
    assert len(replies) == 1
    assert "Confirm in one short" in replies[0] and "Charon" in replies[0]
    assert "do not greet them again" in replies[0]


def test_session_level_relays_survive_the_swap(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    seen = []
    session.on("metrics_collected", lambda ev: seen.append(ev))
    session.on("conversation_item_added", lambda ev: seen.append(ev))
    sw = _swapper(session, _Factory())

    async def _run():
        sw.request("Charon", "")
        await sw._task

    asyncio.run(_run())
    session.emit("metrics_collected", "turn-after-swap")
    session.emit("conversation_item_added", "item-after-swap")
    assert seen == ["turn-after-swap", "item-after-swap"]


def test_accent_reconnects_with_language_hint_on_google(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory)

    async def _run():
        reconnecting, detail = sw.request(None, "an Indian accent")
        assert reconnecting
        assert "en-IN" in detail and "no accent" in detail
        await sw._task

    asyncio.run(_run())
    assert factory.calls == [("Aoede", "an Indian accent", "vertex")]
    assert "speaking: an Indian accent" in session.current_agent.instructions


def test_accent_only_on_inference_does_not_reconnect():
    session = _seeded_session()
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")
    reconnecting, detail = sw.request(None, "an Indian accent")
    assert not reconnecting
    assert "no accent" in detail and "en-IN" not in detail
    assert sw._task is None and factory.calls == []


def test_same_voice_does_not_reconnect():
    sw = _swapper(_seeded_session(), _Factory(), voice="Charon")
    reconnecting, detail = sw.request("Charon", "")
    assert not reconnecting and "already the current voice" in detail


def test_back_to_back_requests_swap_serially_to_the_latest(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")

    async def _run():
        sw.request("Charon", "")
        first = sw._task
        sw.request("Kore", "")
        await sw._task
        assert first.done()

    asyncio.run(_run())
    assert [c[0] for c in factory.calls] == ["Kore"]


def test_failed_swap_keeps_the_current_agent(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    old = session.current_agent

    def _boom(*a, **k):
        raise RuntimeError("no model")

    sw = _swapper(session, _boom)

    async def _run():
        sw.request("Charon", "")
        await sw._task

    asyncio.run(_run())
    assert session.current_agent is old


class _StateSession:
    def __init__(self):
        self.agent_state = "thinking"
        self.handlers = []

    def on(self, _name, fn):
        self.handlers.append(fn)

    def off(self, _name, fn):
        self.handlers.remove(fn)

    def set(self, state):
        self.agent_state = state
        for fn in list(self.handlers):
            fn(type("Ev", (), {"new_state": state})())


def test_await_heads_up_waits_for_the_line_to_finish():
    s = _StateSession()

    async def _run():
        task = asyncio.create_task(agent._await_heads_up(s, 1.0, 1.0))
        await asyncio.sleep(0.01)
        s.set("speaking")
        await asyncio.sleep(0.01)
        assert not task.done()
        s.set("listening")
        await asyncio.wait_for(task, 0.5)

    asyncio.run(_run())
    assert s.handlers == []


def test_await_heads_up_gives_up_when_none_comes():
    s = _StateSession()
    asyncio.run(asyncio.wait_for(agent._await_heads_up(s, 0.05, 1.0), 0.5))
    assert s.handlers == []


# --- Founder test 2026-10-26: "change your voice to a male voice that speaks
# American English" -> heads-up, then silence. The new LiveKit Inference
# session hung on a reply requested the instant it was set up.


def _reports(monkeypatch):
    sent = []
    monkeypatch.setattr(
        agent, "capture_exception", lambda exc=None, tags=None: sent.append((exc, tags))
    )
    return sent


def test_confirmation_waits_for_the_new_session_to_settle(monkeypatch):
    order = []

    class _S:
        async def generate_reply(self, *, instructions):
            order.append("reply")

    async def _sleep(seconds):
        order.append(("settle", seconds))

    a = agent.SwappedVoiceAgent(
        confirm_instructions="confirm", settle_seconds=1.0, instructions="x"
    )
    monkeypatch.setattr(agent.SwappedVoiceAgent, "session", property(lambda s: _S()))
    monkeypatch.setattr(agent.asyncio, "sleep", _sleep)
    asyncio.run(a.on_enter())
    assert order == [("settle", 1.0), "reply"]
    assert agent._SWAP_SETTLE_SECONDS > 0


def test_silent_new_session_is_rebuilt_once(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    sent = _reports(monkeypatch)
    session = _seeded_session()
    _new_sessions_speak(session, [False, True])
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")

    async def _run():
        sw.request("Puck", "")
        await sw._task

    asyncio.run(_run())
    assert [c[0] for c in factory.calls] == ["Puck", "Puck"]
    assert sw._live == ("Puck", None)
    new = session.current_agent
    assert new.llm.voice == "Puck"
    assert "Confirm in one short" in new._confirm_instructions
    assert len(sent) == 1
    exc, tags = sent[0]
    assert isinstance(exc, agent.VoiceSwapError)
    assert tags == {
        "voice_swap": "failed",
        "session_id": "s-1",
        "voice_provider": "livekit_inference",
    }


def test_two_silent_sessions_restore_the_old_voice_honestly(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    sent = _reports(monkeypatch)
    session = _seeded_session()
    _new_sessions_speak(session, [False, False, True])
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")

    async def _run():
        sw.request("Puck", "")
        await sw._task
        # A retry of the same ask later is a real swap again, not "already
        # the current voice".
        assert sw.request("Puck", "")[0] is True
        sw._task.cancel()

    asyncio.run(_run())
    assert [c[0] for c in factory.calls] == ["Puck", "Puck", "Aoede"]
    restored = session.current_agent
    assert restored.llm.voice == "Aoede"
    assert "couldn't switch voices, staying with my current one" in (
        restored._confirm_instructions
    )
    assert "Puck" in restored._confirm_instructions
    assert "Never claim the switch worked" in restored._confirm_instructions
    assert restored.instructions == "SYSTEM PROMPT"
    assert sw._live == ("Aoede", None)
    assert len(sent) == 2


def test_failed_restore_is_reported_not_raised(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    sent = _reports(monkeypatch)
    session = _seeded_session()
    _new_sessions_speak(session, [False, False, False])
    sw = _swapper(session, _Factory(), route="inference")

    async def _run():
        sw.request("Puck", "")
        await sw._task

    asyncio.run(_run())
    assert len(sent) == 3
    assert "restore" in str(sent[-1][0])


def test_muted_silence_is_not_a_failure(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    sent = _reports(monkeypatch)
    session = _seeded_session()
    _new_sessions_speak(session, [False])
    factory = _Factory()
    sw = _swapper(session, factory, route="inference", muted=True)

    async def _run():
        sw.request("Puck", "")
        await sw._task

    asyncio.run(_run())
    assert [c[0] for c in factory.calls] == ["Puck"]
    assert sent == [] and sw._live == ("Puck", None)


def test_tool_result_does_not_wait_for_the_swap():
    """The tool returns its result (which prompts the heads-up) at once while
    the swap waits for that heads-up: neither waits on the other."""
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")
    tool = svp.bind_live(_Chain(), "u1", sw.request)

    async def _run():
        msg = tool(request="a male voice", accent_language="American English")
        assert "Switching my voice, one second" in msg
        await asyncio.sleep(0.05)
        assert not sw._task.done() and factory.calls == []
        _speak(session)  # the heads-up plays
        session.emit(
            "agent_state_changed",
            AgentStateChangedEvent(old_state="speaking", new_state="listening"),
        )
        await asyncio.wait_for(sw._task, 1.0)

    asyncio.run(_run())
    assert factory.calls == [("Charon", "American English", "inference")]
    assert isinstance(session.current_agent, agent.SwappedVoiceAgent)


def test_swap_proceeds_when_the_heads_up_never_comes(monkeypatch):
    real = agent._await_heads_up

    async def _short(session):
        await real(session, 0.05, 0.05)

    monkeypatch.setattr(agent, "_await_heads_up", _short)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")

    async def _run():
        sw.request("Puck", "")
        await asyncio.wait_for(sw._task, 1.0)

    asyncio.run(_run())
    assert [c[0] for c in factory.calls] == ["Puck"]


@pytest.mark.parametrize(
    "kwargs, preset, accent",
    [
        # What the live model actually sent in the 2026-10-26 repro runs.
        ({"request": "Puck", "accent_language": "en-US"}, "Puck", "en-US"),
        ({"request": "Fenrir", "accent_language": "en-US"}, "Fenrir", "en-US"),
        ({"request": "male", "voice_name": "Puck"}, "Puck", ""),
        ({"voice_name": "puck"}, "Puck", ""),
        ({"accent_language": "a male voice, American English"}, "Charon",
         "a male voice, American English"),
        ({"accent_language": "female, British"}, "Kore", "female, British"),
        ({"request": "a male voice that speaks American English"}, "Charon", ""),
        ({"accent_language": "a soft Southern US accent"}, None,
         "a soft Southern US accent"),
    ],
)
def test_voice_asks_map_to_presets(kwargs, preset, accent):
    got = svp._persist(
        _Chain(), "u1", kwargs.get("request", ""), kwargs.get("voice_name", ""),
        kwargs.get("accent_language", ""),
    )
    assert got == (preset, accent)


def test_american_english_hint_only_where_honoured():
    assert voices.bcp47_hint("American English") == "en-US"
    google = _swapper(_seeded_session(), _Factory(), route="vertex")
    assert google._hint("American English") == "en-US"
    inference = _swapper(_seeded_session(), _Factory(), route="inference")
    assert inference._hint("American English") is None
    reconnecting, detail = inference.request(None, "American English")
    assert not reconnecting and "en-US" not in detail


def test_model_build_failures_say_so_on_the_current_session(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    sent = _reports(monkeypatch)
    session = _seeded_session()
    old = session.current_agent
    replies = []
    session.generate_reply = lambda *, instructions: replies.append(instructions)

    def _boom(*a, **k):
        raise RuntimeError("no model")

    sw = _swapper(session, _boom, route="inference")

    async def _run():
        sw.request("Puck", "")
        await sw._task

    asyncio.run(_run())
    assert session.current_agent is old
    assert len(replies) == 1 and "couldn't switch voices" in replies[0]
    assert [str(e) for e, _ in sent] == ["no model", "no model"]
    assert sw._live == ("Aoede", None)


def test_call_ending_mid_swap_stops_retrying(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    sent = _reports(monkeypatch)
    session = _seeded_session()
    count = _new_sessions_speak(session, [False, False, False])
    factory = _Factory()
    sw = _swapper(session, factory, route="inference")
    session.emit("close", object())

    async def _run():
        sw.request("Puck", "")
        await sw._task

    asyncio.run(_run())
    assert count[0] == 1 and len(sent) == 1


# --- Mid-call ACCENT hot-swap (founder follow-up 2026-11-01) ------------------
# The dedicated free-text accent (``ayma_voice_accent``) applies to the CURRENT
# call through the same seamless reconnect — the BCP-47 lever boot uses plus a
# rebuilt accent instruction block — instead of persisting-only for the next
# call.


def test_accent_change_reconnects_with_bcp47_hint(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory, accent_block=_real_accent_block)

    async def _run():
        reconnecting, detail = sw.request(None, "", voice_accent="indian")
        assert reconnecting
        assert "en-IN" in detail and "indian" in detail
        await sw._task

    asyncio.run(_run())
    # Raw accent text reaches the builder, which hints it (as boot does).
    assert factory.calls == [("Aoede", "indian", "vertex")]
    new = session.current_agent
    assert isinstance(new, agent.SwappedVoiceAgent)
    assert new.instructions.startswith("SYSTEM PROMPT")
    assert "indian" in new.instructions
    assert sw._live_accent == "indian"


def test_explicit_language_still_wins_over_accent_hint_live(monkeypatch):
    """Boot parity on the live path: an explicit voice_language beats the
    accent-derived hint — but the new accent instructions still apply."""
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(
        session, factory, language="fr-FR", accent_block=_real_accent_block
    )

    async def _run():
        reconnecting, _detail = sw.request(None, "", voice_accent="indian")
        assert reconnecting
        await sw._task

    asyncio.run(_run())
    assert factory.calls == [("Aoede", "fr-FR", "vertex")]
    assert "indian" in session.current_agent.instructions


def test_same_accent_does_not_reconnect():
    sw = _swapper(_seeded_session(), _Factory(), accent="an Irish accent")
    reconnecting, detail = sw.request(None, "", voice_accent="an Irish accent")
    assert not reconnecting and "already the current accent" in detail
    assert sw._task is None and sw._live_accent == "an Irish accent"


def test_accent_cleared_rebuilds_without_hint(monkeypatch):
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(
        session, factory, accent="indian", accent_block=_real_accent_block
    )

    async def _run():
        reconnecting, detail = sw.request(None, "", voice_accent="")
        assert reconnecting and "default" in detail
        await sw._task

    asyncio.run(_run())
    assert factory.calls == [("Aoede", "", "vertex")]
    new = session.current_agent
    assert new.instructions.startswith("SYSTEM PROMPT")
    assert "indian" not in new.instructions
    assert sw._live_accent == ""


def test_accent_change_on_inference_reconnects_for_instructions(monkeypatch):
    """The gateway ignores the BCP-47 hint, but the accent instructions still
    refresh — so an accent change reconnects where a bare language-hint
    change would not."""
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(
        session, factory, route="inference", accent_block=_real_accent_block
    )

    async def _run():
        reconnecting, detail = sw.request(
            None, "", voice_accent="an Irish accent"
        )
        assert reconnecting
        assert "en-IE" not in detail and "Irish" in detail
        await sw._task

    asyncio.run(_run())
    assert factory.calls == [("Aoede", "an Irish accent", "inference")]
    assert "Irish" in session.current_agent.instructions


def test_live_tool_accent_only_hot_swaps_live():
    db = _Chain()
    calls = []

    def _hook(preset, accent, *, voice_accent=None):
        calls.append((preset, accent, voice_accent))
        return True, f"accent → {voice_accent}: hint set to en-IE, switching now"

    msg = svp.bind_live(db, "u1", _hook)(accent="an Irish accent")
    assert calls == [(None, "", "an Irish accent")]
    assert db.written["ayma_voice_accent"] == "an Irish accent"
    assert "Switching my voice, one second" in msg
    assert "next" not in msg


def test_live_tool_accent_plus_voice_combines_live():
    db = _Chain()
    calls = []

    def _hook(preset, accent, *, voice_accent=None):
        calls.append((preset, accent, voice_accent))
        return True, "voice → Charon (deep); accent → Irish (switching now)"

    msg = svp.bind_live(db, "u1", _hook)(
        request="a male voice", accent="Irish"
    )
    assert calls == [("Charon", "", "Irish")]
    assert db.written["ayma_voice_name"] == "Charon"
    assert db.written["ayma_voice_accent"] == "Irish"
    assert "Switching my voice, one second" in msg


class _Packet:
    def __init__(self, topic, data):
        self.topic = topic
        self.data = data


def _pkt(topic, payload):
    return _Packet(topic, json.dumps(payload).encode())


def test_voice_accent_control_message_triggers_swap(monkeypatch):
    """The settings screen's mid-call save arrives as a
    ``voice_accent_control`` data message; the agent hot-swaps to it."""
    monkeypatch.setattr(agent, "_await_heads_up", _no_heads_up)
    session = _seeded_session()
    _new_sessions_speak(session)
    factory = _Factory()
    sw = _swapper(session, factory, accent_block=_real_accent_block)
    on_data = agent.voice_accent_control_handler(sw)

    async def _run():
        on_data(_pkt(
            agent.TOPIC_VOICE_ACCENT_CONTROL, {"accent": "indian", "language": ""}
        ))
        assert sw._task is not None
        await sw._task

    asyncio.run(_run())
    assert factory.calls == [("Aoede", "indian", "vertex")]
    assert "indian" in session.current_agent.instructions


def test_voice_accent_control_ignores_noise():
    session = _seeded_session()
    factory = _Factory()
    sw = _swapper(session, factory)
    on_data = agent.voice_accent_control_handler(sw)
    on_data(_pkt("agent_mute_control", {"muted": False}))  # wrong topic
    on_data(_Packet(agent.TOPIC_VOICE_ACCENT_CONTROL, b"\xff\xfe"))  # bad bytes
    on_data(_Packet(agent.TOPIC_VOICE_ACCENT_CONTROL, b"[1,2]"))  # not a dict
    on_data(_pkt(agent.TOPIC_VOICE_ACCENT_CONTROL, {}))  # nothing asked
    on_data(_pkt(agent.TOPIC_VOICE_ACCENT_CONTROL, {"accent": 123}))  # not text
    assert sw._task is None and factory.calls == []
