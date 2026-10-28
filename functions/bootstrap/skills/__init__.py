"""Skills / tools registry (ARCHITECTURE.md §13.6).

Every agent tool is defined once as a :class:`~skills._base.Skill` and exposed
here in the two forms the callers need — identical behaviour in both:

* ``/chat`` (text): :func:`session_tool_declarations` + :func:`make_session_tool_fns`
  feed ``gemini.generate_reply``'s manual function-calling loop.
* ``agent.py`` (voice): :func:`make_livekit_tools` wraps the same bound
  callables as livekit-agents ``function_tool``\\ s.

Adding a tool = one module under ``skills/`` and one line in ``_REGISTRY``.
``set_voice_preference`` (§13.3), the matching skill (§5.4) and Explore's NL
filter parser (§6.2) land here in their own steps.
"""

from __future__ import annotations

import functools
import inspect
from typing import Callable

from . import (
    app_control,
    body_report,
    deep_dive,
    dm_outreach,
    face_report,
    fact_source,
    followup,
    physical_attributes,
    questionnaire,
    read_dm_thread,
    recall,
    record_feedback,
    remember,
    report_bug,
    set_profile_field,
    set_voice_preference,
    submit_feedback,
    user_steering,
)
from tool_labels import outcome_label

from ._base import Skill


def _recall_skills() -> list[Skill]:
    """The ``recall`` tool, present only at CONTEXT_OPT_LEVEL >= 3 (context_opt
    Phase 3 — the standing wiki context shrinks to the core card and
    everything else is recall-on-demand). Below level 3 the tool set is
    exactly what it was before the cost program. Checked per call, not at
    import, so the flag flips without a restart."""
    import context_opt

    return [recall.SKILL] if context_opt.recall_enabled() else []

_REGISTRY: list[Skill] = [
    followup.SKILL,
    set_profile_field.SKILL,
    set_voice_preference.SKILL,
    record_feedback.SKILL,
    report_bug.SKILL,
    user_steering.SKILL,
    remember.SKILL,
    read_dm_thread.SKILL,
    *dm_outreach.SKILLS,
    deep_dive.SKILL,
    face_report.SKILL,
    body_report.SKILL,
    physical_attributes.SKILL,
    *questionnaire.SKILLS,
    fact_source.SKILL,
]

# send_dm_message (dm_outreach.py) keeps its pending send in the
# same per-session doc `remember` uses (keyed by session_id) and checks the
# user's own latest line in the turn window before sending, so it takes the
# session_id and the turns.
_DM_OUTREACH_NAMES = {s.name for s in dm_outreach.SKILLS}

# These tools write a fact straight from what the user just said, so they
# take the full session_ctx (session_id/turn_index/turns) too — the current
# turn's user message is the provenance quote `find_fact_source` later
# attributes the write to (§ fact-source-of-truth, 2026-09-21).
_PROVENANCE_NAMES = {"set_profile_field", "record_answer", "set_relationship_intent"}


from . import edit_profile_section, photo_edit, story_edit, story_manage, deep_dive_edit, appearance_edit, generate_image  # noqa: E402

# Always in the TEXT tool set, never in voice: ``generate_image`` delivers its
# image through the same mutable ``result`` sink ``edit_photo`` uses
# (``main._ChatCtx.photo_edit_result`` → the chat reply's ``image_url`` + the
# durable transcript), and voice (agent.py) has no such delivery surface — a
# voice call has nowhere to show a generated image, so exposing the tool there
# would only let the model claim to send images it can't.
_TEXT_ONLY_REGISTRY: list[Skill] = [generate_image.SKILL]

# Text-only like ``generate_image``, but delivered through its OWN sink
# (``main._ChatCtx.feedback_draft`` → the reply's ``feedback_card``) rather
# than the photo sink: ``submit_feedback`` drafts a confirmation card the user
# reviews and sends. Voice has no surface to show/edit a card, so it is never
# in the voice tool set (``_REGISTRY``).
_FEEDBACK_REGISTRY: list[Skill] = [submit_feedback.SKILL]

# Always in the TEXT tool set, never in voice (``_REGISTRY`` → ``make_livekit_
# tools``): ``edit_story_entry`` / ``remove_story_entry`` let Ayma change or
# soft-remove a section of the user's OWN story/wiki straight from an ordinary
# chat (the editor-only passage tools below need a page + highlighted passage
# in focus). Text-only, like ``generate_image`` — kept out of voice to leave
# agent.py's tool set untouched; a story edit is a text-surface action.
_STORY_MANAGE_REGISTRY: list[Skill] = list(story_manage.SKILLS)

