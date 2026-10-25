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
    user_steering,
)
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

# propose_dm_message / send_dm_message (dm_outreach.py) share a
# same-conversation "pending draft" doc keyed by session_id — the same
# per-session-doc mechanism `remember` already uses — so they need
# session_id threaded through the same way.
_DM_OUTREACH_NAMES = {s.name for s in dm_outreach.SKILLS}

# These tools write a fact straight from what the user just said, so they
# take the full session_ctx (session_id/turn_index/turns) too — the current
# turn's user message is the provenance quote `find_fact_source` later
# attributes the write to (§ fact-source-of-truth, 2026-09-21).
_PROVENANCE_NAMES = {"set_profile_field", "record_answer", "set_relationship_intent"}


from . import edit_profile_section, photo_edit, story_edit, deep_dive_edit, appearance_edit, generate_image  # noqa: E402

# Always in the TEXT tool set, never in voice: ``generate_image`` delivers its
# image through the same mutable ``result`` sink ``edit_photo`` uses
# (``main._ChatCtx.photo_edit_result`` → the chat reply's ``image_url`` + the
# durable transcript), and voice (agent.py) has no such delivery surface — a
# voice call has nowhere to show a generated image, so exposing the tool there
# would only let the model claim to send images it can't.
_TEXT_ONLY_REGISTRY: list[Skill] = [generate_image.SKILL]

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
        + app_control.COMMAND_SKILLS
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
) -> dict[str, Callable[..., str]]:
    """``{name: bound callable}`` for ``gemini.generate_reply`` (text).

    ``session_ctx`` (``session_id`` / ``turn_index`` / ``turns``) is threaded
    into ``remember`` and into the fact-writing tools in ``_PROVENANCE_NAMES``
    (``set_profile_field`` / ``record_answer`` / ``set_relationship_intent`` —
    so each write can store the verbatim user quote it came from), and its
    ``session_id`` alone into ``propose_dm_message`` / ``send_dm_message``
    (dm_outreach.py — their two-step confirm needs a same-conversation
    "pending draft" doc, keyed the same way ``remember`` keys its own
    per-session doc); ``story_ctx``
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
    to attach to the reply, exactly like ``edit_photo``'s. Every other skill
    binds on ``(db, uid)`` alone.
    """
    out: dict[str, Callable[..., str]] = {}
    for s in (_REGISTRY + _recall_skills()):
        if s.name in ("remember", *_PROVENANCE_NAMES) and session_ctx:
            out[s.name] = s.bind(db, uid, **session_ctx)
        elif s.name in ("analyze_physical_attributes", "report_bug"):
            out[s.name] = s.bind(db, uid, image_path=image_path)
        elif s.name in _DM_OUTREACH_NAMES:
            out[s.name] = s.bind(
                db, uid, session_id=(session_ctx or {}).get("session_id", "")
            )
        else:
            out[s.name] = s.bind(db, uid)
    for s in _TEXT_ONLY_REGISTRY:
        out[s.name] = s.bind(db, uid, result=image_result)
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
    fn: Callable[..., object], name: str, on_call: Callable[[str, str], None]
) -> Callable[..., object]:
    """Wrap a bound skill callable (sync or async) so ``on_call`` fires once
    right before it runs and once right after it returns or raises — the one
    hook point ``make_livekit_tools`` uses to report every tool call, so voice
    (agent.py) never needs to touch individual skills.

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
            on_call("start", name)
            try:
                return await fn(*args, **kwargs)
            finally:
                on_call("end", name)

        return _async_wrapper

    @functools.wraps(fn)
    async def _sync_wrapper(*args, **kwargs):
        on_call("start", name)
        try:
            return fn(*args, **kwargs)
        finally:
            on_call("end", name)

    return _sync_wrapper


def make_livekit_tools(
    db, uid: str, *, on_call: Callable[[str, str], None] | None = None
) -> list:
    """The same bound callables wrapped as livekit-agents tools (voice), plus
    the voice-only ``current_screen`` tool (``skills.app_control``). The app
    command tools it also carries are shared with the text tool set.

    ``on_call``, when given, is invoked ``on_call("start", name)`` right
    before a tool call runs and ``on_call("end", name)`` right after it
    finishes (agent.py publishes these as the ``tool_used`` data-channel
    event, §1.7 step 3) — this is the single wrap point that covers every
    voice tool, so individual skills stay untouched.

    ``function_tool`` is imported lazily so this package stays importable in the
    Main API venv, which has no ``livekit-agents``.
    """
    from livekit.agents import function_tool

    tools = []
    for s in (_REGISTRY + _recall_skills() + app_control.VOICE_SKILLS):
        fn = s.bind(db, uid)
        if on_call is not None:
            fn = _instrumented(fn, s.name, on_call)
        tools.append(
            function_tool(fn, name=s.name, description=s.declaration["description"])
        )
    return tools
