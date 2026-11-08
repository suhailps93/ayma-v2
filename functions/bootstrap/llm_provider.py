"""Higher-level LLM provider abstraction — hackathon Deliverable A.

Ayma's LLM work (chat, matching, reports, practice/coaching, voice) is reached
through :func:`get_llm_provider`, which returns the provider a *surface* is
configured for. Three implementations:

* :class:`GeminiProvider` — a thin wrapper over the existing ``gemini.py`` calls
  (Vertex / Gemini Developer API). This is the default for every surface, so the
  abstraction changes no production behaviour until a flag is flipped.
* :class:`MetaProvider` — Meta's Muse Spark via the OpenAI-compatible Meta Model
  API (``config.meta_api_base_url``, ``META_API_KEY`` from the environment /
  Secret Manager). Supports text, event-streamed chat and structured/JSON
  output; on any failure it falls back to Gemini when ``llm_meta_fallback`` is
  on, so a flip can never take a surface down.
* :class:`OpenWeightsProvider` — the low-cost route: Muse Spark open weights
  over an OpenAI-compatible chat endpoint (``config.open_weights_api_base_url``,
  ``OPEN_WEIGHTS_API_KEY`` from the environment / Secret Manager). It carries
  NO paid fallback — an unconfigured or failing cheap path raises its explicit
  error instead of silently billing another vendor.

Relationship to ``docs/LIVEKIT_INFERENCE_MIGRATION.md``: that is a *lower*-level
routing of Gemini traffic (Vertex direct vs the LiveKit Inference gateway) and
is orthogonal to this choice. This module picks the *provider vendor* (Gemini vs
Meta); when the provider is Gemini, whatever Gemini transport ``gemini.py`` uses
still applies. See ``docs/META_PROVIDER.md``.

Model ids and the per-surface flags come only from ``config.py`` (``AGENTS.md``).
The ``META_API_KEY`` and ``OPEN_WEIGHTS_API_KEY`` secrets are read from the
environment here, never stored in config and never hardcoded.
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
import inference_llm
import token_ledger
from config import CONFIG
from gemini import Reply

logger = logging.getLogger("ayma.llm_provider")

PROVIDER_GEMINI = "gemini"
PROVIDER_META = "meta"
PROVIDER_OPEN_WEIGHTS = "open-weights"

# LiveKit Inference Brain vendors (founder order 2026-11-07: "Wire all the
# LiveKit models in"). Each is a Brain VENDOR id — never a model id; the
# LiveKit Inference model id for each vendor lives in ``config.py``
# (``CONFIG.livekit_brain_<vendor>_model``). Every one of these is served
# ONLY through LiveKit Inference (``inference_llm.complete`` — the same
# gateway + project LiveKit credentials Gemini already uses), so all of
# them run on the funded LiveKit credits. ZAI GLM is deliberately absent:
# it does not appear in the live LiveKit Inference LLM catalog
# (docs.livekit.io/agents/models/llm, fetched 2026-11-07) and a guessed id
# returns 404 from the gateway — never invent an id.
PROVIDER_GEMMA = "gemma"
PROVIDER_OPENAI = "openai"
PROVIDER_OPENAI_CHAT = "openai-chat"
PROVIDER_OPENAI_OSS = "openai-oss"
PROVIDER_KIMI = "kimi"
PROVIDER_DEEPSEEK = "deepseek"
PROVIDER_GROK = "grok"

#: The Brain vendors served through LiveKit Inference beyond Gemini
#: itself, in picker order.
LIVEKIT_BRAIN_VENDORS: tuple[str, ...] = (
    PROVIDER_GEMMA,
    PROVIDER_OPENAI,
    PROVIDER_OPENAI_CHAT,
    PROVIDER_OPENAI_OSS,
    PROVIDER_KIMI,
    PROVIDER_DEEPSEEK,
    PROVIDER_GROK,
)

_LIVEKIT_BRAIN_MODEL_ATTR: dict[str, str] = {
    PROVIDER_GEMMA: "livekit_brain_gemma_model",
    PROVIDER_OPENAI: "livekit_brain_openai_model",
    PROVIDER_OPENAI_CHAT: "livekit_brain_openai_chat_model",
    PROVIDER_OPENAI_OSS: "livekit_brain_openai_oss_model",
    PROVIDER_KIMI: "livekit_brain_kimi_model",
    PROVIDER_DEEPSEEK: "livekit_brain_deepseek_model",
    PROVIDER_GROK: "livekit_brain_grok_model",
}


def livekit_brain_model(vendor: str) -> str:
    """The LiveKit Inference model id for a LiveKit Brain vendor, or ""
    for anything else. The single mapping voice_catalog also uses, so a
    unified Brain pick and the voice cascade brain can never drift."""
    attr = _LIVEKIT_BRAIN_MODEL_ATTR.get((vendor or "").strip().lower())
    return str(getattr(CONFIG, attr)) if attr else ""

# The surfaces that can flip independently (``config.llm_provider_<surface>``).
SURFACES = (
    "chat", "matching", "reports", "practice", "voice", "dm_coach", "translate",
)

# --- Capability map (single source of truth) ------------------------------ #
#
# The unified Brain (§13.10) is ONE user-selectable LLM vendor driving ALL text
# surfaces, with an automatic per-capability fallback to Gemini. A "brain" is a
# provider VENDOR (``gemini`` | ``meta`` | ``open-weights``), not a model id.
# Each capability a
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
# The open-weights Muse Spark shares the Meta profile exactly (same model
# family, same OpenAI-compatible chat surface, no grounding) — only the
# endpoint, model id and no-paid-fallback rule differ (``OpenWeightsProvider``).
BRAIN_CAPABILITIES: dict[str, frozenset[str]] = {
    PROVIDER_GEMINI: frozenset(
        {CAP_TEXT, CAP_JSON, CAP_VISION, CAP_WEB, CAP_TOOLS}
    ),
    PROVIDER_META: frozenset({CAP_TEXT, CAP_JSON, CAP_TOOLS}),
    PROVIDER_OPEN_WEIGHTS: frozenset({CAP_TEXT, CAP_JSON, CAP_TOOLS}),
    # LiveKit Inference brains (2026-11-07). Text + structured JSON were
    # verified live through the gateway for every vendor below (the DM
    # coach schema). Vision flags are what the LIVE serving path actually
    # does, verified 2026-11-07 with a known-image probe: GPT-5, ChatGPT
    # Latest and Kimi read the image correctly; Gemma 4 answered wrong on
    # both probe images and Grok rejects image input (HTTP 422), so both
    # are vision-less HERE and image jobs route to Gemini. GPT OSS 120B
    # and DeepSeek are text-only models. No LiveKit brain has Gemini's web
    # grounding, so web always routes to Gemini. Tool calling is granted
    # only where the family is built for OpenAI-style function calling;
    # GPT OSS uses a different native tool format, so tool turns route to
    # Gemini for it (its catalog entry says so).
    PROVIDER_GEMMA: frozenset({CAP_TEXT, CAP_JSON, CAP_TOOLS}),
    PROVIDER_OPENAI: frozenset({CAP_TEXT, CAP_JSON, CAP_VISION, CAP_TOOLS}),
    PROVIDER_OPENAI_CHAT: frozenset(
        {CAP_TEXT, CAP_JSON, CAP_VISION, CAP_TOOLS}
    ),
    PROVIDER_OPENAI_OSS: frozenset({CAP_TEXT, CAP_JSON}),
    PROVIDER_KIMI: frozenset({CAP_TEXT, CAP_JSON, CAP_VISION, CAP_TOOLS}),
    PROVIDER_DEEPSEEK: frozenset({CAP_TEXT, CAP_JSON, CAP_TOOLS}),
    PROVIDER_GROK: frozenset({CAP_TEXT, CAP_JSON, CAP_TOOLS}),
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
    PROVIDER_GEMMA: {
        "id": PROVIDER_GEMMA,
        "label": "Gemma 4",
        "description": "Google's Gemma 4 31B, hosted by LiveKit — open "
        "reasoning for chat, matching and coaching. Image reading and web "
        "research fall back to Gemini.",
        "available": True,
    },
    PROVIDER_OPENAI: {
        "id": PROVIDER_OPENAI,
        "label": "GPT-5",
        "description": "OpenAI's GPT-5 via LiveKit — deep reasoning, reads "
        "images and uses tools. Web research falls back to Gemini.",
        "available": True,
    },
    PROVIDER_OPENAI_CHAT: {
        "id": PROVIDER_OPENAI_CHAT,
        "label": "ChatGPT Latest",
        "description": "OpenAI's latest ChatGPT model via LiveKit — reads "
        "images and uses tools. Web research falls back to Gemini.",
        "available": True,
    },
    PROVIDER_OPENAI_OSS: {
        "id": PROVIDER_OPENAI_OSS,
        "label": "GPT OSS 120B",
        "description": "OpenAI's open-weight GPT OSS 120B via LiveKit — "
        "chat and coaching. Image reading, tool use and web research fall "
        "back to Gemini.",
        "available": True,
    },
    PROVIDER_KIMI: {
        "id": PROVIDER_KIMI,
        "label": "Kimi K2.6",
        "description": "Moonshot AI's Kimi K2.6 via LiveKit — long-context "
        "reasoning, reads images and uses tools. Web research falls back "
        "to Gemini.",
        "available": True,
    },
    PROVIDER_DEEPSEEK: {
        "id": PROVIDER_DEEPSEEK,
        "label": "DeepSeek V4 Pro",
        "description": "DeepSeek's V4 Pro via LiveKit — strong reasoning "
        "for chat, matching and coaching. Image reading and web research "
        "fall back to Gemini.",
        "available": True,
    },
    PROVIDER_GROK: {
        "id": PROVIDER_GROK,
        "label": "Grok",
        "description": "xAI's Grok via LiveKit — fast, direct reasoning "
        "for chat, matching and coaching. Image reading and web research "
        "fall back to Gemini.",
        "available": True,
    },
}


def brain_is_credited(brain: str) -> bool:
    """Whether ``brain`` may be offered in a selection list or honoured as a
    saved preference on THIS deploy (``CONFIG.brain_credited_providers``).

    The LiveKit Inference brains (Gemini and the ``LIVEKIT_BRAIN_VENDORS``)
    run on the funded LiveKit credits; Meta Muse Spark bills the Meta
    Model API directly and open-weights bills Modal. A deploy that is not
    credited for a vendor (staging pins ``BRAIN_CREDITED_PROVIDERS`` to the
    LiveKit set, founder orders 2026-11-07) must never list it or serve it.
    Gemini — the funded default and the fallback of last resort — is always
    credited."""
    b = (brain or "").strip().lower()
    return b == PROVIDER_GEMINI or b in CONFIG.brain_credited_providers


def brain_capabilities(brain: str) -> frozenset[str]:
    """Capabilities of ``brain`` (a provider vendor). Unknown → Gemini's set, so
    a typo is treated as the fully-capable default rather than crashing."""
    return BRAIN_CAPABILITIES.get(
        (brain or "").strip().lower(), BRAIN_CAPABILITIES[PROVIDER_GEMINI]
    )


def available_brains() -> list[dict[str, object]]:
    """The Brain catalog for ``GET /brain/preference``: each brain plus the
    capabilities it has (so the UI can describe the Gemini fallback). Gemini
    first, then the other LiveKit Inference brains, then Meta — the order
    they appear in the dropdown. Only CREDITED brains are listed
    (:func:`brain_is_credited`): a deploy whose credited set is ``gemini``
    alone offers Gemini only."""
    out: list[dict[str, object]] = []
    for bid in (PROVIDER_GEMINI, *LIVEKIT_BRAIN_VENDORS, PROVIDER_META):
        if not brain_is_credited(bid):
            continue
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


# --- Open-weights cheap path (OpenAI-compatible) --------------------------- #


# Honest fallback when the open-weights brain leaks a bare / garbled tool name
# as its reply content instead of calling the tool (see
# :func:`_looks_like_leaked_tool_call`). Short and truthful: the common
# navigation / app-control commands are already executed deterministically
# BEFORE the model (``main._prepare_chat`` → ``app_control.detect_app_command``
# and ``set_model_stack.detect_stack_command``), so this only covers the long
# tail the weak 8B brain mangles — and the raw token is never shown to the user.
_TOOL_LEAK_FALLBACK = (
    "Sorry — I couldn't do that just now. Could you say it another way?"
)

# In-persona fallback when the open-weights brain BREAKS CHARACTER — reverts to
# a base-assistant disclaimer ("I'm just a language model", "as an AI
# assistant") or a generic refusal instead of answering as Ayma (founder bug
# 2026-11-03). The existing clean-language guardrail is prompt-level only
# (persona.md etc.), and the 8B brain ignores the system prompt, so the break
# has to be caught on the OUTPUT and replaced with a warm, in-character line —
# the disclaimer is never shown. Short and non-committal so it fits any turn.
_PERSONA_BREAK_FALLBACK = (
    "I'm right here with you — tell me a little more and I'll help with it."
)

# Base-model persona breaks / AI disclaimers Ayma must never utter. High-
# precision by design (she is an AI matchmaker, so a bare "I'm an AI …
# matchmaker" is legitimate and deliberately NOT matched): only the unmistakable
# base-assistant disclaimers and the generic "I can't help with that" refusal.
_PERSONA_BREAK_RE = re.compile(
    r"\b("
    r"language model"                               # "(just a|as a) language model"
    r"|as an? ai\b"                                 # "as an AI, I…"
    r"|(?:just|merely|only|simply) an? ai\b"        # "I'm just an AI"
    r"|ai (?:language )?(?:assistant|model)"        # "AI assistant" / "AI model"
    r"|artificial intelligence"                     # "I'm an artificial intelligence"
    r"|i (?:can'?t|cannot|can ?not|am (?:not able|unable) to|'m (?:not able|unable) to) "
    r"(?:really |actually )?(?:help|assist)(?: you)? with (?:that|this)"  # generic refusal
    r")\b",
    re.IGNORECASE,
)


def _looks_like_persona_break(text: str) -> bool:
    """True when ``text`` is an out-of-character base-assistant disclaimer /
    AI boilerplate / generic refusal Ayma must never say (she answers as a warm
    matchmaker, never "I'm just a language model"). Narrow on purpose so ordinary
    in-persona text — including Ayma truthfully describing herself as *your AI
    matchmaker* — is never flagged."""
    t = (text or "").strip()
    return bool(t) and bool(_PERSONA_BREAK_RE.search(t))


def guard_open_weights_text(
    text: str, had_tool_call: bool, tool_declarations=None
) -> str:
    """Finalize weak open-weights assistant text before it is shown: replace a
    leaked raw tool name (only meaningful as the whole content, so when no tool
    actually ran) or an out-of-character persona break with an honest in-persona
    fallback. A genuine reply passes through untouched. One place so the text
    chat path and any future cascade-output hook share the exact same rules."""
    if not had_tool_call and _looks_like_leaked_tool_call(text, tool_declarations):
        logger.warning(
            "open-weights leaked a bare tool name as content (suppressed): %r", text
        )
        return _TOOL_LEAK_FALLBACK
    if _looks_like_persona_break(text):
        logger.warning(
            "open-weights broke character / gave an AI disclaimer (replaced): %r",
            text,
        )
        return _PERSONA_BREAK_FALLBACK
    return text

# Wrappers vLLM / Llama emit around a (mis)formatted tool call that the
# ``llama3_json`` parser (scripts/modal_open_weights.py) failed to capture, so
# they land in ``message.content`` verbatim rather than ``message.tool_calls``.
_TOOL_WRAPPER_RE = re.compile(
    r"(<\|?python_tag\|?>|<function\b|</?tool_call>|\[/?TOOL_CALLS?\]|"
    r"^\s*functools\.|^\s*\{\s*\"(?:name|type)\"\s*:)",
    re.IGNORECASE,
)

# A bare identifier that is really a tool name, not prose.
_BARE_IDENT_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
_TOOL_VERB_PREFIX_RE = re.compile(
    r"^(?:open|close|set|go|goto|show|search|run|navigate|take|bring|pull|"
    r"switch|list|send|edit|remove|record|report|analyze|start|advance)",
    re.IGNORECASE,
)


def _declared_tool_names(tool_declarations) -> set[str]:
    """Lower-cased tool names from a list of OpenAI/Gemini-style declarations."""
    out: set[str] = set()
    for d in tool_declarations or []:
        name = d.get("name") if isinstance(d, dict) else None
        if name:
            out.add(str(name).lower())
    return out


def _looks_like_leaked_tool_call(text: str, tool_declarations=None) -> bool:
    """True when ``text`` — an assistant reply that carried NO structured tool
    call — is really a bare / malformed tool name the weak open-weights brain
    (Llama-3.1-8B) emitted as content instead of actually calling the tool, so
    it must be suppressed and never shown (founder bug 2026-11-03:
    "open_model_page" / "openamodelspace" surfaced as the reply).

    Conservative: a genuine prose reply — which has whitespace / punctuation and
    reads as a sentence — is never flagged. Only an obvious tool-call wrapper, an
    exact declared tool name standing alone, a snake_case identifier, or a long
    mashed verb-led token (no spaces, not an English word) trips it."""
    t = (text or "").strip()
    if not t:
        return False
    if _TOOL_WRAPPER_RE.search(t):
        return True
    low = t.lower()
    # An exact declared tool name, even standing alone with no arguments.
    if low in _declared_tool_names(tool_declarations):
        return True
    # From here on, only single-token content can qualify — real prose has
    # whitespace between words.
    if any(c.isspace() for c in t):
        return False
    if not _BARE_IDENT_RE.match(t):
        return False
    # snake_case identifier → unmistakably a tool name (prose is never snake_case).
    if "_" in t:
        return True
    # A long, mashed, verb-led token ("openamodelspace") — not an English word.
    return len(t) >= 12 and bool(_TOOL_VERB_PREFIX_RE.match(low))


class OpenWeightsUnconfiguredError(RuntimeError):
    """A surface is routed to ``open-weights`` but the deployment has not set
    ``OPEN_WEIGHTS_BASE_URL`` and/or ``OPEN_WEIGHTS_API_KEY``. Raised instead
    of falling back: the cheap path must never silently bill a paid route."""


class OpenWeightsProvider(LLMProvider):
    """Muse Spark open weights over an OpenAI-compatible chat endpoint.

    The low-cost route for eligible non-premium calls: same call shapes as
    :class:`MetaProvider` (text, event-streamed chat, structured/JSON output),
    but pointed at ``config.open_weights_api_base_url`` with the
    ``OPEN_WEIGHTS_API_KEY`` environment secret and the
    ``config.meta_open_weights_model`` id — and with NO Gemini fallback. Any
    failure (missing env, transport error, bad response) propagates as an
    explicit error so it can never silently become paid-vendor spend.

    A ``client`` can be injected for tests; otherwise it is built lazily from
    the two ``OPEN_WEIGHTS_*`` environment vars. No Meta-Model-API-only knobs
    (``reasoning_effort``) are sent — a generic OpenAI-compatible endpoint may
    reject unknown fields.
    """

    name = PROVIDER_OPEN_WEIGHTS
    #: Same profile as Meta/Muse Spark: text, JSON, tool-calling; NOT vision,
    #: NOT web — those resolve to Gemini (:func:`get_user_brain_provider`).
    capabilities = BRAIN_CAPABILITIES[PROVIDER_OPEN_WEIGHTS]

    def __init__(self, *, client=None) -> None:
        self._client = client

    def _get_client(self):
        if self._client is not None:
            return self._client
        missing = []
        if not CONFIG.open_weights_api_base_url:
            missing.append("OPEN_WEIGHTS_BASE_URL")
        api_key = os.getenv("OPEN_WEIGHTS_API_KEY", "")
        if not api_key:
            missing.append("OPEN_WEIGHTS_API_KEY")
        if missing:
            raise OpenWeightsUnconfiguredError(
                "open-weights LLM is not configured: set "
                + " and ".join(missing)
                + " on the service before routing a surface to open-weights "
                "(see docs/META_PROVIDER.md). Refusing to fall back to a "
                "paid route."
            )
        try:
            from openai import AsyncOpenAI
        except ModuleNotFoundError as exc:  # pragma: no cover - dep in reqs
            raise RuntimeError(
                "the 'openai' package is required for the open-weights provider"
            ) from exc
        self._client = AsyncOpenAI(
            base_url=CONFIG.open_weights_api_base_url, api_key=api_key
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
        client = self._get_client()
        resp = await client.chat.completions.create(
            model=CONFIG.meta_open_weights_model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": _user_content(contents, media)},
            ],
            temperature=temperature,
            max_tokens=4096,
            response_format=_response_format(response_schema, feature),
        )
        token_ledger.record(
            uid, feature, _MetaResponse(getattr(resp, "usage", None)),
            model=CONFIG.meta_open_weights_model, session_id=session_id or None,
        )
        text = (resp.choices[0].message.content or "").strip()
        if not text:
            raise RuntimeError("Open-weights returned an empty JSON response.")
        return _strip_keys(json.loads(_coerce_json_text(text)))

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
            raise RuntimeError("Open-weights returned an empty response.")
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
        async for ev in self._open_weights_reply_events(
            message, system_prompt, tool_declarations, tool_fns,
            media, uid, feature, session_id,
        ):
            yield ev

    async def _open_weights_reply_events(
        self, message, system_prompt, tool_declarations, tool_fns,
        media, uid, feature, session_id,
    ) -> AsyncIterator[dict]:
        """One open-weights chat turn, mirroring ``gemini.generate_reply_events``:
        status events then a single ``reply``. Runs at most one tool round
        (same as the Gemini/Meta paths). No web grounding on this endpoint —
        that stays Gemini-only."""
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
            model=CONFIG.meta_open_weights_model,
            messages=messages,
            temperature=0.9,
            max_tokens=1024,
            tools=tools,
        )
        token_ledger.record(
            uid, feature, _MetaResponse(getattr(resp, "usage", None)),
            model=CONFIG.meta_open_weights_model, session_id=session_id or None,
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
                model=CONFIG.meta_open_weights_model,
                messages=messages,
                temperature=0.9,
                max_tokens=1024,
                tools=tools,
            )
            token_ledger.record(
                uid, feature, _MetaResponse(getattr(resp, "usage", None)),
                model=CONFIG.meta_open_weights_model, session_id=session_id or None,
            )
            msg = resp.choices[0].message

        text = gemini.strip_inline_refs((msg.content or "").strip())
        # Weak-brain output guard (founder bug 2026-11-03): the 8B open-weights
        # brain both (a) leaks a raw tool name as content instead of calling it
        # and (b) breaks character into a base-assistant disclaimer ("I'm just a
        # language model") / generic refusal. Neither may ever reach the user —
        # replace with an honest in-persona fallback. Common commands are already
        # executed deterministically before the model, so this is the safety net
        # for the long tail the weak brain mangles.
        text = guard_open_weights_text(text, bool(calls), tool_declarations)
        if not text:
            raise RuntimeError("Open-weights returned an empty response.")
        yield {"type": "reply", "text": text, "tools_used": used}


# --- LiveKit Inference brains (Gemma / OpenAI / Kimi / DeepSeek / Grok) ---- #


class LiveKitProvider(LLMProvider):
    """One non-Gemini LiveKit Inference Brain vendor (``LIVEKIT_BRAIN_VENDORS``).

    Every call goes through :func:`inference_llm.complete` — the exact
    transport Gemini uses to reach LiveKit Inference (same gateway, same
    JWT minted from the project ``LIVEKIT_API_KEY`` / ``LIVEKIT_API_SECRET``)
    — so these brains run entirely on the funded LiveKit credits. There is
    NO direct provider API and NO provider key anywhere on this path, and
    deliberately NO Gemini fallback on failure: a user who picked this
    brain gets this brain, so a failed call raises (logged with the model
    id) exactly like the open-weights provider, instead of silently serving
    a different brain than the one selected. Capability gaps are a
    different matter — they are routed by
    :func:`get_user_brain_provider`'s capability map before a call is ever
    made (web always, vision/tools where the flag says so).

    ``complete`` is injectable so tests can serve canned responses without
    the network; production passes ``inference_llm.complete``.
    """

    def __init__(self, vendor: str, *, complete=None) -> None:
        vendor = (vendor or "").strip().lower()
        if vendor not in LIVEKIT_BRAIN_VENDORS:
            raise ValueError(f"not a LiveKit Inference brain vendor: {vendor!r}")
        self.name = vendor
        self.capabilities = BRAIN_CAPABILITIES[vendor]
        self._complete = complete if complete is not None else inference_llm.complete

    @property
    def model(self) -> str:
        """The LiveKit Inference model id for this vendor (config-only)."""
        return livekit_brain_model(self.name)

    def _budget_kwargs(self, budget: int) -> dict:
        """Token-budget kwargs for this vendor's model. The GPT-5 family
        rejects ``max_tokens`` at the gateway (HTTP 400, verified live
        2026-11-07) and requires ``max_completion_tokens`` instead."""
        if self.name in (PROVIDER_OPENAI, PROVIDER_OPENAI_CHAT):
            return {"max_completion_tokens": budget}
        return {"max_tokens": budget}

    @staticmethod
    def _messages(system_prompt: str | None, contents) -> list[dict]:
        messages: list[dict] = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": contents})
        return messages

    def _record(self, response, *, uid, feature, session_id="") -> None:
        """Meter this call through the shared token ledger — the inference
        response already duck-types the Gemini usage shape, exactly like
        ``_MetaResponse`` does for Meta usage."""
        try:
            token_ledger.record(
                uid, feature, response,
                model=self.model, session_id=session_id or None,
                provider=self.name,
            )
        except Exception:  # noqa: BLE001 - metering must never break a call
            logger.debug("token ledger record failed", exc_info=True)

    async def _call(self, *, messages, uid, feature, session_id="", **kwargs):
        """One gateway call; a failure is logged WITH the model id and
        re-raised — never swapped for a different brain."""
        try:
            response = await self._complete(
                model=self.model, messages=messages, **kwargs
            )
        except Exception:
            logger.error(
                "LiveKit brain %s (model %s) call failed — no fallback; "
                "the picked brain must be the one that serves or fails",
                self.name, self.model, exc_info=True,
            )
            raise
        self._record(response, uid=uid, feature=feature, session_id=session_id)
        return response

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
        media = list(images or ([] if image is None else [image]))
        if media and CAP_VISION not in self.capabilities:
            # Vision routing should have sent this to Gemini already; if a
            # caller bypassed it, fail loudly rather than silently dropping
            # the image and hallucinating a read (the Muse Spark rule).
            raise RuntimeError(
                f"brain {self.name} cannot process images; vision calls "
                "must route to Gemini via the capability map"
            )
        content = (
            _user_content(contents, media)
            if media
            else contents
        )
        messages = self._messages(system_prompt, content)
        # Generous budget: at 4096 the gateway truncated schema JSON
        # mid-string in live probing (2026-11-07); at 8192 the same calls
        # completed. Matches the Gemini chat budget scale.
        budget = self._budget_kwargs(8192)
        last_error: Exception | None = None
        for attempt in (1, 2):
            response = await self._call(
                messages=messages,
                uid=uid, feature=feature, session_id=session_id,
                response_schema=response_schema,
                temperature=temperature,
                **budget,
            )
            text = (getattr(response, "text", None) or "").strip()
            if not text:
                raise RuntimeError(
                    f"LiveKit brain {self.name} (model {self.model}) "
                    "returned an empty response."
                )
            try:
                return _strip_keys(json.loads(_coerce_json_text(text)))
            except json.JSONDecodeError as exc:
                # Grok in particular intermittently returns truncated or
                # garbled JSON through the gateway (finish_reason=stop with
                # a cut document, observed repeatedly 2026-11-07). ONE
                # retry of the same call on the same brain — never a swap
                # to a different brain.
                last_error = exc
                logger.warning(
                    "LiveKit brain %s (model %s) returned unparseable JSON "
                    "(attempt %d/2): %s",
                    self.name, self.model, attempt, exc,
                )
        assert last_error is not None
        raise last_error

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
        events = self.generate_reply_events(
            message,
            system_prompt,
            tool_declarations,
            tool_fns,
            image=image,
            uid=uid,
            feature=feature,
            session_id=session_id,
        )
        try:
            async for event in events:
                if event.get("type") == "reply":
                    return Reply(
                        text=event["text"],
                        tools_used=event.get("tools_used") or [],
                    )
            return Reply(text="(no reply)", tools_used=[])
        finally:
            await events.aclose()

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
        media = [] if image is None else [image]
        if media and CAP_VISION not in self.capabilities:
            raise RuntimeError(
                f"brain {self.name} cannot process images; vision calls "
                "must route to Gemini via the capability map"
            )
        declarations = tool_declarations or []
        may_call = (
            bool(declarations) and bool(tool_fns)
            and CAP_TOOLS in self.capabilities
        )
        content = _user_content(message, media) if media else message
        tools = (
            inference_llm.to_openai_tools(declarations) if may_call else None
        )
        budget = CONFIG.inference_chat_max_tokens
        messages = self._messages(system_prompt, content)

        from tool_labels import tool_label as _tool_label
        from tool_labels import working_label as _working_label

        used: list[str] = []
        seen: set[str] = set()

        def _note(label: str) -> None:
            if label not in seen:
                seen.add(label)
                used.append(label)

        yield {"type": "status", "label": "Thinking…"}
        response = await self._call(
            messages=messages, uid=uid, feature=feature,
            session_id=session_id,
            tools=tools, temperature=0.9,
            **self._budget_kwargs(budget),
        )
        text = (getattr(response, "text", None) or "").strip()
        calls = list(getattr(response, "function_calls", None) or [])

        finish = str(getattr(response, "finish_reason", None) or "").lower()
        if finish in ("length", "max_tokens", "max_completion_tokens"):
            # Truncated: one larger-budget retry, mirroring Gemini's path.
            logger.warning(
                "LiveKit brain %s (model %s) reply truncated "
                "(finish_reason=%s) — retrying once with double budget",
                self.name, self.model, finish,
            )
            response = await self._call(
                messages=messages, uid=uid, feature=feature,
                session_id=session_id,
                tools=tools, temperature=0.9,
                **self._budget_kwargs(budget * 2),
            )
            text = (getattr(response, "text", None) or "").strip()
            calls = list(getattr(response, "function_calls", None) or [])

        if calls and tool_fns:
            # One function-calling round, mirroring the Meta path in this
            # module: execute locally, feed results back, collect the
            # model's follow-up text.
            import inspect

            tool_calls = []
            for idx, call in enumerate(calls):
                args = call.get("args") or {}
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except (TypeError, ValueError):
                        args = {}
                call["args"] = args
                tool_calls.append({
                    "id": str(call.get("id") or f"call_{idx}"),
                    "type": "function",
                    "function": {
                        "name": call.get("name") or "",
                        "arguments": json.dumps(args),
                    },
                })
            messages = list(messages) + [{
                "role": "assistant",
                "content": text or None,
                "tool_calls": tool_calls,
            }]
            for call, tc in zip(calls, tool_calls):
                name = call.get("name") or ""
                _note(_tool_label(name))
                yield {"type": "status", "label": _working_label(name)}
                fn = tool_fns.get(name)
                try:
                    result = fn(**(call.get("args") or {})) if fn else "unknown tool"
                    if inspect.isawaitable(result):
                        result = await result
                except Exception as tool_exc:  # noqa: BLE001 - report, don't crash
                    result = f"error: {tool_exc}"
                messages.append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "content": str(result),
                })
            yield {"type": "status", "label": "Writing…"}
            follow_resp = await self._call(
                messages=messages, uid=uid, feature=feature,
                session_id=session_id,
                temperature=0.9, **self._budget_kwargs(budget),
            )
            follow_text = (getattr(follow_resp, "text", None) or "").strip()
            if follow_text:
                text = follow_text

        text = gemini.strip_inline_refs(text)
        if not text:
            raise RuntimeError(
                f"LiveKit brain {self.name} (model {self.model}) returned "
                "an empty response."
            )
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
    Gemini fallback when ``config.llm_meta_fallback`` is on; ``open-weights``
    returns an :class:`OpenWeightsProvider`, which deliberately carries NO
    fallback (an unconfigured or failing cheap path raises instead of silently
    billing a paid route); a LiveKit Inference vendor (``gemma`` /
    ``openai`` / ``openai-chat`` / ``openai-oss`` / ``kimi`` / ``deepseek``
    / ``grok``) returns a :class:`LiveKitProvider`, also with NO fallback;
    anything else (including an unknown value, logged once) returns the
    Gemini default so a typo can never route traffic nowhere.
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
    if choice == PROVIDER_OPEN_WEIGHTS:
        return OpenWeightsProvider()
    if choice in LIVEKIT_BRAIN_VENDORS:
        return LiveKitProvider(choice)
    if choice != PROVIDER_GEMINI:
        logger.warning(
            "LLM_PROVIDER for %s is %r (not gemini|meta|open-weights|a "
            "LiveKit brain vendor) — using gemini",
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
    """A provider instance for a vendor name (``gemini`` | ``meta`` |
    ``open-weights`` | a LiveKit Inference vendor). ``meta`` carries the
    Gemini fallback when ``llm_meta_fallback`` is on; ``open-weights`` and
    the LiveKit vendors carry none (their failures stay explicit); anything
    else is the Gemini default."""
    normalized = (name or "").strip().lower()
    if normalized == PROVIDER_META:
        fallback = _gemini_singleton() if CONFIG.llm_meta_fallback else None
        return MetaProvider(fallback=fallback)
    if normalized == PROVIDER_OPEN_WEIGHTS:
        return OpenWeightsProvider()
    if normalized in LIVEKIT_BRAIN_VENDORS:
        return LiveKitProvider(normalized)
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
      is unchanged until a user actually chooses a brain. A saved brain this
      deploy is not credited for (:func:`brain_is_credited` — e.g. Meta on
      staging) resolves to Gemini instead: never the uncredited vendor,
      never an error.
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
    if chosen in BRAIN_CAPABILITIES and brain_is_credited(chosen):
        provider = _provider_for_name(chosen)
    elif chosen in BRAIN_CAPABILITIES:
        # A saved brain this deploy is NOT credited for (e.g. ``meta`` on
        # staging, where only LiveKit-credit inference may run): serve
        # Gemini — never the uncredited vendor, never an error.
        logger.info(
            "saved brain %s is not credited on this deploy — using Gemini",
            chosen,
        )
        provider = _gemini_singleton()
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
