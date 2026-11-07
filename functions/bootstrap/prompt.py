"""System-prompt composition (§13.5).

The base persona is loaded from ``persona.md`` (AGENTS.md: prompt text never
lives inside a code file). Layers wired so far, in §13.5 order: base persona
(Step 11), the curated feedback-correction bullets from ``lessons.md`` (§15),
``session_mode`` instructions (Step 33), wiki ``ai_body`` (Step 24) — which
includes each user's ``private`` steering page — and the recent-turns window
(Step 17). Still to come: ``viewing_profile_uid`` context (Step 44).

The *effective* lessons content is Firestore-backed (``config/ayma_persona``,
field ``lessons_md``) so the daily persona-evolution job (``persona_evolution.py``,
§15 Part B) can update it live, across every running Cloud Run instance,
without a redeploy — instances are stateless/ephemeral, so a background job
rewriting the static file on disk would never actually take effect. The
static ``prompts/lessons.md`` file stays in the repo as the documented
default/seed: it's what a brand-new deploy starts from, and what the very
first persona-evolution run reads as "current" before any real update has
ever landed. Callers that don't pass a Firestore client (``db=None`) — voice's
context-free fallback paths, most of this module's own tests — get the
static file only, exactly as before this migration.

Freshness: reading Firestore on every chat turn would be wasteful, so the
raw effective content is cached process-wide for ``_LESSONS_TTL_SECONDS``
(5 minutes — no existing Firestore-config-caching convention in this codebase
to follow, so this is a fresh, simple choice) rather than the indefinite
``@lru_cache`` this used to be. A daily update is visible to every instance
within one TTL window without needing to restart anything.
"""

from __future__ import annotations

import logging
import re
import time
from functools import lru_cache
from pathlib import Path

from action_facts import action_facts
from plan_facts import plan_facts
from transcript import Turn, format_recent_turns

logger = logging.getLogger("ayma.prompt")

_DIR = Path(__file__).parent
_PERSONA_PATH = _DIR / "persona.md"
_WELCOME_PATH = _DIR / "welcome_persona.md"
_LESSONS_PATH = _DIR / "prompts" / "lessons.md"
_QUESTIONNAIRE_PATH = _DIR / "prompts" / "questionnaire.md"
_VOICE_OPENER_PATH = _DIR / "prompts" / "voice_opener.md"
_VOICE_TOOL_USE_PATH = _DIR / "prompts" / "voice_tool_use.md"
_PRACTICE_GREETING_PATH = _DIR / "prompts" / "practice_greeting.md"
_VOICE_SESSION_SEED_PATH = _DIR / "prompts" / "voice_session_seed.md"
_VOICE_DANGLING_REPLY_PATH = _DIR / "prompts" / "voice_dangling_reply.md"
_TOUR_TAPPED_KICK_PATH = _DIR / "prompts" / "tour_tapped_kick.md"
_VOICE_SWAP_HEADS_UP_PATH = _DIR / "prompts" / "voice_swap_heads_up.md"
_VOICE_SWAP_NOTE_PATH = _DIR / "prompts" / "voice_swap_note.md"
_VOICE_LANGUAGE_PATH = _DIR / "prompts" / "voice_language.md"
_VOICE_ACCENT_PATH = _DIR / "prompts" / "voice_accent.md"
_VOICE_SWAP_CONFIRM_PATH = _DIR / "prompts" / "voice_swap_confirm.md"
_VOICE_SWAP_FAILED_PATH = _DIR / "prompts" / "voice_swap_failed.md"
_RECONNECT_BACK_PATH = _DIR / "prompts" / "reconnect_back.md"
_VOICE_VERBATIM_LINE_PATH = _DIR / "prompts" / "voice_verbatim_line.md"
_VOICE_VOCAB_PATH = _DIR / "prompts" / "voice_vocab.md"
_VOICE_VOCAB_LIVE_PATH = _DIR / "prompts" / "voice_vocab_live.md"
_VOICE_VOCAB_NEXT_CALL_PATH = _DIR / "prompts" / "voice_vocab_next_call.md"
_CAPABILITY_GAP_PATH = _DIR / "prompts" / "capability_gap.md"

_LESSONS_CONFIG_COLLECTION = "config"
_LESSONS_CONFIG_DOC = "ayma_persona"
_LESSONS_CONFIG_FIELD = "lessons_md"
_LESSONS_TTL_SECONDS = 300

