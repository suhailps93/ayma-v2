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
    face_report,
    followup,
    physical_attributes,
    questionnaire,
    read_dm_thread,
    record_feedback,
    remember,
    set_profile_field,
    set_voice_preference,
    user_steering,
)
from ._base import Skill

_REGISTRY: list[Skill] = [
    followup.SKILL,
    set_profile_field.SKILL,
    set_voice_preference.SKILL,
    record_feedback.SKILL,
    user_steering.SKILL,
    remember.SKILL,
    read_dm_thread.SKILL,
    deep_dive.SKILL,
    face_report.SKILL,
    body_report.SKILL,
    physical_attributes.SKILL,
    *questionnaire.SKILLS,
]


from . import edit_profile_section, photo_edit, story_edit  # noqa: E402

# Only exposed when the chat is opened from the Your Story editor (§ Your Story).
_STORY_REGISTRY: list[Skill] = list(story_edit.SKILLS)
_STORY_NAMES = {s.name for s in _STORY_REGISTRY}

# Only exposed when the chat is opened to edit the user's own public profile.
_PROFILE_EDIT_REGISTRY: list[Skill] = list(edit_profile_section.SKILLS)

# Only exposed when the chat is opened from "Chat about it" on one photo.
_PHOTO_REGISTRY: list[Skill] = list(photo_edit.SKILLS)


def all_skills() -> list[Skill]:
    return list(_REGISTRY)


def session_tool_declarations(
    *, story: bool = False, profile_edit: bool = False, photo: bool = False
) -> list[dict]:
    """Gemini function declarations for every registered skill. ``story=True``
    adds the Your Story passage-edit tools; ``profile_edit=True`` adds the
    public-profile section-edit tools; ``photo=True`` adds the photo-note
    tool."""
    reg = list(_REGISTRY)
    if story:
        reg += _STORY_REGISTRY
    if profile_edit:
        reg += _PROFILE_EDIT_REGISTRY
    if photo:
        reg += _PHOTO_REGISTRY
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
) -> dict[str, Callable[..., str]]:
    """``{name: bound callable}`` for ``gemini.generate_reply`` (text).

    ``session_ctx`` (``session_id`` / ``turn_index`` / ``turns``) is threaded
    only into ``remember``; ``story_ctx`` (``page_id`` / ``passage``) adds and
    binds the Your Story passage-edit tools; ``profile_edit=True`` adds the
    public-profile section-edit tools; ``photo_ctx`` (``url`` / ``source`` /
    ``image`` — the resolved photo bytes / ``result`` — a mutable dict
    ``edit_photo`` writes its ``image_path``/``image_url`` into for the
    caller to read back) adds and binds the photo tools; ``image_path`` (the
    photo attached to this chat turn, if any) is threaded only into
    ``analyze_physical_attributes``. Every other skill binds on ``(db, uid)``
    alone.
    """
    out: dict[str, Callable[..., str]] = {}
    for s in _REGISTRY:
        if s.name == "remember" and session_ctx:
            out[s.name] = s.bind(db, uid, **session_ctx)
        elif s.name == "analyze_physical_attributes":
            out[s.name] = s.bind(db, uid, image_path=image_path)
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
    the voice-only screen-awareness / navigation tools (``skills.app_control``)
    that don't belong in the text tool set.

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
    for s in (_REGISTRY + app_control.VOICE_SKILLS):
        fn = s.bind(db, uid)
        if on_call is not None:
            fn = _instrumented(fn, s.name, on_call)
        tools.append(
            function_tool(fn, name=s.name, description=s.declaration["description"])
        )
    return tools
