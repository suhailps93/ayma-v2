"""Gemini client: text chat replies (§1.7 step 2) and structured JSON calls
for the wiki ingest pipeline (§2.3, Step 21).

The model id comes only from ``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field
from functools import lru_cache

from google import genai
from google.genai import types

import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.gemini")

# Friendly, user-facing labels for the tools Ayma can invoke in a chat turn —
# shown in the client as a small caption on her reply ("what she just did").
_TOOL_LABELS = {
    "web_search": "Searched the web",
    "url_context": "Read a link",
    "google_maps": "Checked the map",
    "add_followup_question": "Noted a follow-up",
    "set_profile_field": "Updated your profile",
    "set_voice_preference": "Changed Ayma's voice",
    "record_feedback": "Logged feedback",
    "set_user_steering": "Saved a preference",
}


def _tool_label(name: str) -> str:
    return _TOOL_LABELS.get(name, name.replace("_", " ").capitalize())


@dataclass
class Reply:
    """A chat reply plus the ordered, de-duplicated list of user-facing tool
    labels Ayma used to produce it (empty when she just answered)."""

    text: str
    tools_used: list[str] = field(default_factory=list)

    def __str__(self) -> str:  # keep drop-in string behaviour for logs
        return self.text


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
    """Gemini's reply to a single user message, steered by ``system_prompt``
    (the composed persona, §13.5), as a :class:`Reply` (``.text`` +
    ``.tools_used`` — user-facing labels for whatever tools ran this turn).

    Pass ``image=(bytes, mime)`` for a photo the user attached in chat — it is
    prepended to the message as a vision part (§2.2).

    ``tool_declarations`` (name/description/JSON-schema params) plus ``tool_fns``
    (name → callable) enable one round of manual function calling (§13.6):
    automatic function calling is disabled because it cannot introspect the
    session-bound closures.
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
    response = await _generate(
        client,
        model=CONFIG.gemini_model, contents=contents, config=_config(),
    )
    token_ledger.record(uid, feature, response)

    used: list[str] = []
    seen: set[str] = set()

    def _note(name: str) -> None:
        if name not in seen:
            seen.add(name)
            used.append(_tool_label(name))

    for name in _grounding_tools(response):
        _note(name)

    calls = list(response.function_calls or [])
    if calls and tool_fns:
        parts = []
        for call in calls:
            _note(call.name)
            fn = tool_fns.get(call.name)
            try:
                result = fn(**dict(call.args or {})) if fn else "unknown tool"
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
        token_ledger.record(uid, feature, response)
        for name in _grounding_tools(response):
            _note(name)

    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    return Reply(text=text, tools_used=used)


async def generate_json(
    contents: str,
    system_prompt: str,
    response_schema: dict | None = None,
    image: tuple[bytes, str] | None = None,
    *,
    uid: str | None = None,
    feature: str = "misc",
    enforce_cap: bool = True,
) -> object:
    """Run a structured Gemini call and return the parsed JSON value. Pass
    ``image=(bytes, mime)`` for a vision call (photo-attribute extraction, §6.3).

    ``enforce_cap=False`` still records the spend to ``uid`` but skips the
    out-of-credits gate — for Ayma-initiated background work (e.g. the
    re-engagement check-in) that shouldn't fail just because the user is broke.

    Raises on an empty or unparseable response so callers can treat it as
    best-effort.
    """
    if enforce_cap:
        token_ledger.check(uid)

    parts: object = contents
    if image is not None:
        parts = [
            types.Part.from_bytes(data=image[0], mime_type=image[1]),
            contents,
        ]
    response = await _generate(
        _client(),
        model=CONFIG.gemini_model,
        contents=parts,
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.2,
            max_output_tokens=4096,
            response_mime_type="application/json",
            response_schema=response_schema,
        ),
    )
    token_ledger.record(uid, feature, response)
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty JSON response.")
    return json.loads(text)