# {"raw": str, "loaded_at": float} — process-wide short-TTL cache for the
# effective (Firestore-or-file) lessons content. Not an ``@lru_cache`` because
# that never expires; see module docstring.
_lessons_cache: dict[str, object] = {"raw": None, "loaded_at": 0.0}

# §3.3 — marketing- and interview-scoped instructions. ``active`` / normal adds
# nothing beyond the base persona.
_MODE_PROMPTS = {
    "marketing": _DIR / "prompts" / "mode_marketing.md",
    "interview": _DIR / "prompts" / "mode_interview.md",
}


# --- persona variants (voice-prompt diet, cost program 2026-09-26) ----------
#
# Voice re-bills every resident system-prompt token on every turn of a call
# (the Live API has no prefix caching), while text gets Gemini's implicit
# prefix-cache discount — so the voice variant of the persona drops the few
# rules that provably CANNOT fire in a voice session (text-UI-only mechanics:
# the `[face_report:...]` sentinel copy, the "Shared photo" note protocol,
# the profile-edit-chat tool flow, web/link/map grounding that voice's tool
# set doesn't have, emoji). One source file, `persona.md`, carries both
# variants via line-level markers so the two can never drift apart:
#
#   <!-- text-only -->  ... lines only the text variant keeps ...  <!-- /text-only -->
#   <!-- voice-only --> ... lines only the voice variant keeps ... <!-- /voice-only -->
#
# Marker lines themselves are never emitted. Every behavioural rule stays
# resident in whichever variant it applies to — nothing is loaded on demand.

_VARIANTS = ("text", "voice")
_MARKER_OPEN = {"<!-- text-only -->": "text", "<!-- voice-only -->": "voice"}
_MARKER_CLOSE = {"<!-- /text-only -->": "text", "<!-- /voice-only -->": "voice"}


def _persona_variant(raw: str, variant: str) -> str:
    """Render one variant of the marked-up persona source: marker lines are
    dropped, spans for the other variant are dropped, and any blank-line
    doubling the removals leave behind is collapsed."""
    if variant not in _VARIANTS:
        raise ValueError(f"unknown persona variant: {variant!r}")
    out: list[str] = []
    in_span: str | None = None
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped in _MARKER_OPEN:
            if in_span is not None:
                raise ValueError("nested persona variant markers")
            in_span = _MARKER_OPEN[stripped]
            continue
        if stripped in _MARKER_CLOSE:
            if in_span != _MARKER_CLOSE[stripped]:
                raise ValueError("unbalanced persona variant markers")
            in_span = None
            continue
        if in_span is not None and in_span != variant:
            continue
        out.append(line)
    if in_span is not None:
        raise ValueError("unclosed persona variant marker")
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()


@lru_cache(maxsize=2)
def load_persona(variant: str = "text") -> str:
    return _persona_variant(
        _PERSONA_PATH.read_text(encoding="utf-8"), variant
    )


def load_voice_persona() -> str:
    """The leaner voice variant of the base persona — see `_persona_variant`."""
    return load_persona("voice")


@lru_cache(maxsize=1)
def compose_welcome_prompt() -> str:
    """System prompt for the pre-sign-in "welcome" voice room — the base
    persona (voice variant: a welcome room is always a voice call) plus a
    short greeting frame. No user context, no history."""
    parts = [load_persona("voice")]
    if _WELCOME_PATH.exists():
        parts.append(_WELCOME_PATH.read_text(encoding="utf-8").strip())
    return "\n\n".join(p for p in parts if p)


def _static_lessons_seed() -> str:
    """The repo's checked-in default/seed content — used whenever Firestore
    has no ``config/ayma_persona`` doc yet (fresh deploy) or is unreachable."""
    if not _LESSONS_PATH.exists():
        return ""
    return _LESSONS_PATH.read_text(encoding="utf-8")


def _bullets_only(raw: str) -> str:
    """Comment / blank lines dropped, ``"- "`` bullets kept verbatim."""
    lines = [ln.rstrip() for ln in raw.splitlines() if ln.strip().startswith("- ")]
    return "\n".join(lines)


