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
import re
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
SURFACES = (
    "chat", "matching", "reports", "practice", "voice", "dm_coach", "translate",
)

# --- Capability map (single source of truth) ------------------------------ #
#
# The unified Brain (§13.10) is ONE user-selectable LLM vendor driving ALL text
# surfaces, with an automatic per-capability fallback to Gemini. A "brain" is a
# provider VENDOR (``gemini`` | ``meta``), not a model id. Each capability a
# surface needs is checked against the chosen brain's set here; if the brain
# lacks it, the call resolves to Gemini instead (``get_user_brain_provider``).
# This is the one place the per-brain capabilities are declared.

CAP_TEXT = "text"      # plain text generation / collected reply
CAP_JSON = "json"      # structured / JSON-schema output (generate_json)
CAP_VISION = "vision"  # genuinely reads attached image content
CAP_WEB = "web"        # live web / URL reading (Gemini url_context grounding)
CAP_TOOLS = "tools"    # function/tool calling in a chat turn

ALL_CAPABILITIES = (CAP_TEXT, CAP_JSON, CAP_VISION, CAP_WEB, CAP_TOOLS)

# Per-brain capabilities. Gemini is fully multimodal + grounded. Meta/Muse Spark
# does text, JSON (matching/reports/chat already use it via generate_json) and
# tool-calling, but NOT vision (text/reasoning-only — it would hallucinate a
# read off an image it never processed) and NOT web (no Google-Search / URL
# grounding on the Meta API). Verified against the working Meta paths in
# ``MetaProvider`` (generate_json, _meta_reply_events with tools). Web → Gemini
# and vision → Gemini are therefore forced for every brain here except Gemini.
BRAIN_CAPABILITIES: dict[str, frozenset[str]] = {
    PROVIDER_GEMINI: frozenset(
        {CAP_TEXT, CAP_JSON, CAP_VISION, CAP_WEB, CAP_TOOLS}
    ),
    PROVIDER_META: frozenset({CAP_TEXT, CAP_JSON, CAP_TOOLS}),
}

# User-facing Brain catalog for the "Ayma's models" screen: id (vendor) → short
# label + description. Ids are vendor names (``PROVIDER_*``), never model ids
# (model ids stay in ``config.py``). ``available`` is always True here — both
# vendors are wired — but the field is kept so the Flutter contract matches the
# voice catalog's ``available``/``requires_secret`` shape.
BRAINS: dict[str, dict[str, object]] = {
    PROVIDER_GEMINI: {
        "id": PROVIDER_GEMINI,
        "label": "Gemini",
        "description": "Google Gemini — reads images, does live web research, "
        "and uses tools. The most capable all-round brain.",
        "available": True,
    },
    PROVIDER_META: {
        "id": PROVIDER_META,
        "label": "Meta Muse Spark",
        "description": "Meta's Muse Spark — fast reasoning for chat, matching "
        "and coaching. Image reading and web research fall back to Gemini.",
        "available": True,
    },
}


def brain_capabilities(brain: str) -> frozenset[str]:
    """Capabilities of ``brain`` (a provider vendor). Unknown → Gemini's set, so
    a typo is treated as the fully-capable default rather than crashing."""
    return BRAIN_CAPABILITIES.get(
        (brain or "").strip().lower(), BRAIN_CAPABILITIES[PROVIDER_GEMINI]
    )


def available_brains() -> list[dict[str, object]]:
    """The Brain catalog for ``GET /brain/preference``: each brain plus the
    capabilities it has (so the UI can describe the Gemini fallback). Gemini
    first, then Meta — the order they appear in the dropdown."""
    out: list[dict[str, object]] = []
    for bid in (PROVIDER_GEMINI, PROVIDER_META):
        entry = dict(BRAINS[bid])
        entry["capabilities"] = sorted(BRAIN_CAPABILITIES[bid])
        out.append(entry)
    return out


