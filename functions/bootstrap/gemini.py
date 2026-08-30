"""Gemini client: text chat replies (§1.7 step 2) and structured JSON calls
for the wiki ingest pipeline (§2.3, Step 21).

The model id comes only from ``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import json
from functools import lru_cache

from google import genai
from google.genai import types

from config import CONFIG


@lru_cache(maxsize=1)
def _client() -> genai.Client:
    if CONFIG.use_vertex:
        # ADC = the Cloud Run runtime service identity; no API key.
        return genai.Client(
            vertexai=True,
            project=CONFIG.project_id or None,
            location=CONFIG.vertex_location,
        )
    return genai.Client()  # picks up GOOGLE_API_KEY from the environment


async def generate_reply(
    message: str,
    system_prompt: str | None = None,
    tool_declarations: list[dict] | None = None,
    tool_fns: dict | None = None,
) -> str:
    """Return Gemini's reply to a single user message, steered by ``system_prompt``
    (the composed persona, §13.5).

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

    client = _client()
    response = await client.aio.models.generate_content(
        model=CONFIG.gemini_model, contents=message, config=_config()
    )

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
        response = await client.aio.models.generate_content(
            model=CONFIG.gemini_model,
            contents=[
                types.Content(
                    role="user", parts=[types.Part(text=message)]
                ),
                response.candidates[0].content,
                types.Content(role="user", parts=parts),
            ],
            config=_config(),
        )

    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    return text


async def generate_json(
    contents: str,
    system_prompt: str,
    response_schema: dict | None = None,
    image: tuple[bytes, str] | None = None,
) -> object:
    """Run a structured Gemini call and return the parsed JSON value. Pass
    ``image=(bytes, mime)`` for a vision call (photo-attribute extraction, §6.3).

    Raises on an empty or unparseable response so callers can treat it as
    best-effort.
    """
    parts: object = contents
    if image is not None:
        parts = [
            types.Part.from_bytes(data=image[0], mime_type=image[1]),
            contents,
        ]
    response = await _client().aio.models.generate_content(
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
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty JSON response.")
    return json.loads(text)