def _effective_lessons_raw(db=None) -> str:
    """The raw effective lessons content: the Firestore ``config/ayma_persona``
    doc's ``lessons_md`` field when present and non-blank, else the static
    seed file. Cached process-wide for ``_LESSONS_TTL_SECONDS`` so a daily
    update propagates without a redeploy; ``db=None`` (no Firestore client
    given) always reads the static file and isn't cached against a later call
    that does pass one.
    """
    if db is None:
        return _static_lessons_seed()

    now = time.monotonic()
    cached = _lessons_cache["raw"]
    if cached is not None and (now - _lessons_cache["loaded_at"]) < _LESSONS_TTL_SECONDS:
        return cached  # type: ignore[return-value]

    raw = _static_lessons_seed()
    try:
        snap = (
            db.collection(_LESSONS_CONFIG_COLLECTION)
            .document(_LESSONS_CONFIG_DOC)
            .get()
        )
        if snap.exists:
            value = (snap.to_dict() or {}).get(_LESSONS_CONFIG_FIELD)
            if isinstance(value, str) and value.strip():
                raw = value
    except Exception:  # noqa: BLE001 - a config read must never break a prompt
        logger.exception("prompt: reading config/ayma_persona failed")

    _lessons_cache["raw"] = raw
    _lessons_cache["loaded_at"] = now
    return raw


def load_lessons(db=None) -> str:
    """The curated behavioural-correction bullets (§15): from Firestore
    ``config/ayma_persona`` when ``db`` is given and the doc exists, else the
    static ``prompts/lessons.md`` seed file. Comment / blank lines are
    dropped; ``""`` when there are none yet."""
    return _bullets_only(_effective_lessons_raw(db))


@lru_cache(maxsize=4)
def load_mode_prompt(session_mode: str) -> str:
    path = _MODE_PROMPTS.get(session_mode)
    return path.read_text(encoding="utf-8").strip() if path else ""


@lru_cache(maxsize=1)
def _voice_opener_raw() -> str:
    return _VOICE_OPENER_PATH.read_text(encoding="utf-8").strip()


_OPENER_PRIOR_MARK = ("<!-- OPENER:PRIOR -->", "<!-- /OPENER:PRIOR -->")
_OPENER_FRESH_MARK = ("<!-- OPENER:FRESH -->", "<!-- /OPENER:FRESH -->")


def _opener_block(raw: str, keep: tuple[str, str], drop: tuple[str, str]) -> str:
    """Return ``raw`` with the ``keep`` block's markers stripped and the ``drop``
    block (markers included) removed, then whitespace tidied."""
    for mark in (keep[0], keep[1]):
        raw = raw.replace(mark, "")
    start, end = raw.find(drop[0]), raw.find(drop[1])
    if start != -1 and end != -1:
        raw = raw[:start] + raw[end + len(drop[1]):]
    return re.sub(r"\n{3,}", "\n\n", raw).strip()


def load_voice_opener(has_prior_conversation: bool, last_topic_hint: str = "") -> str:
    """Instruction for Ayma's own opening line on a call the caller hasn't spoken
    in yet (``prompts/voice_opener.md``), scoped to whether this caller has a
    prior conversation to offer (founder behaviour, 2026-10-28).

    When ``has_prior_conversation`` is True the opener is a GREET + a choice —
    "pick up where we left off about X, or something else?" — and explicitly does
    NOT continue the previous topic itself; ``last_topic_hint`` is a short,
    one-line reference to the last thing discussed (never the full transcript),
    substituted into that offer. When False it is a plain fresh warm opener. All
    the instructional prose lives in the prompt file; this only selects the right
    block and injects the hint value."""
    raw = _voice_opener_raw()
    hint = " ".join((last_topic_hint or "").split()).strip()
    if has_prior_conversation and hint:
        block = _opener_block(raw, _OPENER_PRIOR_MARK, _OPENER_FRESH_MARK)
        return block.replace("{last_topic_hint}", hint)
    return _opener_block(raw, _OPENER_FRESH_MARK, _OPENER_PRIOR_MARK)