class LLMProvider(ABC):
    """One LLM vendor behind a stable, surface-agnostic interface.

    The three methods mirror ``gemini.py`` exactly so a call site can swap
    ``gemini.X(...)`` for ``get_llm_provider(surface).X(...)`` with no other
    change: :meth:`generate_json` (structured output), :meth:`generate_reply`
    (collected text) and :meth:`generate_reply_events` (the event-streamed chat
    turn).
    """

    name: str

    #: The capabilities this provider genuinely has, from :data:`BRAIN_CAPABILITIES`
    #: (the single source of truth). Used by :func:`get_user_brain_provider` to
    #: route a capability the chosen brain lacks (web, vision) to Gemini instead.
    capabilities: frozenset[str] = frozenset()

    @property
    def supports_vision(self) -> bool:
        """Whether this provider genuinely processes attached image content. A
        text/reasoning-only vendor (e.g. Muse Spark) is ``False`` so a
        vision-dependent call site routes around it (:func:`get_vision_provider`)
        rather than get a hallucinated read off an image the model never saw.
        Derived from :attr:`capabilities` so vision lives in one map."""
        return CAP_VISION in self.capabilities

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
    #: Gemini is multimodal + grounded: every capability (incl. vision + web).
    capabilities = BRAIN_CAPABILITIES[PROVIDER_GEMINI]

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


_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.IGNORECASE | re.DOTALL)
_CODE_FENCE = re.compile(r"```[A-Za-z0-9_-]*\n(.*?)```", re.DOTALL)


def _coerce_json_text(text: str) -> str:
    """Return just the JSON document embedded in a model reply.

    Muse Spark is a reasoning model and can wrap its JSON in a ```` ```json ````
    fence, precede it with a ``<think>…</think>`` block, or emit chain-of-thought
    prose around it. This strips those and returns the first balanced top-level
    JSON object/array so reasoning text never reaches ``json.loads`` (and so a
    stray thought can never leak through into a parsed field). When no balanced
    object is found the stripped original is returned unchanged, so ``json.loads``
    still raises and the caller's Gemini fallback kicks in."""
    if not text:
        return text
    stripped = _THINK_BLOCK.sub("", text).strip()
    fence = _CODE_FENCE.search(stripped)
    if fence:
        stripped = fence.group(1).strip()

    start = next(
        (i for i, ch in enumerate(stripped) if ch in "{["), -1
    )
    if start == -1:
        return stripped

    open_ch = stripped[start]
    close_ch = "}" if open_ch == "{" else "]"
    depth = 0
    in_str = False
    escaped = False
    for i in range(start, len(stripped)):
        ch = stripped[i]
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return stripped[start : i + 1]
    return stripped