# Only exposed when the chat is opened from the Your Story editor (§ Your Story).
_STORY_REGISTRY: list[Skill] = list(story_edit.SKILLS)
_STORY_NAMES = {s.name for s in _STORY_REGISTRY}

# Only exposed when the chat is opened to edit the user's own public profile.
_PROFILE_EDIT_REGISTRY: list[Skill] = list(edit_profile_section.SKILLS)

# Only exposed when the chat is opened from "Chat about it" on one photo.
_PHOTO_REGISTRY: list[Skill] = list(photo_edit.SKILLS)

# Only exposed when the chat is opened from one item on the deep-dive
# (web-search) report — a fact, the summary, a social link, or a photo.
_DEEP_DIVE_EDIT_REGISTRY: list[Skill] = list(deep_dive_edit.SKILLS)

# Only exposed when the chat is opened from one finding on the Appearance
# report — an attribute, the face report, or the physique/body report.
_APPEARANCE_EDIT_REGISTRY: list[Skill] = list(appearance_edit.SKILLS)


def all_skills() -> list[Skill]:
    return list(_REGISTRY)


def session_tool_declarations(
    *,
    story: bool = False,
    profile_edit: bool = False,
    photo: bool = False,
    deep_dive: bool = False,
    appearance: bool = False,
) -> list[dict]:
    """Gemini function declarations for every registered skill (text always
    also gets the text-only tools — ``generate_image``). ``story=True``
    adds the Your Story passage-edit tools; ``profile_edit=True`` adds the
    public-profile section-edit tools; ``photo=True`` adds the photo-note
    tool; ``deep_dive=True`` adds the web-search-report correct/remove tools;
    ``appearance=True`` adds the Appearance-report correct/clear tools."""
    reg = (
        list(_REGISTRY) + _recall_skills() + _TEXT_ONLY_REGISTRY
        + _FEEDBACK_REGISTRY + _STORY_MANAGE_REGISTRY + app_control.COMMAND_SKILLS
    )
    if story:
        reg += _STORY_REGISTRY
    if profile_edit:
        reg += _PROFILE_EDIT_REGISTRY
    if photo:
        reg += _PHOTO_REGISTRY
    if deep_dive:
        reg += _DEEP_DIVE_EDIT_REGISTRY
    if appearance:
        reg += _APPEARANCE_EDIT_REGISTRY
    return [s.declaration for s in reg]


