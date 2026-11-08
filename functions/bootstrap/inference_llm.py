"""LiveKit Inference text client — the non-Vertex path behind ``gemini.py``.

LiveKit Inference is an OpenAI-compatible gateway (``/v1/chat/completions``)
that fronts Gemini (and other) models. It authenticates with a short-lived JWT
signed from the same ``LIVEKIT_API_KEY`` / ``LIVEKIT_API_SECRET`` the app
already uses to mint room tokens (read from the environment at call time, never
stored). The gateway works standalone — no ``AgentSession`` is required.

What this module hands back is deliberately shaped like the slice of a
``google-genai`` response the rest of the app reads (``.text``,
``.function_calls``, ``.usage_metadata``) so ``token_ledger.record`` meters an
Inference call exactly like a Vertex one.

Image (jpeg/png/webp/gif) and wav/mp3 audio input work through
``media_part``. Not available through the gateway (verified live, see
``docs/LIVEKIT_INFERENCE_MIGRATION.md``): Google Search / URL-context / Maps
grounding. Callers that need grounding stay on Vertex.
"""

from __future__ import annotations

import asyncio
import base64
import datetime
import json
import logging
import os
from dataclasses import dataclass, field
from types import SimpleNamespace

import openai
from livekit import api

from config import CONFIG

logger = logging.getLogger("ayma.inference")

_RETRIES = 2
_RETRY_BACKOFF = 0.6
_TOKEN_TTL_SECONDS = 600

_client_instance: openai.AsyncOpenAI | None = None


@dataclass
class FunctionCall:
    """One model-requested tool call (mirrors ``google.genai`` ``FunctionCall``)."""

    id: str
    name: str
    args: dict
    extra_content: dict | None = None


@dataclass
class InferenceResponse:
    text: str
    function_calls: list[FunctionCall] = field(default_factory=list)
    # The assistant turn as an OpenAI message dict, ready to be replayed in the
    # next request (carries Gemini thought signatures in ``extra_content``).
    assistant_message: dict = field(default_factory=dict)
    usage_metadata: SimpleNamespace = field(default_factory=SimpleNamespace)
    # OpenAI ``finish_reason`` for the choice ("stop", "length", "tool_calls",
    # …). A ``length`` here with empty ``text`` means the completion budget was
    # spent before any visible content (thinking model burned it on reasoning).
    finish_reason: str | None = None


def _mint_token() -> str:
    key = os.getenv("LIVEKIT_API_KEY")
    secret = os.getenv("LIVEKIT_API_SECRET")
    if not key or not secret:
        raise RuntimeError(
            "LiveKit Inference needs LIVEKIT_API_KEY / LIVEKIT_API_SECRET in "
            "the environment."
        )
    return (
        api.AccessToken(key, secret)
        .with_identity("ayma-api")
        .with_inference_grants(api.access_token.InferenceGrants(perform=True))
        .with_ttl(datetime.timedelta(seconds=_TOKEN_TTL_SECONDS))
        .to_jwt()
    )


def _client() -> openai.AsyncOpenAI:
    global _client_instance
    if _client_instance is None:
        _client_instance = openai.AsyncOpenAI(
            api_key="unset",  # replaced with a fresh JWT on every call
            base_url=CONFIG.livekit_inference_url,
            max_retries=0,
            timeout=CONFIG.inference_timeout_seconds,
        )
    _client_instance.api_key = _mint_token()
    return _client_instance


def to_openai_tools(declarations: list[dict]) -> list[dict]:
    """Gemini-style function declarations -> OpenAI ``tools``."""
    return [
        {
            "type": "function",
            "function": {
                "name": d["name"],
                "description": d.get("description", ""),
                "parameters": d.get("parameters")
                or {"type": "object", "properties": {}},
            },
        }
        for d in declarations
    ]


def image_part(data: bytes, mime_type: str) -> dict:
    b64 = base64.b64encode(data).decode("ascii")
    return {
        "type": "image_url",
        "image_url": {"url": f"data:{mime_type};base64,{b64}"},
    }


_IMAGE_MIMES = frozenset({"image/jpeg", "image/png", "image/webp", "image/gif"})
# Audio the gateway decodes (verified live: wav transcribed; mp3 is validated by
# the decoder). Other containers (m4a/webm/opus/ogg/aac) are not proven to be
# read correctly, so they stay on Vertex rather than risk a wrong transcript.
_AUDIO_FORMATS = {
    "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav",
    "audio/mpeg": "mp3", "audio/mp3": "mp3",
}