@lru_cache(maxsize=1)
def load_voice_tool_use() -> str:
    """Voice tool-use directive (``prompts/voice_tool_use.md``): the agent MUST
    call the matching tool for any app action and may only confirm it from the
    tool's actual result — never narrate an action as done without invoking it.

    Appended to the voice session instructions. It especially hardens the Meta
    cascade path, where the chat LLM's tool-calling is probabilistic and would
    otherwise sometimes say "rerunning that now" or "opened that" without firing
    any tool (founder voice bug, 2026-10-28)."""
    return _VOICE_TOOL_USE_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_practice_greeting() -> str:
    """Instruction for the simulated match's own opening line on a Practice Date
    voice call — they "pick up the phone" and greet in character instead of
    waiting for the user (``prompts/practice_greeting.md``)."""
    return _PRACTICE_GREETING_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_voice_session_seed() -> str:
    """The synthetic opening USER turn seeded on a cascade (text-LLM) call so an
    agent-initiated greeting/opener never reaches the chat LLM as a system-only
    message list (``prompts/voice_session_seed.md``).

    On a cascade session (STT -> chat LLM -> TTS, incl. the LiveKit-Inference
    brain) ``generate_reply(instructions=...)`` adds the instruction as a SYSTEM
    message; with no prior user turn the request carries only system messages and
    the OpenAI-compatible gateway rejects it with HTTP 400 ("messages must
    contain at least one message with role user or tool"). Passing this as
    ``generate_reply(user_input=...)`` inserts one benign user turn so the opener
    generates normally. Realtime models (Gemini Live / Inference RealtimeModel)
    do not go through that path and are never seeded."""
    return _VOICE_SESSION_SEED_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_tour_tapped_kick() -> str:
    """The generate_reply instruction when the client reports the guided tour's
    spotlighted control was tapped (``prompts/tour_tapped_kick.md``, §11.2b): it
    tells Ayma to call ``advance_guided_tour`` (which consumes the already-written
    ``tour_event``) and narrate the next step — the voice bridge that advances the
    tour on a tap without depending on a blocking advance being mid-wait."""
    return _TOUR_TAPPED_KICK_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_voice_dangling_reply() -> str:
    """Instruction for Ayma's opening line when the caller's most recent
    message never got a reply (``prompts/voice_dangling_reply.md``).

    The caller is opening a voice call with an UNANSWERED user turn at the
    tail of their history (e.g. a text turn that failed before Ayma replied).
    Instead of a greeting, Ayma opens by ANSWERING that dangling message
    directly — briefly, warmly, in spoken sentences (founder behaviour,
    2026-11-02 — a user-initiated call never opens in silence). Static text:
    the dangling message itself reaches the model through the conversation
    (realtime: already the tail of the agent's context; cascade: passed as
    the reply's ``user_input``), never interpolated here."""
    return _VOICE_DANGLING_REPLY_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_voice_swap_heads_up() -> str:
    """Tool-result guidance for the short heads-up Ayma says in her current
    voice right before a mid-call voice reconnect
    (``prompts/voice_swap_heads_up.md``)."""
    return _VOICE_SWAP_HEADS_UP_PATH.read_text(encoding="utf-8").strip()


def voice_swap_note(change: str) -> str:
    """Context section appended to the instructions of the reconnected Live
    session after a mid-call voice switch (``prompts/voice_swap_note.md``)."""
    return _VOICE_SWAP_NOTE_PATH.read_text(encoding="utf-8").strip().replace(
        "{change}", change
    )


def voice_vocab_directive(current: str, voices: str, hot_swap: bool) -> str:
    """The stack-aware voice-vocabulary section appended to a voice session's
    instructions (``prompts/voice_vocab.md``): the voice the session is actually
    running (``current``), the voices its active stack can use (``voices``, a
    bulleted list), and whether a change can happen mid-call (``hot_swap``, true
    only on Gemini Live) or only from the next call. This is what makes the agent
    answer "what voices do you have" / "which are you on" for the ACTIVE stack
    (e.g. a fishaudio cascade) instead of the Gemini Live presets (§13.9)."""
    swap_rule = (
        _VOICE_VOCAB_LIVE_PATH if hot_swap else _VOICE_VOCAB_NEXT_CALL_PATH
    ).read_text(encoding="utf-8").strip()
    return (
        _VOICE_VOCAB_PATH.read_text(encoding="utf-8")
        .strip()
        .replace("{current}", current)
        .replace("{voices}", voices)
        .replace("{swap_rule}", swap_rule)
    )