def make_session_tool_fns(
    db,
    uid: str,
    *,
    session_ctx: dict | None = None,
    story_ctx: dict | None = None,
    profile_edit: bool = False,
    photo_ctx: dict | None = None,
    image_path: str = "",
    deep_dive_ctx: dict | None = None,
    appearance_ctx: dict | None = None,
    image_result: dict | None = None,
    feedback_result: dict | None = None,
) -> dict[str, Callable[..., str]]:
    """``{name: bound callable}`` for ``gemini.generate_reply`` (text).

    ``session_ctx`` (``session_id`` / ``turn_index`` / ``turns``) is threaded
    into ``remember`` and into the fact-writing tools in ``_PROVENANCE_NAMES``
    (``set_profile_field`` / ``record_answer`` / ``set_relationship_intent`` —
    so each write can store the verbatim user quote it came from), and its
    ``session_id`` and ``turns`` into ``send_dm_message`` (dm_outreach.py —
    its one-confirmation send keeps a pending send in the per-session doc and
    reads the user's own latest line from ``turns``); ``story_ctx``
    (``page_id`` / ``passage``) adds and binds the Your Story passage-edit
    tools; ``profile_edit=True`` adds the public-profile section-edit tools;
    ``photo_ctx`` (``url`` / ``source`` / ``image`` — the resolved photo
    bytes / ``result`` — a mutable dict ``edit_photo`` writes its
    ``image_path``/``image_url`` into for the caller to read back) adds and
    binds the photo tools; ``image_path`` (the photo attached to this chat
    turn, if any) is threaded into ``analyze_physical_attributes`` and
    ``report_bug`` (so a bug report gets the screenshot attached to the same
    turn, if any, with no separate upload step); ``deep_dive_ctx``
    (``report_id`` / ``target``) adds and binds the deep-dive report
    correct/remove tools; ``appearance_ctx`` (``finding_id``) adds and binds
    the Appearance report correct/clear tools; ``image_result`` (the same
    mutable ``main._ChatCtx.photo_edit_result`` sink ``photo_ctx["result"]``
    carries) binds the text-only ``generate_image`` tool's delivery — the
    generated image's ``image_path``/``image_url`` land there for the caller
    to attach to the reply, exactly like ``edit_photo``'s; ``feedback_result``
    (``main._ChatCtx.feedback_draft``) binds the text-only ``submit_feedback``
    tool's delivery — the drafted ``{kind, title, body}`` lands there for the
    reply to carry to the client as ``feedback_card`` (nothing is persisted).
    Every other skill binds on ``(db, uid)`` alone.
    """
    out: dict[str, Callable[..., str]] = {}
    for s in (_REGISTRY + _recall_skills()):
        if s.name in ("remember", *_PROVENANCE_NAMES) and session_ctx:
            out[s.name] = s.bind(db, uid, **session_ctx)
        elif s.name in ("analyze_physical_attributes", "report_bug"):
            out[s.name] = s.bind(db, uid, image_path=image_path)
        elif s.name in _DM_OUTREACH_NAMES:
            out[s.name] = s.bind(
                db, uid,
                session_id=(session_ctx or {}).get("session_id", ""),
                turns=(session_ctx or {}).get("turns"),
            )
        else:
            out[s.name] = s.bind(db, uid)
    for s in _TEXT_ONLY_REGISTRY:
        out[s.name] = s.bind(db, uid, result=image_result)
    for s in _FEEDBACK_REGISTRY:
        # Its own sink (``feedback_result``), not the photo one — a drafted
        # feedback card is delivered to the client via the reply's
        # ``feedback_card`` field; nothing is persisted here.
        out[s.name] = s.bind(db, uid, result=feedback_result)
    for s in _STORY_MANAGE_REGISTRY:
        # Always-on story edit/soft-remove tools — bound on (db, uid) alone,
        # so they can only ever reach this authenticated user's own story.
        out[s.name] = s.bind(db, uid)
    for s in app_control.COMMAND_SKILLS:
        # account_action checks the confirmation against the user's own
        # latest message, so it needs this turn's transcript window.
        if s.name == "account_action" and session_ctx:
            out[s.name] = s.bind(db, uid, **session_ctx)
        else:
            out[s.name] = s.bind(db, uid)
    if story_ctx is not None:
        for s in _STORY_REGISTRY:
            out[s.name] = s.bind(db, uid, **story_ctx)
    if profile_edit:
        for s in _PROFILE_EDIT_REGISTRY:
            out[s.name] = s.bind(db, uid)
    if photo_ctx is not None:
        for s in _PHOTO_REGISTRY:
            out[s.name] = s.bind(db, uid, **photo_ctx)
    if deep_dive_ctx is not None:
        for s in _DEEP_DIVE_EDIT_REGISTRY:
            out[s.name] = s.bind(db, uid, **deep_dive_ctx)
    if appearance_ctx is not None:
        for s in _APPEARANCE_EDIT_REGISTRY:
            out[s.name] = s.bind(db, uid, **appearance_ctx)
    return out


def _instrumented(
    fn: Callable[..., object],
    name: str,
    on_call: Callable[[str, str, str | None], None],
) -> Callable[..., object]:
    """Wrap a bound skill callable (sync or async) so ``on_call`` fires once
    right before it runs and once right after it returns or raises — the one
    hook point ``make_livekit_tools`` uses to report every tool call, so voice
    (agent.py) never needs to touch individual skills.

    ``on_call(phase, name, label)``: ``label`` is ``None`` at start and, at
    end, :func:`tool_labels.outcome_label` of the result (``None`` unless the
    tool's chip depends on what it did, e.g. ``send_dm_message``).

    ``functools.wraps`` preserves ``fn``'s signature (livekit-agents' schema
    introspection follows ``__wrapped__``), and the "end" call happens in a
    ``finally`` so a raising tool still clears a client's "…ing" indicator.

    Both branches return an **async** wrapper, even when ``fn`` itself is a
    plain sync function. livekit-agents' ``function_tool`` is typed to accept
    only an awaitable-returning callable, and its executor unconditionally
    does ``await tool(...)`` (``voice/tool_executor.py::_execute_tool``) — a
    *sync* wrapper handed to it gets called (running the skill correctly) but
    then ``await``ed on its plain return value, which raises
    ``TypeError: object str can't be used in 'await' expression``. Every one
    of our sync skills (``read_dm_thread``, ``record_feedback``, etc. — most
    of the registry) hit this on every voice call: the SDK caught that
    TypeError and silently turned it into a generic
    ``"An internal error occurred"`` function response, so the model never
    saw the tool's real return value (success or failure) and improvised an
    excuse instead of relaying it. Making the sync branch ``async def`` (it
    still just calls ``fn`` directly — no thread offload, matching how the
    text-chat tool loop already calls these same skills) makes it truly
    awaitable and fixes this for every registered sync skill at once.
    """
    if inspect.iscoroutinefunction(fn):

        @functools.wraps(fn)
        async def _async_wrapper(*args, **kwargs):
            on_call("start", name, None)
            result = None
            try:
                result = await fn(*args, **kwargs)
                return result
            finally:
                on_call("end", name, outcome_label(name, result))

        return _async_wrapper

    @functools.wraps(fn)
    async def _sync_wrapper(*args, **kwargs):
        on_call("start", name, None)
        result = None
        try:
            result = fn(*args, **kwargs)
            return result
        finally:
            on_call("end", name, outcome_label(name, result))

    return _sync_wrapper


