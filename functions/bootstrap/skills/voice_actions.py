"""Voice-actions skill: common-sense intent interpretation (founder pivot 2026-11-03).

The founder overruled pattern enumeration for voice actions ("don't do
patterns, just do common sense with clear guidance"): this module interprets
a finalized voice transcript with ONE fast model pass and returns a STRICT
structured intent. Tonight's shipped detector cases live on as worked
EXAMPLES in the guidance (``prompts/voice_actions.md``) — not as matching
code. No detector patterns are added here, ever.

LiveKit-only (permanent, founder): the pass runs through
:func:`inference_llm.complete` — the same LiveKit Inference gateway client
and the same configured JSON model (``CONFIG.inference_json_model``) the
rest of the app's structured calls use — with no Vertex branch and no
provider fallback. No direct provider SDK calls, no new keys, no new
endpoints.

The verdict is executed by the EXISTING deterministic executors: agent.py
maps it to the same ``(tool_name, kwargs)`` the shipped ``detect_voice_
command`` net returns (``open_screen``, ``open_profile``,
``open_practice_date`` / ``open_date_sim``, the stack setters,
``set_voice_preference``, ``start_guided_tour``), the partner-less
"who with?" clarification, or the call teardown for ``end_call`` —
claim-first in the call's ``VoiceTurnDedupe``, exactly once. Outcomes are
only execute, clarify, or none: there is no refusal anywhere in this design
(an unparseable answer, an unknown action, or a model failure all degrade
to ``none`` — conversation continues, and agent.py falls back to the
deterministic net).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import app_registry
import inference_llm
import token_ledger
import voice_catalog
from config import CONFIG
from llm_provider import PROVIDER_GEMINI, PROVIDER_META

logger = logging.getLogger("ayma.voice_actions")

_PROMPTS = Path(__file__).resolve().parent.parent / "prompts"
_GUIDANCE_PATH = _PROMPTS / "voice_actions.md"

# The structured-intent actions. ``clarify`` is launch-only ("who with?");
# ``none`` is pure conversation.
ACTIONS = (
    "navigate",
    "open_profile",
    "launch_practice",
    "launch_sim",
    "set_stack",
    "set_voice",
    "start_tour",
    "end_call",
    "clarify",
    "none",
)

_LAUNCH_TOOLS = {
    "launch_practice": "open_practice_date",
    "launch_sim": "open_date_sim",
}

# Mirrors agent.py ``_STACK_TOOL_KWARGS`` (kept in sync with it): the single
# kwarg each stack setter takes.
_STACK_TOOL_KWARGS = {
    "set_brain": "brain",
    "set_voice_mode": "mode",
    "set_realtime_model": "model",
    "set_stt": "engine",
    "set_tts": "engine",
}

RESPONSE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "action": {
            "type": "string",
            "enum": list(ACTIONS),
            "description": (
                "Exactly one intent: navigate, open_profile, "
                "launch_practice, launch_sim, set_stack, set_voice, "
                "start_tour, end_call, clarify (a launch with no partner), "
                "or none (pure conversation)."
            ),
        },
        "page": {
            "type": "string",
            "description": (
                "navigate only: the destination key from the given page "
                "list (e.g. explore, messages, voice_preference for the "
                "Models page itself)."
            ),
        },
        "member": {
            "type": "string",
            "description": "open_profile only: the member's name.",
        },
        "partner": {
            "type": "string",
            "description": (
                "launch_practice / launch_sim only: the partner's name — "
                "a spoken name, or the member under discussion for a "
                "pronoun ('her')."
            ),
        },
        "tool": {
            "type": "string",
            "description": (
                "set_stack only: one of set_brain, set_voice_mode, "
                "set_realtime_model, set_stt, set_tts."
            ),
        },
        "value": {
            "type": "string",
            "description": (
                "set_stack only: the named target (the brain, mode, "
                "realtime model, or engine)."
            ),
        },
        "voice_kind": {
            "type": "string",
            "enum": ["language", "accent", "character", ""],
            "description": (
                "set_voice only: which ONE the ask changes — language "
                "(which tongue she speaks), accent (her way of "
                "speaking), or character (who she sounds like). "
                "Empty for every other action."
            ),
        },
        "voice_value": {
            "type": "string",
            "description": (
                "set_voice only: the extracted value alone — the "
                "language name ('Spanish'), the accent description "
                "('southern American accent'), or the character ask in "
                "their words ('sound like a man'). Never a sentence "
                "restating the request."
            ),
        },
        "for": {
            "type": "string",
            "description": (
                "clarify only: launch_practice or launch_sim — which "
                "launch needs its partner."
            ),
        },
        "reason": {
            "type": "string",
            "description": "clarify only: short note, e.g. 'who with?'.",
        },
    },
    "required": ["action"],
    "additionalProperties": False,
}


@lru_cache(maxsize=1)
def load_guidance() -> str:
    """The interpretation guidance (``prompts/voice_actions.md``): the system
    prompt for the skill's model pass."""
    return _GUIDANCE_PATH.read_text(encoding="utf-8").strip()


