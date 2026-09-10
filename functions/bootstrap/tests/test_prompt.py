import prompt as prompt_mod
from prompt import compose_system_prompt, load_persona
from transcript import Turn


def test_lessons_layer_appends_only_bullet_lines(tmp_path, monkeypatch):
    f = tmp_path / "lessons.md"
    f.write_text(
        "<!-- header comment -->\n\n"
        "# not a bullet\n"
        "- Check the wiki before asking; never re-ask an answered question.\n"
        "- Keep to one question per turn.\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(prompt_mod, "_LESSONS_PATH", f)
    prompt_mod.load_lessons.cache_clear()
    try:
        out = prompt_mod.load_lessons()
        assert out == (
            "- Check the wiki before asking; never re-ask an answered "
            "question.\n- Keep to one question per turn."
        )
        composed = compose_system_prompt()
        assert "Corrections from past user feedback" in composed
        assert "never re-ask an answered question" in composed
        # right after the persona, before mode/wiki/turns
        assert composed.index("never re-ask") < len(load_persona()) + 400
    finally:
        prompt_mod.load_lessons.cache_clear()


def test_no_lessons_file_adds_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(prompt_mod, "_LESSONS_PATH", tmp_path / "absent.md")
    prompt_mod.load_lessons.cache_clear()
    try:
        assert prompt_mod.load_lessons() == ""
    finally:
        prompt_mod.load_lessons.cache_clear()


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


def test_profile_progress_note_follows_the_mode_prompt():
    note = "PREBOARDING PROGRESS — do NOT ask again: name, where they live."
    prompt = compose_system_prompt(
        session_mode="interview",
        profile_progress=note,
        wiki_context="What you know:\n### x — y\nZ.",
    )
    assert note in prompt
    # after the interview instructions, before the wiki block
    assert prompt.index("INTERVIEW") < prompt.index(note) < prompt.index("Z.")


def test_blank_profile_progress_adds_nothing():
    assert (
        compose_system_prompt(session_mode="interview", profile_progress="  ")
        == compose_system_prompt(session_mode="interview")
    )


def test_active_and_unknown_modes_add_nothing():
    base = compose_system_prompt()
    assert compose_system_prompt(session_mode="active") == base
    assert compose_system_prompt(session_mode="whatever") == base


def test_questionnaire_note_renders_with_its_label():
    note = (
        "QUESTIONNAIRE — their profile is 40% complete. Weave one question in.\n"
        "Their relationship intent isn't set yet."
    )
    prompt = compose_system_prompt(
        session_mode="active",
        questionnaire_note=note,
        wiki_context="What you know:\n### x — y\nZ.",
    )
    assert note in prompt
    # before the wiki block
    assert prompt.index(note) < prompt.index("Z.")


def test_blank_questionnaire_note_is_a_no_op():
    assert (
        compose_system_prompt(session_mode="active", questionnaire_note="  ")
        == compose_system_prompt(session_mode="active")
    )


def test_questionnaire_guidance_layer_is_always_present():
    # persona.md points at it; prompt.py loads prompts/questionnaire.md
    assert "Working through the questionnaire" in compose_system_prompt()


def test_viewing_profile_context_is_the_last_layer():
    prompt = compose_system_prompt(
        recent_turns=[Turn(role="user", text="what do you think of them")],
        viewing_profile_context="They value stability; you crave novelty.",
    )
    assert "They value stability" in prompt
    assert prompt.index("what do you think of them") < prompt.index(
        "They value stability"
    )