def voice_language_directive(preference: str) -> str:
    """The voice-call language section appended to the session instructions
    (``prompts/voice_language.md``), on both voice providers: speak the
    user's saved ``ayma_voice_language`` (plain English when unset) and never
    switch language over a short misheard fragment. The LiveKit Inference
    gateway ignores every transcription language/prompt hint (verified live,
    docs/LIVEKIT_INFERENCE_MIGRATION.md 1c), so this instruction is the only
    lever there."""
    return _VOICE_LANGUAGE_PATH.read_text(encoding="utf-8").strip().replace(
        "{language}", preference.strip() or "English"
    )


def voice_accent_directive(accent: str) -> str:
    """The voice-call ACCENT section appended to the session instructions
    (``prompts/voice_accent.md``), fed ONLY to an accent-capable provider at
    session boot (Gemini Live / OpenAI Realtime — ``voice_catalog.
    provider_supports_accent``). It tells the model to speak in the user's saved
    ``ayma_voice_accent`` from the first word and hold it for the whole call, so
    the voice never reverts to the provider's default accent. Callers must not
    pass this to a fixed-voice provider (the agent routes it per capability)."""
    return _VOICE_ACCENT_PATH.read_text(encoding="utf-8").strip().replace(
        "{accent}", accent.strip()
    )


def voice_swap_confirm(change: str) -> str:
    """The one-shot reply instruction for Ayma's first line in the new voice
    (``prompts/voice_swap_confirm.md``)."""
    return _VOICE_SWAP_CONFIRM_PATH.read_text(encoding="utf-8").strip().replace(
        "{change}", change
    )


def reconnect_back(setup: str) -> str:
    """The one-shot reply instruction for the continuation session's first
    line after a user-requested reconnect (``prompts/reconnect_back.md``):
    the single "I'm back" confirmation, spoken only once the new session is
    actually live on the new setup (founder 2026-11-03 — the old session
    stays silent, its "reconnecting" narration was cut off by the teardown).
    """
    return _RECONNECT_BACK_PATH.read_text(encoding="utf-8").strip().replace(
        "{setup}", setup
    )


def load_voice_verbatim_line(line: str) -> str:
    """A ``generate_reply`` instruction that speaks one literal line and
    nothing else (``prompts/voice_verbatim_line.md``).

    The fallback for surfaces where ``session.say`` cannot run: a realtime
    session with no TTS whose model does not support say() (Gemini Live -
    the google plugin leaves ``capabilities.supports_say`` False, so
    livekit-agents raises RuntimeError from say()). ``generate_reply`` IS
    supported there - it is how the welcome greeting and the reconnect
    "I'm back" line already speak on realtime - so the literal line rides
    it under a say-exactly-this instruction."""
    return _VOICE_VERBATIM_LINE_PATH.read_text(encoding="utf-8").strip().replace(
        "{line}", line
    )


def voice_swap_failed(change: str) -> str:
    """The one-shot reply instruction after a mid-call voice switch failed
    and the call is back on (or never left) the previous voice: the honest
    "couldn't switch" line (``prompts/voice_swap_failed.md``)."""
    return _VOICE_SWAP_FAILED_PATH.read_text(encoding="utf-8").strip().replace(
        "{change}", change
    )


@lru_cache(maxsize=1)
def load_capability_gap() -> str:
    """The capability-gap auto-report instruction (``prompts/capability_gap.md``,
    founder rule 2026-11-07): when a user asks for something no tool covers,
    Ayma answers honestly and silently files one gap report through the
    existing ``report_bug`` path — with the hard exceptions (prohibited /
    user-only requests, tool errors, clarifying questions, vague chat)
    spelled out in the file itself. Static and user-independent, so it
    joins the stable prefix in :func:`compose_system_prompt` and lands in
    both the text prompt and the lean voice seed."""
    if not _CAPABILITY_GAP_PATH.exists():
        return ""
    return _CAPABILITY_GAP_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_questionnaire_guidance() -> str:
    """Standing behavioural guidance for working the tree-based questionnaire
    into conversation (referenced from ``persona.md``). ``""`` if absent."""
    if not _QUESTIONNAIRE_PATH.exists():
        return ""
    return _QUESTIONNAIRE_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=32)
