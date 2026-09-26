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
            return await client.aio.models.generate_content(**kwargs)
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


async def generate_reply_events(
    message: str,
    system_prompt: str | None = None,
    tool_declarations: list[dict] | None = None,
    tool_fns: dict | None = None,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
):
    """Async generator behind :func:`generate_reply`. Yields
    ``{"type": "status", "label": "…"}`` events as the turn progresses (so the
    client can show *"Searching the web…"* while it actually happens instead of
    a flat *"thinking"*), then one final
    ``{"type": "reply", "text": str, "tools_used": list[str]}``.
    """
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
    if CONFIG.gemini_maps_api_key:
        # Google Maps grounding (place lookups). Needs the Maps Grounding API
        # enabled on the project and the key passed through — dormant until
        # GEMINI_MAPS_API_KEY is set.
        tools = (tools or []) + [
            types.Tool(
                google_maps=types.GoogleMaps(
                    auth_config=types.AuthConfig(
                        api_key=CONFIG.gemini_maps_api_key
                    )
                )
            )
        ]

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
    token_ledger.record(uid, feature, response, model=CONFIG.gemini_model)

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
                    result = await result
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
        token_ledger.record(uid, feature, response, model=CONFIG.gemini_model)
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
    token_ledger.record(uid, feature, response, model=CONFIG.gemini_model)
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

    Same shape as the TTS preview path (``voice_preview._synthesize``): a
    ``generate_content`` call with a non-text ``response_modalities`` entry,
    reading the result back out of the first ``inline_data`` part. Raises
    ``RuntimeError`` when the model returns no image part — a content-policy
    refusal, or a transient failure — so the caller (``skills.photo_edit``)
    can fall back to plain text advice instead of a broken chat turn.
    """
    token_ledger.check(uid)
    response = await _generate(
        _client(),
        model=CONFIG.gemini_image_edit_model,
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type=mime_type),
            instruction,
        ],
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
