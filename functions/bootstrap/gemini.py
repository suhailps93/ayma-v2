"""Gemini client: text chat replies (§1.7 step 2) and structured JSON calls
for the wiki ingest pipeline (§2.3, Step 21).

The model id comes only from ``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import json
import logging
from functools import lru_cache

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.gemini")

# Transient upstream statuses worth one quick retry — the Vertex `global`
# endpoint occasionally 503s / rate-limits the first call from a cold client.
_RETRY_STATUS = {429, 500, 502, 503, 504}
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
    """`client.aio.models.generate_content` with a short retry on transient
    upstream errors."""
    for attempt in range(_RETRIES + 1):
        try:
            return await client.aio.models.generate_content(**kwargs)
        except genai_errors.APIError as exc:
            code = getattr(exc, "code", None) or getattr(
                exc, "status_code", None
            )
            if attempt < _RETRIES and code in _RETRY_STATUS:
                logger.warning(
                    "gemini %s on attempt %d/%d — retrying",
                    code, attempt + 1, _RETRIES + 1,
                )
                await asyncio.sleep(_RETRY_BACKOFF * (attempt + 1))
                continue
            raise


async def generate_reply(
    message: str,
    system_prompt: str | None = None,
    tool_declarations: list[dict] | None = None,
    tool_fns: dict | None = None,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
) -> str:
    """Return Gemini's reply to a single user message, steered by ``system_prompt``
    (the composed persona, §13.5).

    Pass ``image=(bytes, mime)`` for a photo the user attached in chat — it is
    prepended to the message as a vision part (§2.2).

    ``tool_declarations`` (name/description/JSON-schema params) plus ``tool_fns``
    (name → callable) enable one round of manual function calling (§13.6):
    automatic function calling is disabled because it cannot introspect the
    session-bound closures.
    """
    tools = None
    afc = None
    if tool_declarations:
        tools = [types.Tool(function_declarations=tool_declarations)]
        afc = types.AutomaticFunctionCallingConfig(disable=True)

    def _config() -> types.GenerateContentConfig:
        return types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.9,
            max_output_tokens=1024,
            tools=tools,
            automatic_function_calling=afc,
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

    calls = list(response.function_calls or [])
    if calls and tool_fns:
        parts = []
        for call in calls:
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

    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    return text


async def generate_json(
    contents: str,
    system_prompt: str,
    response_schema: dict | None = None,
    image: tuple[bytes, str] | None = None,
    *,
    uid: str | None = None,
    feature: str = "misc",
) -> object:
    """Run a structured Gemini call and return the parsed JSON value. Pass
    ``image=(bytes, mime)`` for a vision call (photo-attribute extraction, §6.3).

    Raises on an empty or unparseable response so callers can treat it as
    best-effort.
    """
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