def _strip_keys(obj):
    """Recursively strip whitespace from JSON object keys. Muse Spark
    occasionally emits ``"strengths "`` (trailing space), which would make a
    schema field silently read as missing."""
    if isinstance(obj, dict):
        return {k.strip(): _strip_keys(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_strip_keys(v) for v in obj]
    return obj


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
    #: Muse Spark does text, JSON and tool-calling; NOT vision, NOT web — those
    #: resolve to Gemini (:func:`get_user_brain_provider`, :func:`get_vision_provider`).
    capabilities = BRAIN_CAPABILITIES[PROVIDER_META]

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
            # Muse Spark can surround the JSON with reasoning / a code fence;
            # extract just the JSON document so chain-of-thought never leaks
            # into a parsed field (and a malformed reply still raises → Gemini).
            return _strip_keys(json.loads(_coerce_json_text(text)))
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
    "dm_coach": lambda: CONFIG.llm_provider_dm_coach,
    "translate": lambda: CONFIG.llm_provider_translate,
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


def get_vision_provider(surface: str) -> LLMProvider:
    """The provider for ``surface`` ONLY if it genuinely does vision, else
    Gemini — the capability-aware route for an image/vision-dependent call.

    A surface routed to a text/reasoning-only vendor (Muse Spark) would
    otherwise *silently* return a plausible but hallucinated read off a photo
    the model never actually processed — and, returning valid JSON, never
    trip the on-error Gemini fallback. So any image call (the face/body
    appearance reports) picks the configured provider only when
    ``supports_vision`` is set, and falls back to Gemini otherwise. This lives
    in code, not an env flag, so it survives a surface being flipped to Meta
    and matches the unified-brain capability map (vision → Gemini)."""
    provider = get_llm_provider(surface)
    if provider.supports_vision:
        return provider
    logger.info(
        "surface %s is routed to a vision-less provider (%s) — using Gemini "
        "for this image call",
        surface, provider.name,
    )
    return _gemini_singleton()


# --- Unified Brain (§13.10) ----------------------------------------------- #


def _provider_for_name(name: str) -> LLMProvider:
    """A provider instance for a vendor name (``gemini`` | ``meta``). ``meta``
    carries the Gemini fallback when ``llm_meta_fallback`` is on; anything else
    is the Gemini default."""
    if (name or "").strip().lower() == PROVIDER_META:
        fallback = _gemini_singleton() if CONFIG.llm_meta_fallback else None
        return MetaProvider(fallback=fallback)
    return _gemini_singleton()


def read_brain_pref(uid: str | None) -> str:
    """The user's saved unified-Brain vendor (``ayma_brain_model`` on
    ``users/{uid}/profile/main``), lower-cased, or ``""`` when unset / unreadable
    / no uid. Best-effort: a read failure returns ``""`` (→ the env-flag default),
    never raises, so brain resolution can't take a surface down. Factored out so
    tests can monkeypatch it instead of standing up Firestore."""
    if not uid:
        return ""
    try:
        import schema
        from db import get_db

        snap = schema.profile_doc(get_db(), uid).get()
        return str((snap.to_dict() or {}).get(schema.PF_AYMA_BRAIN_MODEL, "")).strip().lower()
    except Exception:  # noqa: BLE001 - best-effort; fall back to env default
        logger.exception("could not read ayma_brain_model for %s", uid)
        return ""


def get_user_brain_provider(
    uid: str | None, surface: str, *, needs: str | None = None
) -> LLMProvider:
    """The provider for ``surface`` honouring the user's unified **Brain** choice
    (§13.10), with a per-capability fallback to Gemini.

    Resolution:

    * The user's saved ``ayma_brain_model`` picks the brain; with none saved the
      per-surface env flag (:func:`get_llm_provider`) is the default — production
      is unchanged until a user actually chooses a brain.
    * If ``needs`` is given and the chosen brain does NOT have that capability
      (see :data:`BRAIN_CAPABILITIES`), the call resolves to **Gemini** instead.
      So ``needs="web"`` and ``needs="vision"`` always land on Gemini (Muse has
      neither), while ``text``/``json``/``tools`` stay on the chosen brain.

    One brain drives every text surface; a capability the brain lacks is never
    silently dropped — it is routed to Gemini, consistent with
    :func:`get_vision_provider`."""
    if surface not in _SURFACE_FLAG:
        raise ValueError(
            f"unknown LLM surface {surface!r}; expected one of {SURFACES}"
        )
    if needs is not None and needs not in ALL_CAPABILITIES:
        raise ValueError(
            f"unknown capability {needs!r}; expected one of {ALL_CAPABILITIES}"
        )

    chosen = read_brain_pref(uid)
    if chosen in BRAIN_CAPABILITIES:
        provider = _provider_for_name(chosen)
    else:
        # No saved brain (or an unknown value) → the surface's env-flag default.
        provider = get_llm_provider(surface)

    if needs is not None and needs not in provider.capabilities:
        if provider.name != PROVIDER_GEMINI:
            logger.info(
                "brain %s lacks %r for surface %s — using Gemini for this call",
                provider.name, needs, surface,
            )
        return _gemini_singleton()
    return provider
