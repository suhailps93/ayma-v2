"""Gemini client: text chat replies (§1.7 step 2) and structured JSON calls
for the wiki ingest pipeline (§2.3, Step 21).

The model id comes only from ``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import re
from dataclasses import dataclass, field
from functools import lru_cache

from google import genai
from google.genai import types

import inference_llm
import feature_flags
import llm_routing
import token_ledger
from config import CONFIG
from tool_labels import TOOL_LABELS as _TOOL_LABELS
from tool_labels import WORKING_LABELS as _WORKING_LABELS
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


def _grounding_tools(response) -> list[str]:
    """Built-in grounding the API ran itself this turn (no function round-trip):
    ``web_search`` when it issued search queries, ``url_context`` when it fetched
    a URL. Best-effort — the metadata shape varies by model/SDK."""
    out: list[str] = []
    try:
        cand = (response.candidates or [None])[0]
        gm = getattr(cand, "grounding_metadata", None)
        if gm and getattr(gm, "google_maps_widget_context_token", None):
            out.append("google_maps")
        elif gm and (
            getattr(gm, "web_search_queries", None)
            or getattr(gm, "grounding_chunks", None)
        ):
            out.append("web_search")
        if getattr(cand, "url_context_metadata", None):
            out.append("url_context")
    except Exception:  # noqa: BLE001 - metadata is advisory only
        pass
    return out

# A cold Cloud Run instance's first Gemini call sometimes fails — a transient
# 429/5xx from the Vertex `global` endpoint, or an ADC/gRPC hiccup fetching the
# first auth token. The call has no side effects before it returns, so a couple
# of backed-off retries on *any* error are safe. TokenCapExceeded is raised by
# token_ledger.check outside this helper, so it is never retried here.
_RETRIES = 2
_RETRY_BACKOFF = 0.6

# A hung model call or tool must end in an error the user can retry, never an
# endless "Thinking…" (founder tester report, 2026-10-20). A timed-out Gemini
# call is not retried — the wait already burned the budget. Module-level so
# tests can shrink them.
_GENERATE_TIMEOUT_SECONDS = 75.0
_TOOL_TIMEOUT_SECONDS = 120.0


@lru_cache(maxsize=1)
def _client() -> genai.Client:
    if CONFIG.use_vertex:
        # ADC = the Cloud Run runtime service identity; no API key.
        return genai.Client(
            vertexai=True,
            project=CONFIG.project_id or None,
            # gemini_model is Vertex-global-only (3.x flash 404s regionally).
            location=CONFIG.gemini_location,
        )
    return genai.Client()  # picks up GOOGLE_API_KEY from the environment


async def _generate(client, **kwargs):
    """`client.aio.models.generate_content` with a couple of backed-off
    retries — see the note above."""
    for attempt in range(_RETRIES + 1):
        try:
            return await asyncio.wait_for(
                client.aio.models.generate_content(**kwargs),
                timeout=_GENERATE_TIMEOUT_SECONDS,
            )
        except asyncio.TimeoutError:
            logger.error(
                "gemini generate timed out after %.0fs", _GENERATE_TIMEOUT_SECONDS
            )
            raise
        except Exception as exc:  # noqa: BLE001 - broad on purpose; see note
            if attempt >= _RETRIES:
                raise
            logger.warning(
                "gemini generate failed (%s: %s) on attempt %d/%d — retrying",
                type(exc).__name__, exc, attempt + 1, _RETRIES + 1,
            )
            await asyncio.sleep(_RETRY_BACKOFF * (attempt + 1))


async def warmup() -> None:
    """Pay the cold-start cost (ADC token, gRPC channel, first-call flake)
    before the instance serves real traffic. Best-effort."""
    try:
        await _generate(
            _client(),
            model=CONFIG.gemini_model,
            contents="ping",
            config=types.GenerateContentConfig(max_output_tokens=1),
        )
        logger.info("gemini warmup ok")
    except Exception as exc:  # noqa: BLE001
        logger.warning("gemini warmup failed: %s", exc)


class _InferenceUnavailable(Exception):
    """The first LiveKit Inference call of a chat turn failed and Vertex
    fallback is enabled. Raised before any tool has run, so the turn can be
    replayed on Vertex without repeating a side effect."""


_WEB_SEARCH_TOOL = {
    "name": "web_search",
    "description": (
        "Search the live web and read pages. Use it for anything current or "
        "factual you are unsure about, and to read a link the user pasted "
        "(put the URL in the query). Returns a researched summary."
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
    """Grounded lookup for the Inference chat path: the gateway has no Google
    Search grounding, so the search itself runs as a (small) grounded Vertex
    call and the answer is handed back to the Inference model as a tool result."""
    prose, sources = await research(query, uid=uid, feature=feature)
    if sources:
        listed = "; ".join(s["url"] for s in sources[:5])
        return f"{prose}\n\nSources: {listed}"
    return prose


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
    """LiveKit Inference twin of the Vertex chat loop in
    :func:`generate_reply_events` — same events, same one-tool-round shape."""
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

    async def _call():
        return await inference_llm.complete(
            model=model, messages=messages, tools=tools,
            temperature=0.9, max_tokens=1024, reasoning_effort=effort,
        )

    token_ledger.check(uid)
    yield {"type": "status", "label": "Thinking…"}
    try:
        response = await _call()
    except Exception as exc:  # noqa: BLE001 - see _InferenceUnavailable
        if llm_routing.fallback_enabled():
            raise _InferenceUnavailable() from exc
        logger.error(
            "chat: LiveKit Inference failed and the Google fallback is off "
            "(llm_fallback_to_google) — surfacing the error: %s: %s",
            type(exc).__name__, exc,
        )
        raise
    token_ledger.record(
        uid, feature, response, model=model, session_id=session_id or None,
    )

    used: list[str] = []
    seen: set[str] = set()

    def _note(name: str, label: str | None = None) -> None:
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
            _note(call.name, label)
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
    """
    fallback_from: str | None = None
    if llm_routing.route_for("chat") == "inference":
        try:
            async for ev in _reply_events_inference(
                message, system_prompt, tool_declarations, tool_fns,
                image=image, uid=uid, feature=feature, session_id=session_id,
            ):
                yield ev
            return
        except _InferenceUnavailable as exc:
            logger.warning(
                "chat: LiveKit Inference failed (%s) — falling back to Vertex",
                exc.__cause__,
            )
            fallback_from = token_ledger.PROVIDER_LIVEKIT_INFERENCE

    tools: list | None = None
    afc = None
    if tool_declarations:
        tools = [types.Tool(function_declarations=tool_declarations)]
        afc = types.AutomaticFunctionCallingConfig(disable=True)
    if CONFIG.gemini_web_search:
        # Built-in grounding: live Google Search + reading any URL the user
        # pastes. The API runs these itself in the same turn — no function-call
        # round-trip — so they sit alongside the session's function tools.
        tools = (tools or []) + [
            types.Tool(google_search=types.GoogleSearch()),
            types.Tool(url_context=types.UrlContext()),
        ]
    if feature_flags.enabled("maps_grounding"):
        # Google Maps grounding (place lookups) — Vertex built-in tool, no key.
        tools = (tools or []) + [types.Tool(google_maps=types.GoogleMaps())]

    thinking = None
    lvl = (CONFIG.gemini_chat_thinking_level or "").strip().lower()
    if lvl in ("low", "medium", "high"):
        thinking = types.ThinkingConfig(thinking_level=lvl)

    def _config() -> types.GenerateContentConfig:
        return types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.9,
            max_output_tokens=1024,
            tools=tools,
            automatic_function_calling=afc,
            thinking_config=thinking,
        )

    image_part = (
        types.Part.from_bytes(data=image[0], mime_type=image[1])
        if image is not None
        else None
    )
    contents: object = message
    if image_part is not None:
        contents = [image_part, message]

    token_ledger.check(uid)
    client = _client()

    yield {"type": "status", "label": "Thinking…"}
    response = await _generate(
        client,
        model=CONFIG.gemini_model, contents=contents, config=_config(),
    )
    token_ledger.record(
        uid, feature, response, model=CONFIG.gemini_model,
        session_id=session_id or None, fallback_from=fallback_from,
    )

    used: list[str] = []
    seen: set[str] = set()

    def _note(name: str, label: str | None = None) -> None:
        key = label or name
        if key not in seen:
            seen.add(key)
            used.append(label or _tool_label(name))

    for name in _grounding_tools(response):
        _note(name)

    calls = list(response.function_calls or [])
    if calls and tool_fns:
        parts = []
        for call in calls:
            label = None
            if call.name == "deep_dive":
                who = str((call.args or {}).get("full_name") or "").strip()
                if who:
                    subj = "yourself" if (
                        str((call.args or {}).get("subject")) == "self"
                    ) else who
                    label = f"Researched {subj} online"
            _note(call.name, label)
            # The slow part — a research call, a vision call — happens right
            # here. Tell the client what it's waiting on.
            yield {"type": "status", "label": _working_label(call.name)}
            fn = tool_fns.get(call.name)
            try:
                result = fn(**dict(call.args or {})) if fn else "unknown tool"
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
            parts.append(
                types.Part.from_function_response(
                    name=call.name, response={"result": result}
                )
            )
        first_parts = [types.Part(text=message)]
        if image_part is not None:
            first_parts.insert(0, image_part)
        yield {"type": "status", "label": "Writing…"}
        response = await _generate(
            client,
            model=CONFIG.gemini_model,
            contents=[
                types.Content(role="user", parts=first_parts),
                response.candidates[0].content,
                types.Content(role="user", parts=parts),
            ],
            config=_config(),
        )
        token_ledger.record(
            uid, feature, response, model=CONFIG.gemini_model,
            session_id=session_id or None, fallback_from=fallback_from,
        )
        for name in _grounding_tools(response):
            _note(name)

    text = strip_inline_refs((response.text or "").strip())
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    yield {"type": "reply", "text": text, "tools_used": used}


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
) -> tuple[str, list[dict]]:
    """A single grounded web-research call: ``google_search`` + ``url_context``
    on, no function tools, no JSON schema. Returns ``(prose, sources)`` where
    ``sources`` is ``[{"url", "title"}]`` pulled from the grounding metadata.
    Metered like any Gemini call."""
    token_ledger.check(uid)
    cfg = types.GenerateContentConfig(
        system_instruction=system_prompt,
        temperature=0.3,
        max_output_tokens=max_output_tokens,
        tools=[
            types.Tool(google_search=types.GoogleSearch()),
            types.Tool(url_context=types.UrlContext()),
        ],
    )
    response = await _generate(
        _client(), model=CONFIG.gemini_model, contents=prompt, config=cfg
    )
    token_ledger.record(uid, feature, response, model=CONFIG.gemini_model)

    sources: list[dict] = []
    seen_urls: set[str] = set()
    try:
        cand = (response.candidates or [None])[0]
        gm = getattr(cand, "grounding_metadata", None)
        for chunk in (getattr(gm, "grounding_chunks", None) or []):
            web = getattr(chunk, "web", None)
            url = getattr(web, "uri", None)
            if url and url not in seen_urls:
                seen_urls.add(url)
                sources.append(
                    {"url": url, "title": getattr(web, "title", "") or url}
                )
    except Exception:  # noqa: BLE001 - metadata is advisory
        logger.warning("research: grounding metadata parse failed", exc_info=True)

    return strip_inline_refs((response.text or "").strip()), sources


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
    return _parse_json_text(response.text)


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

    Raises on an empty or unparseable response so callers can treat it as
    best-effort.
    """
    if enforce_cap:
        token_ledger.check(uid)

    photo_parts = list(images or ([image] if image is not None else []))
    route = llm_routing.route_for("vision" if photo_parts else "json")
    if route == "inference" and any(
        inference_llm.media_part(b"", m) is None for _, m in photo_parts
    ):
        # A media type the gateway cannot take (e.g. HEIC, m4a): not a failure,
        # so no Inference attempt and no fallback tag — straight to Vertex.
        logger.info(
            "%s: media type not supported by LiveKit Inference — using Vertex",
            feature,
        )
        route = "vertex"
    fallback_from: str | None = None
    if route == "inference":
        try:
            return await _generate_json_inference(
                contents, system_prompt, response_schema, photo_parts,
                uid=uid, feature=feature, temperature=temperature,
                session_id=session_id,
            )
        except Exception as exc:  # noqa: BLE001 - fall back or re-raise below
            if not llm_routing.fallback_enabled():
                logger.error(
                    "%s: LiveKit Inference failed and the Google fallback is "
                    "off (llm_fallback_to_google) — surfacing the error: %s: %s",
                    feature, type(exc).__name__, exc,
                )
                raise
            logger.warning(
                "%s: LiveKit Inference failed (%s: %s) — falling back to Vertex",
                feature, type(exc).__name__, exc,
            )
            fallback_from = token_ledger.PROVIDER_LIVEKIT_INFERENCE
    parts: object = contents
    if photo_parts:
        parts = [
            types.Part.from_bytes(data=b, mime_type=m) for b, m in photo_parts
        ] + [contents]
    response = await _generate(
        _client(),
        model=CONFIG.gemini_model,
        contents=parts,
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=temperature,
            max_output_tokens=4096,
            response_mime_type="application/json",
            response_schema=response_schema,
        ),
    )
    token_ledger.record(
        uid, feature, response, model=CONFIG.gemini_model,
        session_id=session_id or None, fallback_from=fallback_from,
    )
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty JSON response.")
    return json.loads(text)


async def edit_image(
    image_bytes: bytes,
    mime_type: str,
    instruction: str,
    *,
    uid: str | None = None,
    feature: str = "misc",
) -> tuple[bytes, str]:
    """Edit ``image_bytes`` per ``instruction`` with the LOCKED Gemini
    image-edit model (``config.py`` — the ``edit_photo`` tool, §"Chat about
    it"). Returns the edited image's raw bytes and mime type.

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
    """Generate an image from ``prompt`` with the LOCKED Gemini image model
    (``config.py`` — the ``generate_image`` / ``edit_photo`` tools). Pass
    ``image=(bytes, mime)`` to ground the generation in a reference photo
    (an edit, or "a caricature of ME"); without it this is pure text-to-image.
    Returns the generated image's raw bytes and mime type.

    Same shape as the TTS preview path (``voice_preview._synthesize``): a
    ``generate_content`` call with a non-text ``response_modalities`` entry,
    reading the result back out of the first ``inline_data`` part. Raises
    ``RuntimeError`` when the model returns no image part — a content-policy
    refusal, or a transient failure — so the caller (``skills.photo_edit`` /
    ``skills.generate_image``) can fall back to plain text instead of a
    broken chat turn.
    """
    token_ledger.check(uid)
    parts: list = []
    if image is not None:
        parts.append(types.Part.from_bytes(data=image[0], mime_type=image[1]))
    parts.append(prompt)
    response = await _generate(
        _client(),
        model=CONFIG.gemini_image_edit_model,
        contents=parts,
        config=types.GenerateContentConfig(
            response_modalities=["TEXT", "IMAGE"],
        ),
    )
    token_ledger.record(uid, feature, response, model=CONFIG.gemini_image_edit_model)
    try:
        parts = response.candidates[0].content.parts or []
    except (AttributeError, IndexError, TypeError):
        parts = []
    for part in parts:
        inline = getattr(part, "inline_data", None)
        data = getattr(inline, "data", None) if inline else None
        if data:
            mime = (getattr(inline, "mime_type", "") or "image/png").strip()
            return data, mime
    # No image part — most likely a safety/content-policy refusal in the text.
    refusal = strip_inline_refs((getattr(response, "text", "") or "").strip())
    raise RuntimeError(refusal or "Gemini did not return an edited image")