def load_prompt_file(path) -> str:
    """The stripped text of one prompt/template file, cached per path.

    The single-file ``_prompt()`` loaders in ``dm_moderation``,
    ``taste_backfill``, ``photo_moderation``, ``photo_attrs``,
    ``photo_pipeline``, ``deep_dive_public_profiles``, ``physical_attributes``,
    ``explore``, ``ai_assessment`` (cached) and ``completeness`` (uncached)
    were all this same read — they call it now with their own
    ``_PROMPT_PATH``. ``path`` is ``str``- or ``Path``-shaped; a missing file
    still raises ``FileNotFoundError``, exactly as before.
    """
    return Path(path).read_text(encoding="utf-8").strip()


@lru_cache(maxsize=32)
def load_prompt_sections(path) -> dict[str, str]:
    """The ``## name`` sections of one prompt file, cached per path.

    The section parsers in ``face_report``, ``body_report`` (both now via
    ``photo_report``) and ``deep_dive`` were three copies of this same
    loop; they call it now with their own ``_PROMPTS_PATH``.
    """
    text = Path(path).read_text(encoding="utf-8")
    out: dict[str, str] = {}
    key: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^##\s+([\w-]+)\s*$", line)
        if m:
            if key is not None:
                out[key] = "\n".join(buf).strip()
            key, buf = m.group(1), []
        elif key is not None:
            buf.append(line)
    if key is not None:
        out[key] = "\n".join(buf).strip()
    return out

