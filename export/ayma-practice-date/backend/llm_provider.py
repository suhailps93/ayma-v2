"""Higher-level LLM provider abstraction — hackathon Deliverable A.

Ayma's LLM work (chat, matching, reports, practice/coaching, voice) is reached
through :func:`get_llm_provider`, which returns the provider a *surface* is
configured for. Two implementations:

* :class:`GeminiProvider` — a thin wrapper over the existing ``gemini.py`` calls
  (Vertex / Gemini Developer API). This is the default for every surface, so the
  abstraction changes no production behaviour until a flag is flipped.
* :class:`MetaProvider` — Meta's Muse Spark via the OpenAI-compatible Meta Model
  API (``config.meta_api_base_url``, ``META_API_KEY`` from the environment /
  Secret Manager). Supports text, event-streamed chat and structured/JSON
  output; on any failure it falls back to Gemini when ``llm_meta_fallback`` is
  on, so a flip can never take a surface down.

Relationship to ``docs/LIVEKIT_INFERENCE_MIGRATION.md``: that is a *lower*-level
routing of Gemini traffic (Vertex direct vs the LiveKit Inference gateway) and
is orthogonal to this choice. This module picks the *provider vendor* (Gemini vs
Meta); when the provider is Gemini, whatever Gemini transport ``gemini.py`` uses
still applies. See ``docs/META_PROVIDER.md``.

Model ids and the per-surface flags come only from ``config.py`` (``AGENTS.md``).
The ``META_API_KEY`` secret is read from the environment here, never stored in
config and never hardcoded.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from abc import ABC, abstractmethod
from functools import lru_cache
from typing import AsyncIterator

import gemini
import token_ledger
from config import CONFIG
from gemini import Reply

logger = logging.getLogger("ayma.llm_provider")

PROVIDER_GEMINI = "gemini"
PROVIDER_META = "meta"

# The surfaces that can flip independently (``config.llm_provider_<surface>``).
SURFACES = ("chat", "matching", "reports", "practice", "voice")


class LLMProvider(ABC):
    """One LLM vendor behind a stable, surface-agnostic interface.

    The three methods mirror ``gemini.py`` exactly so a call site can swap
    ``gemini.X(...)`` for ``get_llm_provider(surface).X(...)`` with no other
    change: :meth:`generate_json` (structured output), :meth:`generate_reply`
    (collected text) and :meth:`generate_reply_events` (the event-streamed chat
    turn).
    """

    name: str

    @abstractmethod
    async def generate_json(
        self,
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
        ...

    @abstractmethod
    async def generate_reply(
        self,
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
        ...

    @abstractmethod
    def generate_reply_events(
        self,
        message: str,
        system_prompt: str | None = None,
        tool_declarations: list[dict] | None = None,
        tool_fns: dict | None = None,
        *,
        image: tuple[bytes, str] | None = None,
        uid: str | None = None,
        feature: str = "misc",
        session_id: str = "",
    ) -> AsyncIterator[dict]:
        ...


class GeminiProvider(LLMProvider):
    """Delegates straight to ``gemini.py`` — the production default."""

    name = PROVIDER_GEMINI

    async def generate_json(self, *args, **kwargs) -> object:
        return await gemini.generate_json(*args, **kwargs)

    async def generate_reply(self, *args, **kwargs) -> Reply:
        return await gemini.generate_reply(*args, **kwargs)

    def generate_reply_events(self, *args, **kwargs) -> AsyncIterator[dict]:
        # gemini.generate_reply_events is itself an async generator; returning
        # it (not awaiting) keeps ``async for`` working at the call site.
        return gemini.generate_reply_events(*args, **kwargs)


# --- Meta Model API (OpenAI-compatible) ----------------------------------- #


def _response_format(response_schema: dict | None, name: str) -> dict | None:
    """Map a Gemini-style JSON schema dict to the OpenAI ``response_format``.

    With a schema -> ``json_schema`` (non-strict: Ayma's schemas use partial
    ``required`` and omit ``additionalProperties``, which OpenAI strict mode
    forbids). With none -> plain ``json_object`` so the model still returns
    parseable JSON."""
    if not response_schema:
        return {"type": "json_object"}
    return {
        "type": "json_schema",
        "json_schema": {
            "name": name,
            "schema": response_schema,
            "strict": False,
        },
    }


def _data_url(data: bytes, mime: str) -> str:
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


def _user_content(text: str, media: list[tuple[bytes, str]]):
    """One OpenAI chat ``user`` message content: plain text, or a multimodal
    parts list when images are attached (``image_url`` data URLs)."""
    if not media:
        return text
    parts: list[dict] = [
        {"type": "image_url", "image_url": {"url": _data_url(b, m)}}
        for b, m in media
    ]
    parts.append({"type": "text", "text": text})
    return parts


class _MetaUsage:
    """``usage_metadata``-shaped view of an OpenAI usage object so the existing
    :func:`token_ledger.record` meters a Meta call unchanged."""

    def __init__(self, usage) -> None:
        self.prompt_token_count = int(getattr(usage, "prompt_tokens", 0) or 0)
        self.candidates_token_count = int(
            getattr(usage, "completion_tokens", 0) or 0
        )
        self.total_token_count = int(getattr(usage, "total_tokens", 0) or 0)
        # Meta's OpenAI surface does not report an implicit-cache subset.
        self.cached_content_token_count = 0


class _MetaResponse:
    def __init__(self, usage) -> None:
        self.usage_metadata = _MetaUsage(usage)


def _meta_tools(tool_declarations: list[dict] | None) -> list[dict] | None:
    """Gemini function declarations -> OpenAI ``tools`` array."""
    if not tool_declarations:
        return None
    return [
        {
            "type": "function",
            "function": {
                "name": d.get("name"),
                "description": d.get("description", ""),
                "parameters": d.get("parameters")
                or {"type": "object", "properties": {}},
            },
        }
        for d in tool_declarations
    ]


class MetaProvider(LLMProvider):
    """Meta Muse Spark via the OpenAI-compatible Meta Model API.

    ``fallback`` (a :class:`GeminiProvider` when ``llm_meta_fallback`` is on) is
    used on any failure so a flipped surface degrades to Gemini instead of
    erroring. A ``client`` can be injected for tests; otherwise it is built lazily
    from ``config.meta_api_base_url`` + the ``META_API_KEY`` environment secret.
    """

    name = PROVIDER_META

    def __init__(
        self,
        *,
        fallback: LLMProvider | None = None,
        client=None,
    ) -> None:
        self._fallback = fallback
        self._client = client

    def _get_client(self):
        if self._client is not None:
            return self._client
        api_key = os.getenv("META_API_KEY", "")
        if not api_key:
            raise RuntimeError(
                "META_API_KEY is not set — add it to Secret Manager and mount "
                "it on the service before routing a surface to Meta "
                "(see docs/META_PROVIDER.md)."
            )
        try:
            from openai import AsyncOpenAI
        except ModuleNotFoundError as exc:  # pragma: no cover - dep in reqs
            raise RuntimeError(
                "the 'openai' package is required for the Meta provider"
            ) from exc
        self._client = AsyncOpenAI(
            base_url=CONFIG.meta_api_base_url, api_key=api_key
        )
        return self._client

    # -- structured / JSON ------------------------------------------------- #

    async def generate_json(
        self,
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
        if enforce_cap:
            token_ledger.check(uid)
        media = list(images or ([image] if image is not None else []))
        try:
            client = self._get_client()
            resp = await client.chat.completions.create(
                model=CONFIG.meta_chat_model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": _user_content(contents, media)},
                ],
                temperature=temperature,
                max_tokens=4096,
                response_format=_response_format(response_schema, feature),
                extra_body={"reasoning_effort": CONFIG.meta_reasoning_effort},
            )
            token_ledger.record(
                uid, feature, _MetaResponse(getattr(resp, "usage", None)),
                model=CONFIG.meta_chat_model, session_id=session_id or None,
            )
            text = (resp.choices[0].message.content or "").strip()
            if not text:
                raise RuntimeError("Meta returned an empty JSON response.")
            return json.loads(text)
        except Exception as exc:  # noqa: BLE001 - fall back to Gemini
            if self._fallback is None:
                raise
            logger.warning(
                "Meta generate_json failed (%s: %s) — falling back to Gemini",
                type(exc).__name__, exc,
            )
            return await self._fallback.generate_json(
                contents, system_prompt, response_schema, image,
                images=images, uid=uid, feature=feature,
                enforce_cap=False, temperature=temperature,
                session_id=session_id,
            )

    # -- text (collected) -------------------------------------------------- #

    async def generate_reply(
        self,
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
        text = ""
        tools: list[str] = []
        async for ev in self.generate_reply_events(
            message, system_prompt, tool_declarations, tool_fns,
            image=image, uid=uid, feature=feature, session_id=session_id,
        ):
            if ev["type"] == "reply":
                text, tools = ev["text"], ev["tools_used"]
        if not text:
            raise RuntimeError("Meta returned an empty response.")
        return Reply(text=text, tools_used=tools)

    # -- event-streamed chat ---------------------------------------------- #

    async def generate_reply_events(
        self,
        message: str,
        system_prompt: str | None = None,
        tool_declarations: list[dict] | None = None,
        tool_fns: dict | None = None,
        *,
        image: tuple[bytes, str] | None = None,
        uid: str | None = None,
        feature: str = "misc",
        session_id: str = "",
    ) -> AsyncIterator[dict]:
        token_ledger.check(uid)
        media = [image] if image is not None else []
        try:
            async for ev in self._meta_reply_events(
                message, system_prompt, tool_declarations, tool_fns,
                media, uid, feature, session_id,
            ):
                yield ev
        except Exception as exc:  # noqa: BLE001 - fall back to Gemini
            if self._fallback is None:
                raise
            logger.warning(
                "Meta chat failed (%s: %s) — falling back to Gemini",
                type(exc).__name__, exc,
            )
            async for ev in self._fallback.generate_reply_events(
                message, system_prompt, tool_declarations, tool_fns,
                image=image, uid=uid, feature=feature, session_id=session_id,
            ):
                yield ev

    async def _meta_reply_events(
        self, message, system_prompt, tool_declarations, tool_fns,
        media, uid, feature, session_id,
    ) -> AsyncIterator[dict]:
        """One Meta chat turn, mirroring ``gemini.generate_reply_events``:
        status events then a single ``reply``. Runs at most one tool round
        (same as the Gemini path). Note: Meta has no Google-Search grounding, so
        a chat surface flipped to Meta loses live web/URL grounding — that stays
        Gemini-only (see docs/META_PROVIDER.md)."""
        client = self._get_client()
        tools = _meta_tools(tool_declarations)
        messages: list[dict] = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append(
            {"role": "user", "content": _user_content(message, media)}
        )

        from tool_labels import tool_label as _tool_label
        from tool_labels import working_label as _working_label

        used: list[str] = []
        seen: set[str] = set()

        def _note(label: str) -> None:
            if label not in seen:
                seen.add(label)
                used.append(label)

        yield {"type": "status", "label": "Thinking…"}
        resp = await client.chat.completions.create(
            model=CONFIG.meta_chat_model,
            messages=messages,
            temperature=0.9,
            max_tokens=1024,
            tools=tools,
            extra_body={"reasoning_effort": CONFIG.meta_reasoning_effort},
        )
        token_ledger.record(
            uid, feature, _MetaResponse(getattr(resp, "usage", None)),
            model=CONFIG.meta_chat_model, session_id=session_id or None,
        )
        msg = resp.choices[0].message
        calls = list(getattr(msg, "tool_calls", None) or [])

        if calls and tool_fns:
            messages.append(
                {
                    "role": "assistant",
                    "content": msg.content or "",
                    "tool_calls": [
                        {
                            "id": c.id,
                            "type": "function",
                            "function": {
                                "name": c.function.name,
                                "arguments": c.function.arguments,
                            },
                        }
                        for c in calls
                    ],
                }
            )
            for c in calls:
                name = c.function.name
                _note(_tool_label(name))
                yield {"type": "status", "label": _working_label(name)}
                try:
                    args = json.loads(c.function.arguments or "{}")
                except json.JSONDecodeError:
                    args = {}
                fn = tool_fns.get(name)
                try:
                    result = fn(**args) if fn else "unknown tool"
                    import inspect
                    if inspect.isawaitable(result):
                        result = await result
                except Exception as tool_exc:  # noqa: BLE001 - report, don't crash
                    result = f"error: {tool_exc}"
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": c.id,
                        "content": str(result),
                    }
                )
            yield {"type": "status", "label": "Writing…"}
            resp = await client.chat.completions.create(
                model=CONFIG.meta_chat_model,
                messages=messages,
                temperature=0.9,
                max_tokens=1024,
                tools=tools,
                extra_body={"reasoning_effort": CONFIG.meta_reasoning_effort},
            )
            token_ledger.record(
                uid, feature, _MetaResponse(getattr(resp, "usage", None)),
                model=CONFIG.meta_chat_model, session_id=session_id or None,
            )
            msg = resp.choices[0].message

        text = gemini.strip_inline_refs((msg.content or "").strip())
        if not text:
            raise RuntimeError("Meta returned an empty response.")
        yield {"type": "reply", "text": text, "tools_used": used}


# --- selection ------------------------------------------------------------ #


_SURFACE_FLAG = {
    "chat": lambda: CONFIG.llm_provider_chat,
    "matching": lambda: CONFIG.llm_provider_matching,
    "reports": lambda: CONFIG.llm_provider_reports,
    "practice": lambda: CONFIG.llm_provider_practice,
    "voice": lambda: CONFIG.llm_provider_voice,
}


@lru_cache(maxsize=1)
def _gemini_singleton() -> GeminiProvider:
    return GeminiProvider()


def get_llm_provider(surface: str) -> LLMProvider:
    """The provider configured for ``surface`` (one of :data:`SURFACES`).

    Reads ``config.llm_provider_<surface>`` (env ``LLM_PROVIDER_<SURFACE>``,
    default ``gemini``). ``meta`` returns a :class:`MetaProvider` carrying a
    Gemini fallback when ``config.llm_meta_fallback`` is on; anything else
    (including an unknown value, logged once) returns the Gemini default so a
    typo can never route traffic nowhere.
    """
    flag = _SURFACE_FLAG.get(surface)
    if flag is None:
        raise ValueError(
            f"unknown LLM surface {surface!r}; expected one of {SURFACES}"
        )
    choice = flag()
    if choice == PROVIDER_META:
        fallback = _gemini_singleton() if CONFIG.llm_meta_fallback else None
        return MetaProvider(fallback=fallback)
    if choice != PROVIDER_GEMINI:
        logger.warning(
            "LLM_PROVIDER for %s is %r (not gemini|meta) — using gemini",
            surface, choice,
        )
    return _gemini_singleton()
