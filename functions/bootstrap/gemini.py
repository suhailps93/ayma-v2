"""Gemini client for text chat (§1.7 step 2).

Step 10: a plain single-turn call — no persona (Step 11), no wiki/memory
(Step 24). The model id comes only from ``config.py`` (AGENTS.md).
"""

from __future__ import annotations

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


async def generate_reply(message: str, system_prompt: str | None = None) -> str:
    """Return Gemini's reply to a single user message, optionally steered by a
    system prompt (the composed persona, §13.5)."""
    response = await _client().aio.models.generate_content(
        model=CONFIG.gemini_model,
        contents=message,
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
            temperature=0.9,
            max_output_tokens=1024,
        ),
    )
    text = (response.text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned an empty response.")
    return text
