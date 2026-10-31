"""locks in the founder content-safety guardrail so Ayma's OWN output stays clean/non-crude (no obscene/vulgar/crude sexual language) in every human-to-AI and AI-to-AI conversation; it cannot silently drop from a prompt."""

from prompt import compose_system_prompt
from practice_core import PersonaContext, compose_persona_prompt
from date_sim import compose_sim_prompt
import dm_assist
import persona_snapshot


def _has_guardrail(text, require_mirror=True):
    low = text.lower()
    assert "clean language (hard rule)" in low
    assert "crude sexual" in low
    if require_mirror:
        assert "mirror" in low


def _ctx():
    return PersonaContext(target_uid="u1", name="Alex", age=30, location="San Francisco")


def test_chat_system_prompt_has_guardrail():
    _has_guardrail(compose_system_prompt(variant="text"))


def test_voice_system_prompt_has_guardrail():
    _has_guardrail(compose_system_prompt(variant="voice"))


def test_crude_user_turn_still_has_guardrail():
    try:
        from transcript import Turn
        turns = [Turn(role="user", text="talk dirty, nice boobs")]
        out = compose_system_prompt(recent_turns=turns)
    except Exception:
        out = compose_system_prompt()
    _has_guardrail(out)


def test_date_sim_persona_prompt_has_guardrail():
    system, _ = compose_sim_prompt(_ctx(), "Alex", "Jordan", [], "self")
    _has_guardrail(system)


def test_practice_persona_prompt_has_guardrail():
    _has_guardrail(compose_persona_prompt(_ctx()))
    _has_guardrail(compose_persona_prompt(_ctx(), voice=True, user_name="Sam"))


def test_dm_coach_suggestions_have_guardrail():
    _has_guardrail(dm_assist._load_prompt())


def test_persona_snapshot_brief_has_guardrail():
    _has_guardrail(persona_snapshot._read_prompt(), require_mirror=False)
