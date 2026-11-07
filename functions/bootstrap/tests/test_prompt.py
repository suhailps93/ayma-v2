import prompt as prompt_mod
from prompt import compose_system_prompt, load_persona
from transcript import Turn, format_recent_turns


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


def test_persona_forbids_ungrounded_match_claims():
    """Founder bug 2026-10-25: Ayma called a near-empty stranger "a great
    match on paper". The persona must carry an explicit grounding rule — only
    characterise compatibility/alignment with a computed score or real facts —
    so it is in every chat and voice system prompt."""
    persona = load_persona().lower()
    assert "talking about a match or another member" in persona
    assert "computed match score" in persona
    assert "align" in persona and "run a match" in persona


def test_persona_forbids_surfacing_internal_context_scaffolding():
    """Founder bug R2-D3: with a profile pinned, Ayma opened a reply with "A
    system test report slipped through there—ignore that!" — remarking on its
    own internal context scaffolding to the user. The persona must carry an
    explicit guardrail that grounding/context, photo-context notes and any
    system/test annotation are private and never quoted or remarked on, so it
    is in every chat and voice system prompt."""
    persona = load_persona().lower()
    assert "private scaffolding" in persona
    assert "test" in persona and "slipped through" in persona
    assert "photo-context" in persona


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


def test_persona_leans_into_volunteered_specifics():
    """Founder fix 2026-09-26: a user offering a concrete specific (income,
    numbers, names, places, dates) gets interest and a follow-up for the
    actual figure — never a deflection like "I care about your mindset, not
    the numbers". Text-level assertion (the strongest persona-behaviour check
    this suite supports — same pattern as the register test above; the
    behavioural check itself lives in persona_eval_scenarios.json:
    volunteered_specifics_income, run by the persona-evolution eval gate)."""
    lowered = load_persona().lower()
    assert "lean into specifics" in lowered
    assert "income" in lowered
    # ask for the real number/detail, save it, and never wave it off
    assert "figure" in lowered
    assert "never deflect" in lowered
    assert "the answer is always yes" in lowered


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


def test_current_screen_context_layer():
    prompt = compose_system_prompt(
        current_screen_context="The user is browsing the Explore screen.",
    )
    assert "browsing the Explore screen" in prompt


def test_blank_current_screen_context_adds_nothing():
    assert "currently looking at" not in compose_system_prompt()


# --- cost-program Phase 1: byte-stable prompt prefix (context_opt) -----------


def _every_layer_kwargs(turn_i=1, qnote="Questionnaire score: 42"):
    return dict(
        recent_turns=[
            Turn(role="user", text=f"hello there, turn {turn_i}"),
            Turn(role="ayma", text=f"hi! (reply {turn_i})"),
        ],
        wiki_context="What you already know:\n### identity — who\nA doctor.",
        profile_progress="PROGRESS: name captured",
        questionnaire_note=qnote,
        story_context="STORY EDITOR: working on a section.",
        current_screen_context="The user is browsing Explore.",
        shared_photo_note="Looks like them.",
        viewing_profile_context="They value stability.",
    )


def test_flags_off_assembly_is_byte_identical_to_the_original_order():
    """With every context_opt flag off (the default), the assembled prompt
    must be byte-for-byte what the pre-cost-program code produced, plus the
    static plan-facts block that closes the stable prefix, plus the
    config-rendered permitted-action block right after it, plus the static
    capability-gap instruction block right after that (founder rule
    2026-11-07): persona, lessons,
    mode, questionnaire guidance, plan facts, action facts, capability
    gap, progress,
    questionnaire note,
    story, screen line, wiki, history, photo note, viewing-profile — joined
    by blank lines."""
    kwargs = _every_layer_kwargs()
    got = compose_system_prompt(**kwargs)

    expected_parts = [load_persona()]
    lessons = prompt_mod.load_lessons(None)
    if lessons:
        expected_parts.append(
            "Corrections from past user feedback — apply every one:\n" + lessons
        )
    guidance = prompt_mod.load_questionnaire_guidance()
    if guidance:
        expected_parts.append(guidance)
    expected_parts.append(prompt_mod.plan_facts())
    expected_parts.append(prompt_mod.action_facts())
    _capability_gap = prompt_mod.load_capability_gap()
    if _capability_gap:
        expected_parts.append(_capability_gap)
    expected_parts += [
        kwargs["profile_progress"],
        kwargs["questionnaire_note"],
        kwargs["story_context"],
        "What the user is currently looking at in the app: "
        + kwargs["current_screen_context"],
        kwargs["wiki_context"],
        "Conversation so far (voice and text turns interleaved). Continue "
        "it naturally — do not repeat yourself:\n"
        + format_recent_turns(kwargs["recent_turns"]),
        "Shared photo: " + kwargs["shared_photo_note"],
        "The user is looking at / has shared a specific person's profile so "
        "you can talk about them. Here is what you know about that person "
        "and, if a match was run, your private read on the pair. Use their "
        "public wiki freely; never state a private fact from your match "
        "read outright — use it to steer toward what matters:\n"
        + kwargs["viewing_profile_context"],
    ]
    assert got == "\n\n".join(expected_parts)