def _guarded(
    fn: Callable[..., object], guard: Callable[[], str | None]
) -> Callable[..., object]:
    """Wrap a voice tool so ``guard()`` is checked right before it runs: a
    non-``None`` return is handed back to the model as the tool result and
    the tool itself never runs (agent.py uses this to refuse tool calls
    triggered by a misheard speech fragment). Always async, for the same
    reason as :func:`_instrumented`."""

    @functools.wraps(fn)
    async def _wrapper(*args, **kwargs):
        refusal = guard()
        if refusal is not None:
            return refusal
        result = fn(*args, **kwargs)
        if inspect.isawaitable(result):
            result = await result
        return result

    return _wrapper


def make_livekit_tools(
    db,
    uid: str,
    *,
    on_call: Callable[[str, str, str | None], None] | None = None,
    on_voice_change: set_voice_preference.VoiceChangeHook | None = None,
    voice_pref: object | None = None,
    guard: Callable[[], str | None] | None = None,
    session_id: str = "",
    turns: Callable[[], list] | None = None,
) -> list:
    """The same bound callables wrapped as livekit-agents tools (voice), plus
    the voice-only ``current_screen`` tool (``skills.app_control``). The app
    command tools it also carries are shared with the text tool set.

    ``on_call``, when given, is invoked ``on_call("start", name, None)`` right
    before a tool call runs and ``on_call("end", name, label)`` right after it
    finishes (agent.py publishes these as the ``tool_used`` data-channel
    event, §1.7 step 3) — this is the single wrap point that covers every
    voice tool, so individual skills stay untouched.

    ``on_voice_change``, when given, binds ``set_voice_preference`` through
    :func:`skills.set_voice_preference.bind_live` so a voice change is applied
    to the running call (agent.py ``VoiceSwapper``) instead of "next call" — the
    Gemini-Live-only hot-swap path. ``voice_pref`` (a
    ``voice_catalog.RuntimeVoices``), given on a cascade / non-Gemini-realtime
    call instead, binds ``set_voice_preference`` through
    :func:`skills.set_voice_preference.bind_stack` so the voice resolves within
    the ACTIVE provider's voices (saved for the next call) and the tool's
    description names those voices rather than the Gemini presets (§13.9).

    ``guard``, when given, runs before every tool call; a string it returns
    replaces the call (see :func:`_guarded`).

    ``session_id`` and ``turns`` (a callable returning the call's live turn
    window) bind ``send_dm_message``, which keeps its pending send per session
    and reads the caller's own latest line before sending.

    ``function_tool`` is imported lazily so this package stays importable in the
    Main API venv, which has no ``livekit-agents``.
    """
    from livekit.agents import function_tool

    tools = []
    for s in (_REGISTRY + _recall_skills() + app_control.VOICE_SKILLS):
        description = s.declaration["description"]
        if s is set_voice_preference.SKILL and on_voice_change is not None:
            # Gemini Live: mid-call hot-swap within the Gemini presets (unchanged).
            fn = set_voice_preference.bind_live(db, uid, on_voice_change)
        elif s is set_voice_preference.SKILL and voice_pref is not None:
            # Cascade / non-Gemini realtime: switch within the active provider's
            # voices, saved for the next call; name them in the description.
            fn = set_voice_preference.bind_stack(db, uid, voice_pref)
            description = set_voice_preference.stack_description(voice_pref)
        elif s.name in _DM_OUTREACH_NAMES:
            fn = s.bind(db, uid, session_id=session_id, turns=turns)
        else:
            fn = s.bind(db, uid)
        if on_call is not None:
            fn = _instrumented(fn, s.name, on_call)
        if guard is not None:
            # Outermost, so a refused call never shows a tool chip.
            fn = _guarded(fn, guard)
        tools.append(function_tool(fn, name=s.name, description=description))
    return tools
