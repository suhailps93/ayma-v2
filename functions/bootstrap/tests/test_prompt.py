import prompt as prompt_mod
from prompt import compose_system_prompt, load_persona
from transcript import Turn


def _reset_lessons_cache(monkeypatch):
    monkeypatch.setattr(prompt_mod, "_lessons_cache", {"raw": None, "loaded_at": 0.0})


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


def test_no_lessons_file_adds_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(prompt_mod, "_LESSONS_PATH", tmp_path / "absent.md")
    assert prompt_mod.load_lessons() == ""


class _NoConfigDb:
    """Firestore stub with no `config/ayma_persona` doc at all."""

    class _Snap:
        exists = False

    class _Doc:
        def get(self_):
            return _NoConfigDb._Snap()

    class _Col:
        def document(self_, _id):
            return _NoConfigDb._Doc()

    def collection(self, _name):
        return self._Col()


class _ConfigDb:
    """Firestore stub whose `config/ayma_persona` doc holds `lessons_md`."""

    def __init__(self, lessons_md: str):
        self._lessons_md = lessons_md

    class _Snap:
        exists = True

        def __init__(self, lessons_md):
            self._lessons_md = lessons_md

        def to_dict(self):
            return {"lessons_md": self._lessons_md}

    def collection(self, name):
        assert name == "config"
        db = self

        class _Col:
            def document(self_, doc_id):
                assert doc_id == "ayma_persona"

                class _Doc:
                    def get(self_):
                        return _ConfigDb._Snap(db._lessons_md)

                return _Doc()

        return _Col()


def test_load_lessons_falls_back_to_the_static_file_when_firestore_has_no_doc(
    tmp_path, monkeypatch
):
    f = tmp_path / "lessons.md"
    f.write_text("- Static seed bullet.\n", encoding="utf-8")
    monkeypatch.setattr(prompt_mod, "_LESSONS_PATH", f)
    _reset_lessons_cache(monkeypatch)
    assert prompt_mod.load_lessons(db=_NoConfigDb()) == "- Static seed bullet."


def test_load_lessons_prefers_firestore_when_the_config_doc_exists(
    tmp_path, monkeypatch
):
    f = tmp_path / "lessons.md"
    f.write_text("- Static seed bullet.\n", encoding="utf-8")
    monkeypatch.setattr(prompt_mod, "_LESSONS_PATH", f)
    _reset_lessons_cache(monkeypatch)
    db = _ConfigDb("- Firestore-updated bullet.\n- Second bullet.\n")
    assert prompt_mod.load_lessons(db=db) == (
        "- Firestore-updated bullet.\n- Second bullet."
    )


def test_load_lessons_caches_the_firestore_read_within_the_ttl(
    tmp_path, monkeypatch
):
    _reset_lessons_cache(monkeypatch)
    calls = {"n": 0}

    class _CountingDb(_ConfigDb):
        def collection(self, name):
            calls["n"] += 1
            return super().collection(name)

    db = _CountingDb("- Cached bullet.\n")
    assert prompt_mod.load_lessons(db=db) == "- Cached bullet."
    assert prompt_mod.load_lessons(db=db) == "- Cached bullet."
    assert calls["n"] == 1  # second call served from the TTL cache


def test_no_db_given_always_reads_the_static_file(tmp_path, monkeypatch):
    f = tmp_path / "lessons.md"
    f.write_text("- Static only.\n", encoding="utf-8")
    monkeypatch.setattr(prompt_mod, "_LESSONS_PATH", f)
    _reset_lessons_cache(monkeypatch)
    assert prompt_mod.load_lessons(db=None) == "- Static only."


def test_lessons_md_override_is_used_verbatim_for_the_eval_gate():
    prompt = compose_system_prompt(lessons_md_override="- Candidate bullet.\n")
    assert "Corrections from past user feedback" in prompt
    assert "Candidate bullet" in prompt


def test_blank_lessons_md_override_adds_no_lessons_layer():
    prompt = compose_system_prompt(lessons_md_override="")
    assert "Corrections from past user feedback" not in prompt


def test_persona_loads_from_markdown():
    persona = load_persona()
    assert persona
    lowered = persona.lower()
    for trait in ("warm", "witty", "direct", "nurturing"):
        assert trait in lowered
    assert "mood-mirroring" in lowered


def test_compose_system_prompt_includes_persona():
    assert load_persona() in compose_system_prompt()


def test_persona_has_register_matching_guidance():
    lowered = load_persona().lower()
    assert "matching their register" in lowered
    # meet a flirty/crude user, don't refuse or lecture
    assert "flirty" in lowered
    assert "never a cold refusal" in lowered
    # safety lines are kept
    assert "minors" in lowered


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
