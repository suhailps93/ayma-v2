"""Gemini chat + structured calls, served ONLY through LiveKit Inference.

Founder rule (2026-11-04, permanent — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md``): there is no direct-Google path in this
module. Every call goes to the LiveKit Inference gateway via
:mod:`inference_llm`; a gateway failure fails the call honestly, never falls
back to Vertex or the Developer API.

Sub-paths the gateway provably cannot serve (grounded research, image
generate/edit) are DISABLED — they raise
:exc:`llm_routing.DirectGoogleDisabledError` instead of calling Google. Each is
a founder-decision item: restore only with a LiveKit-served equivalent or an
explicit founder exception.

The model ids come only from ``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import re
from dataclasses import dataclass, field

import inference_llm
import llm_routing
import token_ledger
from config import CONFIG
from tool_labels import NO_CHIP as _NO_CHIP
from tool_labels import TOOL_LABELS as _TOOL_LABELS
from tool_labels import WORKING_LABELS as _WORKING_LABELS
from tool_labels import outcome_label as _outcome_label
from tool_labels import tool_label as _tool_label
from tool_labels import working_label as _working_label

logger = logging.getLogger("ayma.gemini")

# Friendly, user-facing labels for the tools Ayma can invoke in a chat turn —
# shown in the client as a small caption on her reply ("what she just did").
# Every registered skill (``skills.session_tool_declarations(story=True,
# profile_edit=True)``) plus the three built-in grounding tools must have an
# entry in BOTH ``_TOOL_LABELS`` and ``_WORKING_LABELS`` — a test enforces it —
# so the chat kicker never falls back to a raw "Read dm thread" / "Working…".
# The maps themselves live in ``tool_labels.py`` (imported above), shared with
# ``agent.py`` (voice) so both surfaces describe the same tool call the same
# way.


@dataclass
class Reply:
    """A chat reply plus the ordered, de-duplicated list of user-facing tool
    labels Ayma used to produce it (empty when she just answered)."""

    text: str
    tools_used: list[str] = field(default_factory=list)

    def __str__(self) -> str:  # keep drop-in string behaviour for logs
        return self.text


# Gemini 3 grounding sometimes leaves an opaque citation chunk id in the prose,
# e.g. "[AUZIYQEL…FGY7dFnikr8=]" or a comma-separated list of them. They are not
# meant for the reader — strip them (and any bracketed [1]/[2,3] style markers).
# A grounding chunk id: 24+ url-safe chars that include at least one digit /
# underscore / dash (so ordinary bracketed words never match). Also handles the
# plain "[1]" / "[2, 3]" footnote style.
_REF_TOKEN = r"(?=[A-Za-z0-9_-]*[0-9_-])[A-Za-z0-9_-]{24,}={0,2}"
_INLINE_REF_RE = re.compile(
    r"\s*\[\s*(?:" + _REF_TOKEN + r"|\d{1,3})"
    r"(?:\s*,\s*(?:" + _REF_TOKEN + r"|\d{1,3}))*\s*\]"
)


def strip_inline_refs(text: str) -> str:
    """Remove leaked grounding-citation brackets from a model reply, tidy the
    spacing they leave behind."""
    if not text:
        return text
    out = _INLINE_REF_RE.sub("", text)
    out = re.sub(r"\s+([.,;:!?])", r"\1", out)  # " ." -> "."
    out = re.sub(r"[ \t]{2,}", " ", out)
    return out.strip()


# A hung model call or tool must end in an error the user can retry, never an
# endless "Thinking…" (founder tester report, 2026-10-20). Module-level so
# tests can shrink them.
# Last-resort nudge when the model closes a turn with a repeated empty `stop`
# (no reply after its tool call, or nothing at all). Sent once with tools OFF so
# the model produces the user-facing sentence it skipped, instead of forcing the
# user to repeat themselves (demo-test1 2026-11-15, staging WTKCv8ARQfBnygn7Y6df).
_EMPTY_REPLY_NUDGE = "Please reply to me now in plain text — a sentence or two."

_TOOL_TIMEOUT_SECONDS = 120.0
# Grounded web research (google_search + url_context) legitimately runs longer
# than a plain generate — and the deep-dive path that uses it is a polled
# BACKGROUND job (the client POSTs /deep-dive then polls /deep-dive/mine), so
# it is not bound by the client's long-request budget and can afford a longer
# wait than the 75s synchronous default. Kept so the (now disabled) research
# call shape stays intact for a future LiveKit-served equivalent.
RESEARCH_TIMEOUT_SECONDS = 120.0


async def warmup() -> None:
    """One minimal gateway ping before the instance serves real traffic, so a
    credential/route problem surfaces in the startup logs instead of the first
    user turn. Best-effort."""
    try:
        await inference_llm.complete(
            model=CONFIG.inference_chat_model,
            messages=[{"role": "user", "content": "ping"}],
            max_tokens=1,
        )
        logger.info("inference warmup ok")
    except Exception as exc:  # noqa: BLE001
        logger.warning("inference warmup failed: %s", exc)


def _empty_retry_budget(finish_reason: str | None, base: int) -> int:
    """The max_tokens for the single empty-response retry: doubled for a
    ``length`` truncation (a thinking model spent the whole budget on reasoning
    and emitted nothing), the same budget for a transient stop-with-empty
    content flake (Scout NOTE 214 Defect A)."""
    return base * 2 if (finish_reason or "").lower() == "length" else base


async def _reply_events_inference(
    message: str,
    system_prompt: str | None,
    tool_declarations: list[dict] | None,
    tool_fns: dict | None,
    *,
    image: tuple[bytes, str] | None,
    uid: str | None,
    feature: str,
    session_id: str,
):
    """The LiveKit Inference chat loop: same events, same one-tool-round
    shape the Vertex twin used to have. A gateway failure propagates to the
    caller — there is no fallback."""
    declarations = list(tool_declarations or [])
    fns = dict(tool_fns or {})
    # The web_search tool arrives through the skills registry like every
    # other tool (skills.web_search, gated by CONFIG.gemini_web_search in
    # skills._web_search_skills) — it used to be hand-appended here, which
    # is why the voice tool set never had it (founder bug 2026-11-07).
    tools = inference_llm.to_openai_tools(declarations) if declarations else None
    effort = (CONFIG.gemini_chat_thinking_level or "").strip().lower()
    effort = effort if effort in ("low", "medium", "high") else None
    model = CONFIG.inference_chat_model

    user_content: object = message
    if image is not None:
        user_content = [
            inference_llm.image_part(image[0], image[1]),
            {"type": "text", "text": message},
        ]
    messages: list[dict] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": user_content})

    chat_max_tokens = CONFIG.inference_chat_max_tokens
    if not chat_max_tokens:
        raise RuntimeError(
            "INFERENCE_CHAT_MAX_TOKENS is not configured — config.py must "
            "provide inference_chat_max_tokens (no inline default here)."
        )

    async def _call(max_tokens: int = chat_max_tokens, *, use_tools: bool = True):
        return await inference_llm.complete(
            model=model, messages=messages,
            tools=tools if use_tools else None,
            temperature=0.9, max_tokens=max_tokens, reasoning_effort=effort,
        )

    token_ledger.check(uid)
    yield {"type": "status", "label": "Thinking…"}
    response = await _call()
    token_ledger.record(
        uid, feature, response, model=model, session_id=session_id or None,
    )

    # Transient empty first response (Scout NOTE 214 Defect A): the model
    # intermittently comes back with NO text AND NO tool call (seen as
    # finish_reason=stop, a few completion tokens). That would drop an entire
    # valid tool-using turn — the user got the generic "couldn't finish that"
    # apology and the tool (e.g. propose_date_plan) never ran. Retry the
    # inference ONCE — same call, still on LiveKit Inference, no loop and no
    # provider/model change — before proceeding. The retried response flows
    # through the normal tool-execution + text path below, so a tool call the
    # flake swallowed is re-issued and runs on the retry.
    if not response.function_calls and not response.text.strip():
        usage = response.usage_metadata
        logger.warning(
            "chat: empty first inference (finish_reason=%s prompt=%s "
            "completion=%s) — retrying once on LiveKit Inference",
            response.finish_reason,
            getattr(usage, "prompt_token_count", None),
            getattr(usage, "candidates_token_count", None),
        )
        response = await _call(
            _empty_retry_budget(response.finish_reason, chat_max_tokens)
        )
        token_ledger.record(
            uid, feature, response, model=model, session_id=session_id or None,
        )

    used: list[str] = []
    seen: set[str] = set()

    def _note(name: str, label: str | None = None) -> None:
        if label == _NO_CHIP:
            return
        key = label or name
        if key not in seen:
            seen.add(key)
            used.append(label or _tool_label(name))

    if response.function_calls and fns:
        messages.append(response.assistant_message)
        for call in response.function_calls:
            label = None
            if call.name == "deep_dive":
                who = str(call.args.get("full_name") or "").strip()
                if who:
                    subj = "yourself" if str(call.args.get("subject")) == "self" else who
                    label = f"Researched {subj} online"
            yield {"type": "status", "label": _working_label(call.name)}
            fn = fns.get(call.name)
            try:
                result = fn(**call.args) if fn else "unknown tool"
                if inspect.isawaitable(result):
                    result = await asyncio.wait_for(
                        result, timeout=_TOOL_TIMEOUT_SECONDS
                    )
            except asyncio.TimeoutError:
                logger.error("tool %s timed out", call.name)
                result = (
                    "error: that took too long and was not completed — "
                    "tell the user it didn't work."
                )
            except Exception as exc:  # noqa: BLE001 - report to the model, don't crash
                result = f"error: {exc}"
            # Noted after the call: some labels depend on what it did.
            _note(call.name, label or _outcome_label(call.name, result))
            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": json.dumps({"result": result}, default=str),
            })
        yield {"type": "status", "label": "Writing…"}
        response = await _call()
        token_ledger.record(
            uid, feature, response, model=model, session_id=session_id or None,
        )
        # Retry ONCE on an empty POST-TOOL final response (no loop), still on
        # LiveKit Inference: a "length" truncation gets a doubled budget (a
        # thinking model spent it all on reasoning); a transient stop-with-empty
        # content flake (Scout NOTE 214 Defect A) gets another attempt at the
        # same budget, so a completed tool call isn't thrown away for want of a
        # closing sentence.
        if not response.text.strip():
            usage = response.usage_metadata
            logger.warning(
                "chat: empty post-tool inference (finish_reason=%s prompt=%s "
                "completion=%s) — retrying once on LiveKit Inference",
                response.finish_reason,
                getattr(usage, "prompt_token_count", None),
                getattr(usage, "candidates_token_count", None),
            )
            response = await _call(
                _empty_retry_budget(response.finish_reason, chat_max_tokens)
            )
            token_ledger.record(
                uid, feature, response, model=model,
                session_id=session_id or None,
            )

    text = strip_inline_refs(response.text.strip())
    if not text:
        usage = response.usage_metadata
        logger.warning(
            "chat: empty inference content — finish_reason=%s prompt=%s "
            "completion=%s max_tokens=%s",
            response.finish_reason,
            getattr(usage, "prompt_token_count", None),
            getattr(usage, "candidates_token_count", None),
            chat_max_tokens,
        )
        # The same-call retry above did not help: the model keeps closing with
        # an empty `stop` (demo-test1 2026-11-15 — an empty post-tool stop
        # recurred identically across three turns, so the user had to repeat the
        # same answer three times). Re-issuing the identical request reproduces
        # it, so nudge ONCE for a plain-text reply with tools OFF — the model
        # cannot loop back into another empty tool round, and a fresh
        # instruction breaks the repeated empty stop. Still LiveKit Inference,
        # same model, no provider/model change — a clearer ask, not a fallback.
        messages.append({"role": "user", "content": _EMPTY_REPLY_NUDGE})
        response = await _call(use_tools=False)
        token_ledger.record(
            uid, feature, response, model=model, session_id=session_id or None,
        )
        text = strip_inline_refs(response.text.strip())
    if not text:
        # Empty even after the nudge — a genuinely dead response. Fail loudly and
        # honestly, no loop: one honest failure for this turn, never a silent
        # non-response.
        logger.warning(
            "chat: inference still empty after the reply nudge — failing honestly"
        )
        raise RuntimeError("Gemini returned an empty response.")
    yield {"type": "reply", "text": text, "tools_used": used}


async def generate_reply_events(
    message: str,
    system_prompt: str | None = None,
    tool_declarations: list[dict] | None = None,
    tool_fns: dict | None = None,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
    session_id: str = "",
):
    """Async generator behind :func:`generate_reply`. Yields
    ``{"type": "status", "label": "…"}`` events as the turn progresses (so the
    client can show *"Searching the web…"* while it actually happens instead of
    a flat *"thinking"*), then one final
    ``{"type": "reply", "text": str, "tools_used": list[str]}``.

    Served only through LiveKit Inference — a gateway failure raises, there is
    no direct-Google fallback.
    """
    async for ev in _reply_events_inference(
        message, system_prompt, tool_declarations, tool_fns,
        image=image, uid=uid, feature=feature, session_id=session_id,
    ):
        yield ev


async def generate_reply(
    message: str,
    system_prompt: str | None = None,
    tool_declarations: list[dict] | None = None,
    tool_fns: dict | None = None,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
    session_id: str = "",
) -> Reply:
    """Gemini's reply to a single user message as a :class:`Reply` — collects
    :func:`generate_reply_events`. Streaming callers use the generator directly.
    """
    text = ""
    tools: list[str] = []
    async for ev in generate_reply_events(
        message,
        system_prompt,
        tool_declarations,
        tool_fns,
        image=image,
        uid=uid,
        feature=feature,
        session_id=session_id,
    ):
        if ev["type"] == "reply":
            text, tools = ev["text"], ev["tools_used"]
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    return Reply(text=text, tools_used=tools)


async def research(
    prompt: str,
    system_prompt: str | None = None,
    *,
    uid: str | None = None,
    feature: str = "misc",
    max_output_tokens: int = 4096,
    timeout: float | None = None,
) -> tuple[str, list[dict]]:
    """DISABLED (founder rule 2026-11-04 — see ``docs/DIRECT_GOOGLE_KILL_AUDIT.md``
    item 3): grounded web research needs Google Search / URL-context grounding,
    which only exists on the direct-Google path. The LiveKit gateway has no
    equivalent, so this raises instead of calling Google. Founder-decision
    item: restore only with a LiveKit-served equivalent or an explicit
    exception. The signature is kept so every caller keeps working unchanged
    (each already treats a research failure as an honest, non-fatal error).

    Founder exception granted 2026-11-07: web *search* is restored as
    retrieval, not inference — the chat tool and the research reports fetch
    result links + snippets through the capped Programmable Search path in
    :mod:`web_search` (hard 100/day free-quota cap, fail closed) and hand
    them to the LiveKit-routed model. Grounded synthesis through THIS
    function stays disabled."""
    raise llm_routing.DirectGoogleDisabledError(
        "live web search is unavailable: grounded research needs direct "
        "Google grounding, which is disabled — all inference goes through "
        "LiveKit (founder decision required to restore it)"
    )


class UnparseableReplyError(RuntimeError, json.JSONDecodeError):
    """A model reply that is not parseable JSON, carrying the raw text.

    The usual cause is a budget-truncated reply (``finish_reason="length"``):
    the model ran on inside one field and the JSON was cut mid-string. The
    completed fields are still in the text — a best-effort caller can salvage
    them instead of treating the whole call as lost. It subclasses both
    :class:`RuntimeError` and :class:`json.JSONDecodeError`, so existing
    handlers (``except Exception`` and ``except json.JSONDecodeError`` alike)
    see the same failure as before.
    """

    def __init__(self, text: str, finish_reason: str | None = None) -> None:
        json.JSONDecodeError.__init__(
            self, "Model reply is not parseable JSON.", text, 0
        )
        self.text = text
        self.finish_reason = finish_reason


def _parse_json_text(text: str) -> object:
    text = text.strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text[4:] if text[:4].lower() == "json" else text
    return json.loads(text.strip())


async def _generate_json_inference(
    contents: str,
    system_prompt: str,
    response_schema: dict | None,
    photo_parts: list[tuple[bytes, str]],
    *,
    uid: str | None,
    feature: str,
    temperature: float,
    session_id: str,
    max_tokens: int = 4096,
) -> object:
    user_content: object = contents
    if photo_parts:
        user_content = [
            inference_llm.media_part(b, m) for b, m in photo_parts
        ] + [{"type": "text", "text": contents}]
    model = CONFIG.inference_json_model
    response = await inference_llm.complete(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        response_schema=response_schema,
        temperature=temperature,
        max_tokens=max_tokens,
    )
    token_ledger.record(
        uid, feature, response, model=model, session_id=session_id or None,
    )
    if not response.text.strip():
        raise RuntimeError("Gemini returned an empty JSON response.")
    try:
        return _parse_json_text(response.text)
    except Exception:
        # A reply that fails to parse is undiagnosable without the raw
        # text: best-effort callers swallow this raise and return something
        # empty. Log the shape of the reply (finish reason, plus both ends
        # of the text — a budget-truncated reply is cut at the tail), then
        # raise carrying the raw text so a caller that can use the completed
        # fields (dm_assist's salvage) can recover them instead of losing
        # the whole call.
        logger.warning(
            "generate_json: unparseable model reply "
            "(finish_reason=%s, chars=%d) head=%r tail=%r",
            response.finish_reason, len(response.text),
            response.text[:600], response.text[-400:],
        )
        raise UnparseableReplyError(
            response.text, response.finish_reason
        ) from None


async def generate_json(
    contents: str,
    system_prompt: str,
    response_schema: dict | None = None,
    image: tuple[bytes, str] | None = None,
    *,
    images: list[tuple[bytes, str]] | None = None,
    uid: str | None = None,
    feature: str = "misc",
    enforce_cap: bool = True,
    temperature: float = 0.2,
    session_id: str = "",
    max_tokens: int = 4096,
) -> object:
    """Run a structured Gemini call and return the parsed JSON value. Pass
    ``image=(bytes, mime)`` for a single-image vision call (photo-attribute
    extraction, §6.3), or ``images=[(bytes, mime), …]`` for a multi-image pass
    (the physical-attributes read over a user's whole photo set).

    ``enforce_cap=False`` still records the spend to ``uid`` but skips the
    out-of-credits gate — for Ayma-initiated background work (e.g. the
    re-engagement check-in) that shouldn't fail just because the user is broke.

    Served only through LiveKit Inference. A media type the gateway cannot
    take (e.g. HEIC, m4a) raises honestly instead of going to Vertex; a
    gateway failure raises, there is no direct-Google fallback.

    Raises on an empty or unparseable response so callers can treat it as
    best-effort; an unparseable reply raises :class:`UnparseableReplyError`
    carrying the raw text. ``max_tokens`` caps the completion budget
    (default 4096) — a caller whose reply is short by construction passes a
    smaller cap so a runaway field is cut off cheaply instead of burning
    the whole budget.
    """
    if enforce_cap:
        token_ledger.check(uid)

    photo_parts = list(images or ([image] if image is not None else []))
    bad = [m for _, m in photo_parts if inference_llm.media_part(b"", m) is None]
    if bad:
        raise llm_routing.DirectGoogleDisabledError(
            "media type(s) not served by LiveKit Inference and the direct "
            f"path is disabled: {', '.join(sorted(set(bad)))}"
        )
    return await _generate_json_inference(
        contents, system_prompt, response_schema, photo_parts,
        uid=uid, feature=feature, temperature=temperature,
        session_id=session_id, max_tokens=max_tokens,
    )


async def edit_image(
    image_bytes: bytes,
    mime_type: str,
    instruction: str,
    *,
    uid: str | None = None,
    feature: str = "misc",
) -> tuple[bytes, str]:
    """Edit ``image_bytes`` per ``instruction`` with the user's selected image
    model (the ``edit_photo`` tool, §"Chat about it"). Returns the edited
    image's raw bytes and mime type.

    Thin wrapper over :func:`generate_image` (same model, same call shape) —
    kept as its own name so the edit path's callers/tests and the generation
    path's stay independently greppable."""
    return await generate_image(
        instruction, image=(image_bytes, mime_type), uid=uid, feature=feature
    )


async def generate_image(
    prompt: str,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
) -> tuple[bytes, str]:
    """Generate an image from ``prompt`` with the user's selected image model
    (Models screen; default Gemini-direct). Pass ``image=(bytes, mime)`` to
    ground the generation in a reference photo (an edit, or "a caricature of
    ME"); without it this is pure text-to-image. Returns the generated image's
    raw bytes and mime type.

    Image generation is the ONE founder-authorized direct-Google inference
    exception (``image_gen.py``, 2026-11-08): the direct provider call, the
    pluggable model catalog and the fail-closed daily cap all live there, so
    this stays a thin public face with no direct call of its own. The per-user
    credit gate (:func:`token_ledger.check`) runs first so an out-of-credits
    user never consumes the daily cap. On a non-``ok`` outcome this raises
    ``RuntimeError`` carrying the outcome's user-safe message — both skill
    callers (``skills.generate_image`` / ``skills.photo_edit``) catch it and
    relay it as a plain-text chat turn instead of a broken image."""
    import image_gen

    token_ledger.check(uid)
    outcome = await image_gen.generate(
        prompt, image=image, uid=uid, feature=feature
    )
    if outcome.status == image_gen.STATUS_OK:
        return outcome.image_bytes, outcome.mime
    raise RuntimeError(outcome.message)