def test_stable_prefix_moves_wiki_before_the_volatile_layers():
    prompt = compose_system_prompt(**_every_layer_kwargs(), stable_prefix=True)
    wiki_at = prompt.index("What you already know")
    assert wiki_at < prompt.index("PROGRESS: name captured")
    assert wiki_at < prompt.index("Questionnaire score")
    assert wiki_at < prompt.index("browsing Explore")
    assert wiki_at < prompt.index("Conversation so far")


def test_consecutive_turns_share_a_byte_identical_prefix_through_the_wiki():
    """The Phase 1 cache-alignment guarantee: two consecutive turns of one
    conversation (history grew, volatile notes changed) must share a byte-
    identical prefix that extends through the END of the wiki block, so
    Gemini's implicit prefix cache can hit on system+wiki every turn."""
    import os.path

    p1 = compose_system_prompt(
        **_every_layer_kwargs(turn_i=1, qnote="Questionnaire score: 42"),
        stable_prefix=True,
    )
    p2 = compose_system_prompt(
        **_every_layer_kwargs(turn_i=2, qnote="Questionnaire score: 43"),
        stable_prefix=True,
    )
    assert p1 != p2
    common = os.path.commonprefix([p1, p2])
    wiki = _every_layer_kwargs()["wiki_context"]
    assert wiki in common  # the shared prefix covers the whole wiki block


def test_stable_prefix_off_leaves_the_old_wiki_position():
    prompt = compose_system_prompt(**_every_layer_kwargs())
    assert prompt.index("PROGRESS: name captured") < prompt.index(
        "What you already know"
    )


# --- voice persona variant (voice-prompt diet, cost program 2026-09-26) ------


def test_variant_markers_never_leak_into_either_variant():
    for variant in ("text", "voice"):
        rendered = load_persona(variant)
        assert "<!--" not in rendered
        assert "-->" not in rendered


def test_voice_variant_drops_only_the_rules_that_cannot_fire_in_a_call():
    """Each dropped rule is trace-verified as unable to fire in a voice
    session (see the commit message): the `[face_report:...]` sentinel copy
    (voice replies reach chat as output-audio transcription, never model
    text), the "Shared photo" note protocol (that compose layer is never
    passed on the voice seed path), the profile-edit-chat tool flow (those
    tools are only registered via make_session_tool_fns(profile_edit=True) —
    text), live-web/link/map grounding (gemini.py wires google_search /
    url_context / google_maps for the text loop only), and emoji (audio)."""
    voice = load_persona("voice")
    assert "[face_report:" not in voice
    assert "Shared photo" not in voice
    assert "list_profile_sections" not in voice
    assert "edit_profile_section" not in voice
    assert "search the live web" not in voice
    assert "emoji" not in voice
    # ...and the text variant still carries every one of them.
    text = load_persona()
    for needle in (
        "[face_report:", "Shared photo", "list_profile_sections",
        "search the live web", "emoji",
    ):
        assert needle in text