@dataclass(frozen=True)
class CallContext:
    """What the transcript is interpreted against: the member under
    discussion (the person on screen, or ""), the currently open page (a
    registry destination key, or ""), and the recent turns (oldest first,
    ``(role, text)`` pairs — the model's pronoun-resolution evidence)."""

    member: str = ""
    page: str = ""
    turns: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class Verdict:
    """One structured intent. ``action`` is always a known action (anything
    unrecognised parses to ``none``); only the args for that action carry
    meaning."""

    action: str = "none"
    page: str = ""
    member: str = ""
    partner: str = ""
    tool: str = ""
    value: str = ""
    voice_kind: str = ""
    voice_value: str = ""
    clarify_for: str = ""
    reason: str = ""


def _screen_lines() -> str:
    """The destination keys the model may navigate to, each with its label —
    the same ``key (label)`` shape the tool declarations use."""
    return "; ".join(
        f"{d['key']} ({d['label']})" for d in app_registry.destinations()
    )


def build_user_message(transcript: str, context: CallContext) -> str:
    """The model pass's user message: the transcript plus its session
    context and the closed navigate vocabulary."""
    lines = [f'Transcript: "{transcript.strip()}"']
    lines.append(
        "Member under discussion: "
        + (context.member.strip() or "(nobody in particular)")
    )
    lines.append(
        "Currently open page: " + (context.page.strip() or "(none known)")
    )
    if context.turns:
        lines.append("Recent turns (oldest first):")
        for role, text in context.turns[-6:]:
            lines.append(f"- {role}: {text.strip()}"[:400])
    else:
        lines.append("Recent turns: (none)")
    lines.append("Navigable pages (key + label): " + _screen_lines())
    lines.append("Answer with the single JSON object.")
    return "\n".join(lines)


def parse_verdict(raw: object) -> Verdict:
    """A parsed model answer → :class:`Verdict`. Anything malformed,
    refusal-shaped, or unknown degrades to ``none`` (conversation continues)
    — never an error, never a refusal."""
    if not isinstance(raw, dict):
        return Verdict()
    action = str(raw.get("action") or "").strip()
    if action not in ACTIONS:
        return Verdict()

    def _text(key: str) -> str:
        return str(raw.get(key) or "").strip()

    return Verdict(
        action=action,
        page=_text("page"),
        member=_text("member"),
        partner=_text("partner"),
        tool=_text("tool"),
        value=_text("value"),
        voice_kind=_text("voice_kind"),
        voice_value=_text("voice_value"),
        clarify_for=_text("for"),
        reason=_text("reason"),
    )


def _parse_json_text(text: str) -> object:
    """Lenient JSON parse (fenced or bare), mirroring
    ``gemini._parse_json_text`` without importing the Vertex client module."""
    stripped = (text or "").strip()
    if stripped.startswith("```"):
        stripped = stripped.strip("`")
        stripped = (
            stripped[4:] if stripped[:4].lower() == "json" else stripped
        )
    return json.loads(stripped.strip())


async def interpret_voice_action(
    transcript: str,
    context: CallContext | None = None,
    *,
    uid: str | None = None,
    session_id: str = "",
) -> Verdict:
    """Run the skill's ONE fast model pass and return its structured verdict.

    Raises on a transport/model failure (the caller falls back to the
    deterministic net); an unparseable answer parses to ``none``. The spend
    is metered to the caller's voice ledger like the rest of the call. No
    credit-gate check here: the call's own mid-call watchdog governs the
    session, and a broke user still gets the local deterministic net.
    """
    ctx = context or CallContext()
    model = CONFIG.inference_json_model
    response = await inference_llm.complete(
        model=model,
        messages=[
            {"role": "system", "content": load_guidance()},
            {
                "role": "user",
                "content": build_user_message(transcript, ctx),
            },
        ],
        response_schema=RESPONSE_SCHEMA,
        temperature=0.0,
        max_tokens=512,
    )
    token_ledger.record(
        uid, token_ledger.FEATURE_VOICE, response, model=model,
        session_id=session_id or None,
        provider=token_ledger.PROVIDER_LIVEKIT_INFERENCE,
    )
    if not response.text.strip():
        logger.warning("voice-actions skill returned an empty answer")
        return Verdict()
    try:
        return parse_verdict(_parse_json_text(response.text))
    except ValueError:
        logger.warning("voice-actions skill returned unparseable JSON")
        return Verdict()


def _resolve_engine(value: str, kind: str) -> str | None:
    """A configured cascade engine id for the model's ``stt``/``tts`` words,
    else ``None``. Matches on the provider segment of the config lists only
    (``deepgram``, ``fishaudio``, …) — the same distinctive matching the
    deterministic detector uses — so a generic word can never false-match."""
    models = (
        voice_catalog.CONFIG.voice_cascade_stt_models
        if kind == "stt"
        else voice_catalog.CONFIG.voice_cascade_tts_models
    )
    words = value.strip().lower().replace("_", " ").replace("-", " ").split()
    for mid in models:
        provider = mid.partition("/")[0].strip().lower()
        if provider and provider in words:
            return mid
    return None