def media_part(data: bytes, mime_type: str) -> dict | None:
    """OpenAI content part for an image or audio blob, or ``None`` when the
    gateway cannot take that mime type (the caller then stays on Vertex)."""
    mime = (mime_type or "").split(";")[0].strip().lower()
    if mime in _IMAGE_MIMES:
        return image_part(data, mime)
    fmt = _AUDIO_FORMATS.get(mime)
    if fmt:
        return {
            "type": "input_audio",
            "input_audio": {
                "data": base64.b64encode(data).decode("ascii"), "format": fmt,
            },
        }
    return None


def _usage(raw) -> SimpleNamespace:
    """OpenAI ``usage`` -> the ``usage_metadata`` shape ``token_ledger`` reads.
    ``completion_tokens`` already includes reasoning tokens (verified live), so
    output is billed in full; cached tokens are a subset of the prompt."""
    if raw is None:
        return SimpleNamespace(
            prompt_token_count=0, candidates_token_count=0,
            total_token_count=0, cached_content_token_count=0,
        )
    details = getattr(raw, "prompt_tokens_details", None)
    cached = int(getattr(details, "cached_tokens", 0) or 0)
    prompt = int(raw.prompt_tokens or 0)
    completion = int(raw.completion_tokens or 0)
    return SimpleNamespace(
        prompt_token_count=prompt,
        candidates_token_count=completion,
        total_token_count=int(raw.total_tokens or (prompt + completion)),
        cached_content_token_count=cached,
    )


def _parse(raw) -> InferenceResponse:
    choice = raw.choices[0]
    msg = choice.message
    calls: list[FunctionCall] = []
    replay_calls: list[dict] = []
    for tc in msg.tool_calls or []:
        try:
            args = json.loads(tc.function.arguments or "{}")
        except json.JSONDecodeError:
            args = {}
        extra = getattr(tc, "extra_content", None)
        calls.append(
            FunctionCall(id=tc.id, name=tc.function.name, args=args,
                         extra_content=extra)
        )
        entry = {
            "id": tc.id,
            "type": "function",
            "function": {"name": tc.function.name,
                         "arguments": tc.function.arguments or "{}"},
        }
        if extra:
            entry["extra_content"] = extra
        replay_calls.append(entry)
    assistant: dict = {"role": "assistant", "content": msg.content or ""}
    if replay_calls:
        assistant["tool_calls"] = replay_calls
    return InferenceResponse(
        text=msg.content or "",
        function_calls=calls,
        assistant_message=assistant,
        usage_metadata=_usage(raw.usage),
        finish_reason=getattr(choice, "finish_reason", None),
    )


async def complete(
    *,
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    response_schema: dict | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    max_completion_tokens: int | None = None,
    reasoning_effort: str | None = None,
) -> InferenceResponse:
    """One chat completion through LiveKit Inference, with a backed-off
    retry-on-anything policy. A timeout is not retried (the wait already
    spent the budget).

    ``max_completion_tokens`` is sent INSTEAD of ``max_tokens`` when given:
    the GPT-5 family behind the gateway rejects ``max_tokens`` outright
    (HTTP 400, verified live 2026-11-07), so callers serving those models
    must pass the budget this way."""
    kwargs: dict = {"model": model, "messages": messages}
    if tools:
        kwargs["tools"] = tools
    if response_schema is not None:
        kwargs["response_format"] = {
            "type": "json_schema",
            "json_schema": {
                "name": "response", "schema": response_schema, "strict": False,
            },
        }
    if temperature is not None:
        kwargs["temperature"] = temperature
    if max_completion_tokens is not None:
        kwargs["max_completion_tokens"] = max_completion_tokens
    elif max_tokens is not None:
        kwargs["max_tokens"] = max_tokens
    if reasoning_effort:
        kwargs["reasoning_effort"] = reasoning_effort

    for attempt in range(_RETRIES + 1):
        try:
            raw = await asyncio.wait_for(
                _client().chat.completions.create(**kwargs),
                timeout=CONFIG.inference_timeout_seconds,
            )
            return _parse(raw)
        except asyncio.TimeoutError:
            logger.error(
                "inference completion timed out after %.0fs",
                CONFIG.inference_timeout_seconds,
            )
            raise
        except openai.APITimeoutError:
            logger.error("inference completion timed out")
            raise
        except openai.BadRequestError:
            raise  # deterministic — retrying the same request cannot help
        except Exception as exc:  # noqa: BLE001 - broad on purpose, see docstring
            if attempt >= _RETRIES:
                raise
            logger.warning(
                "inference completion failed (%s: %s) on attempt %d/%d — retrying",
                type(exc).__name__, exc, attempt + 1, _RETRIES + 1,
            )
            await asyncio.sleep(_RETRY_BACKOFF * (attempt + 1))
    raise RuntimeError("unreachable")  # pragma: no cover