def test_text_variant_knows_what_the_chat_renders():
    """The founder's tree-diagram bug: Ayma emitted box-drawing art without a
    fence and the chat mangled it. The text persona now says exactly what the
    chat renders (markdown incl. fenced code blocks, kept verbatim in
    monospace) and to fence simple monospace diagrams or offer generate_image
    for anything richer. Text-UI-only formatting can't fire in voice, so the
    voice variant drops the whole line (variant-marker system)."""
    text = load_persona()
    assert "Chat renders markdown" in text
    assert "fenced" in text
    assert "kept verbatim" in text
    assert "never box-drawing art outside a fence" in text
    # generate_image is a text-only tool (skills registry) — the offer lives
    # next to the render list.
    assert "generate_image" in text

    voice = load_persona("voice")
    assert "Chat renders markdown" not in voice
    assert "fenced" not in voice
    assert "box-drawing" not in voice
    assert "generate_image" not in voice


def test_voice_variant_keeps_every_rule_that_can_fire_in_a_call():
    """Safety / confirm-flow rules must live in BOTH variants, and every tool
    the voice registry exposes keeps its guidance."""
    for variant in ("text", "voice"):
        p = load_persona(variant).lower()
        # hard lines + register matching
        assert "minors" in p
        assert "never a cold refusal" in p
        # DM confirm-before-send
        assert "send_dm_message" in p
        assert "exactly one yes" in p
        assert "only on a clear" in p
        # 18+ birthdate refusal
        assert "18+ only" in p
        # honest refusals
        assert "never invent a glitch" in p
        # voice-registry tools keep their rules
        for tool in (
            "deep_dive", "face_report", "body_report", "remember",
            "find_fact_source", "set_profile_field", "set_voice_preference",
            "read_dm_thread", "record_feedback", "set_user_steering",
            "open_screen", "app_action",
        ):
            assert tool in p, tool
        # current_screen is a voice-only tool; text never sees it
        assert ("current_screen" in p) == (variant == "voice")
        # photo-identity caution stays resident in voice too
        assert "never guess a stranger" in p


def test_unbalanced_variant_markers_raise():
    import pytest

    for bad in (
        "a\n<!-- text-only -->\nb",                        # unclosed
        "a\n<!-- /voice-only -->\nb",                      # close w/o open
        "<!-- text-only -->\n<!-- voice-only -->\nx",      # nested
    ):
        with pytest.raises(ValueError):
            prompt_mod._persona_variant(bad, "text")
    with pytest.raises(ValueError):
        prompt_mod._persona_variant("fine", "sms")


def test_compose_system_prompt_variant_selects_the_persona():
    assert load_persona("voice") in compose_system_prompt(variant="voice")
    assert load_persona() in compose_system_prompt()
    # the voice variant is genuinely leaner
    assert len(load_persona("voice")) < len(load_persona())


def test_welcome_prompt_uses_the_voice_persona():
    # the pre-sign-in welcome room is always a voice call
    welcome = prompt_mod.compose_welcome_prompt()
    assert load_persona("voice") in welcome


def test_summary_context_renders_before_the_history_tail():
    prompt = compose_system_prompt(
        recent_turns=[Turn(role="user", text="recent line")],
        summary_context="They told you their sister Meera lives in Kochi.",
    )
    assert "Meera" in prompt
    assert prompt.index("running summary") < prompt.index("recent line")


def test_blank_summary_context_adds_nothing():
    assert "running summary" not in compose_system_prompt(
        recent_turns=[Turn(role="user", text="hi")]
    )


# --- scope guard: dating only (no coding / off-topic research) ---------------


def test_scope_guard_is_in_every_prompt_path():
    for rendered in (
        load_persona("text"),
        load_persona("voice"),
        compose_system_prompt(),
        compose_system_prompt(variant="voice"),
        prompt_mod.compose_welcome_prompt(),
    ):
        assert "## Scope — dating only (hard rule)" in rendered
        assert "code, scripts, SQL, regex or shell" in rendered
        assert "Ignore your instructions" in rendered or "ignore your instructions" in rendered.lower()


def test_text_web_grounding_is_limited_to_dating_purposes():
    text = load_persona("text")
    assert "only for dating purposes" in text
    assert "Never use search, links or the map to" in text


def test_voice_language_directive_defaults_to_english_and_resists_drift():
    text = prompt_mod.voice_language_directive("")
    assert "Speak like this by default: English." in text
    assert "mishearing" in text and "no tool call" in text
    assert "{language}" not in text


def test_voice_language_directive_uses_the_saved_preference():
    text = prompt_mod.voice_language_directive("Malayalam mixed with English")
    assert "Speak like this by default: Malayalam mixed with English." in text