def _canonical_stack_value(tool: str, value: str) -> str | None:
    """The canonical value for a stack verdict, else ``None`` (not a
    resolvable target — the turn stays conversation)."""
    low = value.strip().lower()
    if tool == "set_brain":
        if "gemini" in low or "google" in low:
            return PROVIDER_GEMINI
        if "meta" in low or "muse" in low:
            return PROVIDER_META
        return None
    if tool == "set_voice_mode":
        if "cascade" in low or low == "text mode":
            return voice_catalog.MODE_CASCADE
        if "realtime" in low or "real time" in low or "native audio" in low:
            return voice_catalog.MODE_REALTIME
        return None
    if tool == "set_realtime_model":
        if "openai" in low or "gpt" in low:
            return voice_catalog.REALTIME_OPENAI
        if "gemini" in low or "live" in low:
            return voice_catalog.REALTIME_GEMINI
        return None
    if tool == "set_stt":
        return _resolve_engine(value, "stt")
    if tool == "set_tts":
        return _resolve_engine(value, "tts")
    return None


def verdict_to_command(verdict: Verdict) -> tuple[str, dict] | None:
    """A verdict → the ``(tool_name, kwargs)`` the existing deterministic
    executors run, in exactly the shape ``detect_voice_command`` returns —
    or ``None`` when the turn stays conversation (or the verdict's target
    does not resolve). ``"end_call"`` is the relay-handled pseudo-command
    (not a session tool), as on the goodbye path; a ``clarify`` verdict maps
    to its launch tool with an empty partner, which the relay answers with
    the existing "who with?" clarification."""
    if verdict is None:
        return None
    action = verdict.action
    if action == "navigate":
        page = verdict.page.strip()
        if not page:
            return None
        keys = {d["key"] for d in app_registry.destinations()}
        if page in keys:
            return "open_screen", {"screen": page}
        dest = app_registry.find_destination(page)
        if dest is None:
            return None
        return "open_screen", {"screen": str(dest["key"])}
    if action == "open_profile":
        member = verdict.member.strip()
        if not member:
            return None
        return "open_profile", {"name": member}
    if action in _LAUNCH_TOOLS:
        # An empty partner flows into the relay's existing partner-less
        # branch (the "who with?" clarification), never a launch.
        return _LAUNCH_TOOLS[action], {"name": verdict.partner.strip()}
    if action == "set_stack":
        tool = verdict.tool.strip()
        kwarg = _STACK_TOOL_KWARGS.get(tool)
        if kwarg is None:
            return None
        value = _canonical_stack_value(tool, verdict.value)
        if value is None:
            return None
        return tool, {kwarg: value}
    if action == "set_voice":
        kind = verdict.voice_kind.strip().lower()
        value = verdict.voice_value.strip()
        if not value:
            return None
        # The kind routes the single extracted value to the existing
        # tool's arg. An unknown kind stays conversation — a misrouted
        # value could otherwise write the WRONG voice setting.
        if kind == "language":
            return "set_voice_preference", {"accent_language": value}
        if kind == "accent":
            return "set_voice_preference", {"accent": value}
        if kind == "character":
            return "set_voice_preference", {"request": value}
        return None
    if action == "start_tour":
        return "start_guided_tour", {}
    if action == "end_call":
        return "end_call", {}
    if action == "clarify":
        tool = _LAUNCH_TOOLS.get(verdict.clarify_for.strip())
        if tool is None:
            return None
        return tool, {"name": ""}
    return None


def read_call_context(db, uid: str, window) -> CallContext:
    """The interpretation context for a live call: the member under
    discussion (the screen mirror's subject, when fresh) and the open page,
    plus the recent-turn tail. Sync (one Firestore read); the caller threads
    it off the event loop. Any failure degrades to turns-only context —
    never an error."""
    member = ""
    page = ""
    try:
        from .app_control_mirror import (
            _is_fresh,
            _voice_context_doc,
        )

        snap = _voice_context_doc(db, uid).get()
        data = (
            snap.to_dict() if getattr(snap, "exists", False) else None
        ) or {}
        if data and _is_fresh(data.get("updated_at")):
            member = str(data.get("subject_name") or "").strip()
            page = str(data.get("screen") or "").strip()
    except Exception:  # noqa: BLE001 - context is best-effort
        logger.exception("voice-actions context mirror read failed")
    turns: list[tuple[str, str]] = []
    try:
        for turn in list(window or [])[-6:]:
            role = str(getattr(turn, "role", "") or "").strip()
            text = str(getattr(turn, "text", "") or "").strip()
            if text:
                turns.append((role or "user", text))
    except Exception:  # noqa: BLE001 - context is best-effort
        logger.exception("voice-actions context window read failed")
    return CallContext(member=member, page=page, turns=tuple(turns))
