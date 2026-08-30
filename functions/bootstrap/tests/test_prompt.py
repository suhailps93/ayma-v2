from prompt import compose_system_prompt, load_persona
from transcript import Turn


def test_persona_loads_from_markdown():
    persona = load_persona()
    assert persona
    lowered = persona.lower()
    for trait in ("warm", "witty", "direct", "nurturing"):
        assert trait in lowered
    assert "mood-mirroring" in lowered


def test_compose_system_prompt_includes_persona():
    assert load_persona() in compose_system_prompt()


def test_compose_system_prompt_appends_recent_turns():
    prompt = compose_system_prompt(
        recent_turns=[
            Turn(role="user", text="I sail on weekends"),
            Turn(role="ayma", text="nice — where do you go?"),
        ]
    )
    assert load_persona() in prompt
    assert "User: I sail on weekends" in prompt
    assert "Ayma: nice — where do you go?" in prompt


def test_compose_system_prompt_ignores_empty_turn_list():
    assert compose_system_prompt(recent_turns=[]) == compose_system_prompt()


def test_compose_system_prompt_places_wiki_before_recent_turns():
    prompt = compose_system_prompt(
        recent_turns=[Turn(role="user", text="latest thing")],
        wiki_context="What you know:\n### interests — pottery\nThrows pots.",
    )
    assert load_persona() in prompt
    assert "Throws pots." in prompt
    # §13.5 order: persona, then wiki, then recent turns
    assert prompt.index("Throws pots.") < prompt.index("latest thing")


def test_compose_system_prompt_ignores_blank_wiki_context():
    assert compose_system_prompt(wiki_context="   ") == compose_system_prompt()


def test_marketing_mode_prepends_the_restricted_instructions():
    prompt = compose_system_prompt(session_mode="marketing")
    assert load_persona() in prompt
    lowered = prompt.lower()
    assert "marketing" in lowered
    assert "get started" in lowered
    # placed right after the persona, before wiki/turns
    persona_end = prompt.index(load_persona()) + len(load_persona())
    assert "MARKETING" in prompt[persona_end:persona_end + 400]


def test_interview_mode_prepends_the_interview_instructions():
    prompt = compose_system_prompt(session_mode="interview")
    assert "INTERVIEW" in prompt
    assert "preboarding" in prompt.lower()


def test_active_and_unknown_modes_add_nothing():
    base = compose_system_prompt()
    assert compose_system_prompt(session_mode="active") == base
    assert compose_system_prompt(session_mode="whatever") == base
