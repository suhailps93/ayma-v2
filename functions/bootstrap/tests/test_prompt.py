from prompt import compose_system_prompt, load_persona


def test_persona_loads_from_markdown():
    persona = load_persona()
    assert persona
    lowered = persona.lower()
    for trait in ("warm", "witty", "direct", "nurturing"):
        assert trait in lowered
    assert "mood-mirroring" in lowered


def test_compose_system_prompt_includes_persona():
    assert load_persona() in compose_system_prompt()