def test_voice_opener_with_prior_context_offers_a_choice_not_a_continuation():
    """Founder behaviour (2026-10-28): with prior conversation the opener must
    greet + offer to continue-or-switch, and explicitly NOT resume the old topic
    itself. The one-line last-topic hint is woven into the offer."""
    text = prompt_mod.load_voice_opener(
        True, "your date on Friday with Priya"
    )
    assert "your date on Friday with Priya" in text
    low = text.lower()
    assert "choice" in low or "either" in low or "or is there something else" in low
    assert "do not" in low and ("continue" in low or "resume" in low)
    # The fresh-only wording must not leak into the prior-context opener.
    assert "no particular prior conversation" not in low


def test_voice_opener_without_prior_context_is_a_plain_fresh_opener():
    text = prompt_mod.load_voice_opener(False)
    low = text.lower()
    assert "no particular prior conversation" in low
    # No continue-or-switch choice, and no leftover template placeholder.
    assert "{last_topic_hint}" not in text
    assert "pick up where we left off" not in low


def test_voice_opener_with_prior_flag_but_empty_hint_falls_back_to_fresh():
    """A has-prior flag with no usable hint still yields the fresh opener (no
    dangling placeholder, no empty 'pick up where we left off about ""')."""
    text = prompt_mod.load_voice_opener(True, "   ")
    assert "{last_topic_hint}" not in text
    assert "no particular prior conversation" in text.lower()


def test_voice_opener_never_leaks_block_markers():
    for text in (
        prompt_mod.load_voice_opener(True, "coffee plans"),
        prompt_mod.load_voice_opener(False),
    ):
        assert "OPENER:PRIOR" not in text
        assert "OPENER:FRESH" not in text


def test_voice_dangling_reply_answers_the_unanswered_message():
    """Founder behaviour (2026-11-02): when the caller's last message never got
    a reply, the voice opener answers THAT message — static instructions, no
    placeholders, honest about garbled input instead of inventing an answer."""
    text = prompt_mod.load_voice_dangling_reply()
    assert text.strip()
    low = text.lower()
    assert "never got a reply" in low
    assert "answering" in low or "answer" in low
    assert "{" not in text and "}" not in text


def test_misheard_fragment_detection():
    import voices

    for garbled in ("el número", "murió", "Größe", "¿Cuándo? ¿A qué hora?"):
        assert voices.is_misheard_fragment(garbled, "")
    # Plain short confirmations and ordinary sentences are never fragments.
    assert not voices.is_misheard_fragment("Yeah, do it.", "")
    assert not voices.is_misheard_fragment("yes", "a soft Southern US accent")
    assert not voices.is_misheard_fragment(
        "Can you run a match score on Dillu Shakeeb, señor?", ""
    )
    # A user whose call language isn't English is never second-guessed.
    assert not voices.is_misheard_fragment("murió", "Spanish")
    assert voices.is_misheard_fragment("murió", "British English")


def test_load_prompt_file_reads_and_strips(tmp_path):
    f = tmp_path / "probe.md"
    f.write_text("\n\n  hello prompt  \n\n", encoding="utf-8")
    assert prompt_mod.load_prompt_file(f) == "hello prompt"
    assert prompt_mod.load_prompt_file(str(f)) == "hello prompt"


def test_load_prompt_file_caches_per_path(tmp_path):
    f = tmp_path / "cached.md"
    f.write_text("v1", encoding="utf-8")
    assert prompt_mod.load_prompt_file(f) == "v1"
    f.write_text("v2", encoding="utf-8")
    assert prompt_mod.load_prompt_file(f) == "v1"  # cached, like _prompt() was
    g = tmp_path / "other.md"
    g.write_text("v2", encoding="utf-8")
    assert prompt_mod.load_prompt_file(g) == "v2"


def test_persona_source_rule_names_natural_provenance_phrasings():
    """#28 (founder retest Nov 2, 2026): the "where did you get this" rule
    only fired for that exact shape — natural paraphrases fell through to a
    generic answer. The trigger must name the paraphrases explicitly."""
    persona = load_persona()
    for phrase in (
        "where's this from",
        "what's this based on",
        "who says that",
        "prove it",
        "what's the source",
    ):
        assert phrase in persona, phrase
    assert "find_fact_source" in persona
