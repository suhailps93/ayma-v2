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
import web_search
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


_WEB_SEARCH_TOOL = {
    "name": "web_search",
    "description": (
        "Search the live web. Use it for anything current or factual you "
        "are unsure about — events, news, places, prices, schedules, what "
        "is happening near the user — and include a place the user "
        "mentioned or that is already in context when the question is "
        "local. Returns search results (titles, snippets, links) for you "
        "to answer from. Search has a daily free-quota cap: if the result "
        "says it is used up for today, tell the user exactly that — never "
        "present it as a glitch or a technical problem."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "What to look up, or the URL to read.",
            }
        },
        "required": ["query"],
    },
}


async def _web_search_tool(query: str, *, uid: str | None, feature: str) -> str:
    """The chat `web_search` tool backend — the capped Programmable Search
    path in :mod:`web_search` (founder restore, 2026-11-07).

    Retrieval only: the LiveKit brain decides to search, the backend
    fetches result links + snippets under the hard daily free-quota cap,
    and the model answers from them. Direct-Google grounding stays
    disabled — :func:`research` still raises for direct callers — and the
    capped path reports its states honestly (paused at the cap,
    unavailable when unconfigured) instead of an internal error.
    """
    outcome = await web_search.search(query)
    return web_search.format_outcome(outcome, query)


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
    if CONFIG.gemini_web_search:
        declarations.append(_WEB_SEARCH_TOOL)
        fns["web_search"] = lambda query="", **_: _web_search_tool(
            str(query), uid=uid, feature=feature
        )
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

    async def _call(max_tokens: int = chat_max_tokens):
        return await inference_llm.complete(
            model=model, messages=messages, tools=tools,
            temperature=0.9, max_tokens=max_tokens, reasoning_effort=effort,
        )

    token_ledger.check(uid)
    yield {"type": "status", "label": "Thinking…"}
    response = await _call()
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
        # A thinking model can spend the whole completion budget on reasoning
        # and emit no visible content; the gateway reports that as a "length"
        # truncation. Retry ONCE with a larger budget (no loop) before giving
        # up — stays entirely on LiveKit Inference, no provider reroute.
        if (response.finish_reason or "").lower() == "length":
            retry_max_tokens = chat_max_tokens * 2
            logger.warning(
                "chat: retrying once on LiveKit Inference with max_tokens=%s "
                "after length truncation", retry_max_tokens,
            )
            response = await _call(retry_max_tokens)
            token_ledger.record(
                uid, feature, response, model=model,
                session_id=session_id or None,
            )
            text = strip_inline_refs(response.text.strip())
        if not text:
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
        max_tokens=4096,
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
        # of the text — a budget-truncated reply is cut at the tail),
        # then re-raise unchanged.
        logger.warning(
            "generate_json: unparseable model reply "
            "(finish_reason=%s, chars=%d) head=%r tail=%r",
            response.finish_reason, len(response.text),
            response.text[:600], response.text[-400:],
        )
        raise


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
    best-effort.
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
        session_id=session_id,
    )


async def edit_image(
    image_bytes: bytes,
    mime_type: str,
    instruction: str,
    *,
    uid: str | None = None,
    feature: str = "misc",
) -> tuple[bytes, str]:
    """DISABLED (founder rule 2026-11-04 — see ``docs/DIRECT_GOOGLE_KILL_AUDIT.md``
    item 4): photo editing needs the direct-Google image model, which the
    LiveKit gateway does not serve. Raises instead of calling Google."""
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
    """DISABLED (founder rule 2026-11-04 — see ``docs/DIRECT_GOOGLE_KILL_AUDIT.md``
    item 4): image generation needs the direct-Google image model, which the
    LiveKit gateway does not serve. Raises instead of calling Google. The
    message is user-safe: both skill callers interpolate it into a chat reply."""
    raise llm_routing.DirectGoogleDisabledError(
        "image generation isn't available right now"
    )