def compose_system_prompt(
    recent_turns: list[Turn] | None = None,
    wiki_context: str = "",
    session_mode: str = "",
    viewing_profile_context: str = "",
    profile_progress: str = "",
    preferences_context: str = "",
    model_stack_context: str = "",
    story_context: str = "",
    shared_photo_note: str = "",
    questionnaire_note: str = "",
    current_screen_context: str = "",
    db=None,
    lessons_md_override: str | None = None,
    summary_context: str = "",
    stable_prefix: bool = False,
    variant: str = "text",
) -> str:
    """Assemble the final system prompt in §13.5 order: base persona, then the
    ``session_mode`` instructions (§3.3), the preboarding-progress note (interview
    mode only), the wiki ``ai_body`` block (§2.3), the recent-turns window
    (§1.5), and — when the user is talking about a specific profile — that pair's
    ``ai_explanation`` (§5.6).

    ``current_screen_context`` is a short one-line description of whatever
    screen the user had open when they started this chat turn (the floating
    Ayma launcher's page-context threading) — the same descriptive shape
    ``skills.app_control._describe`` already builds for voice's
    ``current_screen`` tool, so text and voice share one notion of "where the
    user is". Left blank for the profile case, which already gets a much
    richer briefing via ``viewing_profile_context``.

    ``db`` reads the live (Firestore-or-file) lessons content — pass it at
    every real request site; ``None`` (voice's context-free fallback paths,
    most tests) uses the static seed file. ``lessons_md_override`` is for the
    persona-evolution eval gate only: it renders the prompt against a
    candidate ``lessons.md`` that was never written to Firestore, so the
    "current" and "proposed" personas can be compared side by side.

    ``summary_context`` is the rolling conversation summary (context_opt,
    cost-program Phase 2) — everything older than the raw ``recent_turns``
    tail, rendered just before the transcript so the two read as one
    continuous memory. ``""`` (the default) changes nothing.

    ``stable_prefix`` (context_opt, cost-program Phase 1) reorders assembly so
    the byte-stable parts — base persona, lessons, mode, questionnaire
    guidance, then the wiki block — come FIRST and are byte-identical across
    consecutive turns of a conversation, aligning with Gemini's implicit
    prompt-prefix caching; the volatile parts (progress notes, screen context,
    summary, history tail, photo/profile briefings) all move after the wiki
    block. ``False`` (the default) keeps the exact pre-existing §13.5 order,
    byte for byte.

    ``variant`` picks the persona variant (voice-prompt diet — see
    ``_persona_variant``): ``"text"`` (the default) is byte-identical to the
    pre-split persona, so the text path's stable-prefix caching property is
    untouched; ``"voice"`` is the leaner variant every voice seed uses.
    """
    parts = [load_persona(variant)]

    lessons = (
        _bullets_only(lessons_md_override)
        if lessons_md_override is not None
        else load_lessons(db)
    )
    if lessons:
        parts.append(
            "Corrections from past user feedback — apply every one:\n" + lessons
        )

    mode_prompt = load_mode_prompt(session_mode)
    if mode_prompt:
        parts.append(mode_prompt)

    guidance = load_questionnaire_guidance()
    if guidance:
        parts.append(guidance)

    # The real plan/credit/pricing facts, rendered from config + the ledger's
    # feature labels (plan_facts.py) — so Ayma states actual prices, monthly
    # credits and what credits buy instead of inventing dating-app perks. It is
    # user-independent and byte-stable, so it closes the static stable prefix
    # here (after persona/lessons/mode/guidance, before every volatile part),
    # landing in both the lean voice seed and the full text prompt.
    parts.append(plan_facts())

    # The permitted-action context, rendered from the app registry config
    # (action_facts.py — same config-to-prompt pattern as plan_facts): the
    # pages she can open, the settings she can change and the account
    # actions she can run, with the registry's exclusions deny-list applied
    # as a filter so a user-only action never appears as permitted. Nothing
    # about buttons is hardcoded in prompt text. User-independent and
    # byte-stable, so it joins the stable prefix here too, in both the
    # lean voice seed and the full text prompt.
    parts.append(action_facts())

    # The capability-gap auto-report instruction (founder rule 2026-11-07):
    # static prompt text from prompts/capability_gap.md — answer honestly
    # and silently file one report_bug gap report when no tool covers a
    # request, never for a prohibited ask, a tool error, or a clarifying
    # question. Byte-stable and user-independent, so it closes the stable
    # prefix here, in both the text prompt and the voice seed.
    _capability_gap = load_capability_gap()
    if _capability_gap:
        parts.append(_capability_gap)

    # Cache-alignment reorder (see the docstring): the wiki block joins the
    # stable prefix right here, before any per-turn volatile part.
    if stable_prefix and wiki_context.strip():
        parts.append(wiki_context.strip())

    # What preboarding has already captured — keeps interview-mode Ayma from
    # re-asking for a field the on-screen form already holds.
    if profile_progress.strip():
        parts.append(profile_progress.strip())

    # The user's saved partner preferences (gender, interested in, age range,
    # distance) — so Ayma never claims not to know what they asked for.
    if preferences_context.strip():
        parts.append(preferences_context.strip())

    # The user's model stack — main brain vs the brain under Voice as
    # labeled facts (skills.set_model_stack.model_stack_context), so she
    # never conflates the two brains or denies an enabled voice-brain option.
    if model_stack_context.strip():
        parts.append(model_stack_context.strip())

    # Active-mode nudge: where the questionnaire-completeness score is < 100,
    # the current score + the highest-priority nodes still to fill in.
    if questionnaire_note.strip():
        parts.append(questionnaire_note.strip())

    # The user opened this chat from the Your Story editor to work on a passage.
    if story_context.strip():
        parts.append(story_context.strip())

    # Where the user is in the app right now (floating launcher, non-profile
    # screens) — a short line, not a full briefing.
    if current_screen_context.strip():
        parts.append(
            "What the user is currently looking at in the app: "
            + current_screen_context.strip()
        )

    if not stable_prefix and wiki_context.strip():
        parts.append(wiki_context.strip())

    # The rolling summary of everything older than the raw tail below.
    if summary_context.strip():
        parts.append(
            "What you and this person covered earlier (a running summary of "
            "older conversation not shown verbatim below — treat it as your "
            "own memory):\n" + summary_context.strip()
        )

    rendered = format_recent_turns(recent_turns) if recent_turns else ""
    if rendered:
        parts.append(
            "Conversation so far (voice and text turns interleaved). Continue "
            "it naturally — do not repeat yourself:\n" + rendered
        )

    # Face check on a photo the user just shared in this chat (§ shared-photo
    # verify) — is it the account holder, someone else, or unverifiable?
    if shared_photo_note.strip():
        parts.append("Shared photo: " + shared_photo_note.strip())

    if viewing_profile_context.strip():
        parts.append(
            "The user is looking at / has shared a specific person's profile so "
            "you can talk about them. Here is what you know about that person "
            "and, if a match was run, your private read on the pair. Use their "
            "public wiki freely; never state a private fact from your match "
            "read outright — use it to steer toward what matters:\n"
            + viewing_profile_context.strip()
        )

    return "\n\n".join(parts)
