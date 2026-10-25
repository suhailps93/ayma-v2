"""Mid-call voice hot swap (agent.py ``VoiceSwapper``) and the live variant of
``set_voice_preference``: the Live session is rebuilt in the new voice with the
conversation carried over once, a context note + confirmation instruction on the
new agent, and every session-level relay (metrics, transcripts…) untouched."""

import asyncio

import pytest

pytest.importorskip("livekit.agents")
pytest.importorskip("livekit.plugins.google.realtime")

from livekit.agents import Agent, AgentSession, llm  # noqa: E402

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


def _swapper(session, factory, *, route="vertex", voice="Aoede", language=""):
    sw = agent.VoiceSwapper(
        session,
        system_prompt="SYSTEM PROMPT",
        route=route,
        voice_name=voice,
        voice_language=language,
        model_factory=factory,
    )
    sw.tools = []
    return sw


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
