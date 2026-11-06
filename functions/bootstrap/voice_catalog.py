"""The selectable voice stack for the MAIN Ayma voice call (ARCHITECTURE §13.9;
``docs/META_PROVIDER.md``).

Two **modes**, chosen per user in developer settings:

* **REALTIME** — one all-in-one native-audio speech-to-speech model handles audio
  in *and* out. Options: **Gemini Live** (the LOCKED ``CONFIG.gemini_live_model``,
  always available, no key) and **OpenAI Realtime** (``CONFIG.openai_realtime_model``
  via ``livekit-plugins-openai``, exposed only behind ``voice_openai_realtime_enabled``
  and inert until an ``OPENAI_API_KEY`` secret exists). Meta serves no working
  realtime audio API, so it is **not** a realtime option. The voice list comes
  from the chosen realtime model.
* **CASCADE** — three independently selectable components, mixable in any
  combination: **BRAIN** (LLM), **STT**, **TTS**. The voice list comes from the
  chosen TTS.

Sourcing. The cascade's model lists come from the config FALLBACK lists
(``CONFIG.voice_cascade_*_models``, ``source="fallback"``) — the permanent
catalog source until LiveKit ships a real catalog API. Those lists enumerate
the providers the project has LiveKit startup credits for, with canonical
model ids from the LiveKit docs (docs.livekit.io/agents/models). Availability
is marked TRUTHFULLY (:func:`_availability`): a provider in
``CONFIG.voice_credited_providers`` is enabled; any other is shown disabled
with a "needs LiveKit credits" note rather than a silently-failing pick.
``cartesia`` is the exception: it rides its own grant-funded plugin, so it is
an ENABLEMENT gate, not an availability marking —
:func:`cartesia_enabled` (``CARTESIA_API_KEY`` wired) decides whether its ids
appear in the served lists at all, and while the key is missing they are
absent entirely (founder ruling 2026-11-05), never shown disabled. Merged in
on top: the direct Meta Muse brain (not a LiveKit model — via the Meta API)
and the two realtime models (Gemini Live, the LOCKED model; OpenAI Realtime,
flag-gated).

**There is no live catalog to fetch (root cause verified 2026-11-06).**
``GET /v1/models`` on the inference gateway (``agent-gateway.livekit.cloud``)
is a STUB route: it returns ``{}`` to every caller — staging key, prod key,
and no auth at all. With the same InferenceGrants JWT, ``POST
/v1/chat/completions`` returned a real completion carrying the project's
Scale quotas (RPM 1000 / TPM 6,000,000, cost $0.0), so the project is fully
provisioned on the gateway; the route simply is not a catalog API. In
livekit-agents 1.8.9 (our pin) that ``/models`` call exists only as the
inference LLM's prewarm ping and its result is discarded — it never returns
data for anyone. (This supersedes the 2026-10-27 "simply not populated for
our plan" reading.) The old live-fetch path was therefore deleted: it could
only ever return ``None`` and cost an HTTP round-trip per cache expiry.

Per-TTS *voice* lists are a separate concern — ``/v1/models`` lists models, not
each model's voices — so they come from :func:`_livekit_tts_voices` (the live
extension point, empty today) else the **documented** fallback in
:data:`_TTS_FALLBACK_VOICES` (the LiveKit docs' per-provider sample voices;
overridable by ``VOICE_TTS_VOICES_<PROVIDER>``).

Model ids all live in ``config.py`` per ``AGENTS.md``; this
module holds only voice *ids*/labels and catalog metadata (routes, availability).
"""

from __future__ import annotations

import logging
import os
import re
import time
from dataclasses import dataclass

import voices
from config import CONFIG
from llm_provider import PROVIDER_GEMINI, PROVIDER_META, PROVIDER_OPEN_WEIGHTS

logger = logging.getLogger("ayma.voice_catalog")

MODE_REALTIME = "realtime"
MODE_CASCADE = "cascade"
MODES = (MODE_REALTIME, MODE_CASCADE)

# Stable realtime-model + Meta-brain ids persisted on the profile — never
# renamed. Inference brains/STT/TTS use the LiveKit model string as their id.
REALTIME_GEMINI = "gemini-live"
REALTIME_OPENAI = "openai-realtime"
BRAIN_META = "meta-muse-spark"
# Self-hosted open-weights voice brain (§13.9). Offered only when
# ``CONFIG.open_weights_api_base_url`` (env ``OPEN_WEIGHTS_BASE_URL``) is set;
# never a production default. Stable id persisted on the profile — never renamed.
BRAIN_OPEN_WEIGHTS = "open-weights-llama-3.1-8b"

# Cascade brain ROUTES (how the agent builds the LLM leg).
ROUTE_META = "meta"
ROUTE_INFERENCE = "inference"
# OpenAI-compatible self-hosted endpoint (NOT LiveKit Inference): the agent
# builds the LLM leg with ``livekit-plugins-openai`` pointed at
# ``CONFIG.open_weights_api_base_url``.
ROUTE_OPEN_WEIGHTS = "open-weights"

_CATALOG_TTL_SECONDS = 300


@dataclass(frozen=True)
class Voice:
    id: str
    label: str
    description: str = ""
    gender: str = ""

    def to_dict(self) -> dict[str, str]:
        d = {"id": self.id, "label": self.label, "description": self.description}
        if self.gender:
            d["gender"] = self.gender
        return d


# --- Accent / language list (shared across every component) -----------------
def _languages() -> list[dict[str, str]]:
    out: list[dict[str, str]] = [{"code": "", "label": "Default (English)"}]
    seen: set[str] = set()
    for keyword, code in voices._LANG_HINTS:  # noqa: SLF001 - sibling module
        if code in seen:
            continue
        seen.add(code)
        out.append({"code": code, "label": keyword.title()})
    return out


def _gender_of(description: str) -> str:
    m = re.search(r"leans (\w+)", description)
    return m.group(1) if m else ""


def _gemini_voices() -> list[Voice]:
    return [
        Voice(id=name, label=name, description=desc, gender=_gender_of(desc))
        for name, desc in voices.VOICE_PRESETS.items()
    ]


# OpenAI Realtime voices (not model ids — like the Gemini preset names). The
# published speech-to-speech voices; a wrong one only costs a mid-call fallback.
_OPENAI_REALTIME_VOICES = [
    Voice(id="", label="Default (alloy)", description="the model default voice"),
    Voice(id="alloy", label="Alloy", description="neutral, even"),
    Voice(id="ash", label="Ash", description="warm, grounded"),
    Voice(id="ballad", label="Ballad", description="expressive, lyrical"),
    Voice(id="coral", label="Coral", description="bright, friendly", gender="feminine"),
    Voice(id="echo", label="Echo", description="calm, clear", gender="masculine"),
    Voice(id="sage", label="Sage", description="measured, soft"),
    Voice(id="shimmer", label="Shimmer", description="light, airy", gender="feminine"),
    Voice(id="verse", label="Verse", description="energetic, varied"),
]


# --- Cascade TTS voices: DOCUMENTED FALLBACK (no LiveKit catalog API) --------
#
# Keyed by the provider segment of the TTS model id ("inworld/inworld-tts-1" ->
# "inworld"). The empty-id "" voice always means "the vendor's default voice"
# and is always safe. Override with ``VOICE_TTS_VOICES_<PROVIDER>`` (CSV of
# ``id`` or ``id|Label|gender``). A wrong id only triggers a mid-call fallback
# to Gemini Live.
#
# The non-default voice ids below are the DOCUMENTED LiveKit Inference sample
# voices for each provider, lifted verbatim from docs.livekit.io/agents/models/
# tts/<provider> (verified 2026-10-27) — not invented. At runtime the agent
# builds the full descriptor ``<model>:<voice-id>`` (e.g.
# ``fishaudio/s2.1-pro:bf322df2096a46f18c579d0baa36f41d``).
_TTS_FALLBACK_VOICES: dict[str, list[Voice]] = {
    "inworld": [
        Voice(id="", label="Default (Ashley)", description="the vendor default voice"),
        Voice(id="Ashley", label="Ashley", description="warm, bright", gender="feminine"),
        Voice(id="Olivia", label="Olivia", description="calm, even", gender="feminine"),
        Voice(id="Elizabeth", label="Elizabeth", description="clear, measured", gender="feminine"),
        Voice(id="Sarah", label="Sarah", description="youthful, upbeat", gender="feminine"),
        Voice(id="Alex", label="Alex", description="friendly, mid-range", gender="masculine"),
        Voice(id="Mark", label="Mark", description="steady, grounded", gender="masculine"),
        Voice(id="Hades", label="Hades", description="deep, intense", gender="masculine"),
        Voice(id="Edward", label="Edward", description="crisp, confident", gender="masculine"),
    ],
    # Fish Audio s2.1-pro sample voices (docs .../tts/fishaudio).
    "fishaudio": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
        Voice(id="bf322df2096a46f18c579d0baa36f41d", label="Adrian",
              description="friendly, casual American", gender="masculine"),
        Voice(id="536d3a5e000945adb7038665781a4aca", label="Ethan",
              description="a curious explainer", gender="masculine"),
        Voice(id="9a9cf47702da476aa4629e2506d4a857", label="Hannah",
              description="a conversational specialist", gender="feminine"),
        Voice(id="79d0bd3e4e5444b18f7b6d89b5927bf1", label="Jordan",
              description="a motivational speaker", gender="masculine"),
        Voice(id="e3cd384158934cc9a01029cd7d278634", label="Laura",
              description="a confident female narrator", gender="feminine"),
        Voice(id="933563129e564b19a115bedd57b7406a", label="Sarah",
              description="an engaged speaker", gender="feminine"),
        Voice(id="b347db033a6549378b48d00acb0d06cd", label="Selene",
              description="a meditative female voice", gender="feminine"),
    ],
    # Rime sample voices (docs .../tts/inference/rime; names shared across
    # rime/coda and rime/mistv3).
    "rime": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
        Voice(id="astra", label="Astra",
              description="chipper, upbeat American", gender="feminine"),
        Voice(id="celeste", label="Celeste",
              description="chill Gen-Z American", gender="feminine"),
        Voice(id="luna", label="Luna",
              description="chill but excitable American", gender="feminine"),
    ],
    # Gradium sample voices (docs .../tts/gradium; en-US flagships).
    "gradium": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
        Voice(id="4SZHfMpw-p46Ywgs", label="Harper",
              description="en-US", gender="feminine"),
        Voice(id="6MFfc37kq0sBjBjy", label="Sterling",
              description="en-US", gender="masculine"),
    ],
    # Cartesia Sonic voice-library UUIDs (docs.cartesia.ai sample voices for
    # Sonic 3.x + the livekit-plugins-cartesia default, verified 2026-11-04):
    # valid for the plugin route (agent.py builds cartesia.TTS with the pinned
    # flagship model). Locales are per-voice (there is no free-text accent
    # instruction — cartesia stays out of voice_accent_capable_providers).
    "cartesia": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
        Voice(id="f786b574-daa5-4673-aa0c-cbe3e8534c02", label="Katie",
              description="the plugin default voice"),
        Voice(id="db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", label="Skylar",
              description="en-US", gender="feminine"),
        Voice(id="47c38ca4-5f35-497b-b1a3-415245fb35e1", label="Daniel",
              description="en-US", gender="masculine"),
        Voice(id="9626c31c-bec5-4cca-baa8-f8ba9e84c8bc", label="Jacqueline",
              description="en-US", gender="feminine"),
        Voice(id="62ae83ad-4f6a-430b-af41-a9bede9286ca", label="Gemma",
              description="en-GB", gender="feminine"),
        Voice(id="ef191366-f52f-447a-a398-ed8c0f2943a1", label="Archie",
              description="en-GB", gender="masculine"),
    ],
    "elevenlabs": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
    ],
}


def _provider_of(model: str) -> str:
    """``"inworld/inworld-tts-1"`` -> ``"inworld"``; bare model -> ``""``."""
    return model.split("/", 1)[0] if "/" in model else ""


def cartesia_enabled() -> bool:
    """Whether Cartesia may appear in any served selection list.

    Cartesia STT/TTS ride the grant-funded ``livekit-plugins-cartesia`` legs,
    which only exist when ``CARTESIA_API_KEY`` is wired — so the KEY is the
    enablement signal, not the credited-providers list (staging credits the
    provider via ``VOICE_CREDITED_PROVIDERS`` but has no key yet). Founder
    ruling 2026-11-05: while Cartesia is inactive it must not appear at all —
    not shown-disabled, absent — in voice/TTS/STT/model lists and the models
    page. :func:`_sources` enforces this for the served catalog (every surface
    inherits it); ``set_model_stack._credited_providers`` enforces it for the
    voice skills' option fills. Selecting cartesia while uncredited still
    errors honestly (defense in depth)."""
    return bool(os.getenv("CARTESIA_API_KEY", "").strip())


def _is_cartesia_model(model_id: str) -> bool:
    mid = (model_id or "").strip()
    return _provider_of(mid) == "cartesia" or mid == "cartesia"


def _env_voices(provider: str) -> list[Voice] | None:
    raw = os.getenv(f"VOICE_TTS_VOICES_{provider.upper()}", "").strip()
    if not raw:
        return None
    out: list[Voice] = []
    for item in raw.split(","):
        parts = [p.strip() for p in item.split("|")]
        vid = parts[0]
        label = parts[1] if len(parts) > 1 and parts[1] else (vid or "Default voice")
        gender = parts[2] if len(parts) > 2 else ""
        out.append(Voice(id=vid, label=label, gender=gender))
    return out or None


def _livekit_tts_voices(provider: str) -> list[Voice] | None:
    """Extension point for a LIVE LiveKit Inference voice catalog. LiveKit
    exposes none today (module docstring), so this returns ``None`` and the
    documented fallback is used. Wire + cache a live pull here when it ships —
    the ``/voice/engines`` contract is unchanged."""
    return None


def _tts_voices(model: str) -> list[Voice]:
    provider = _provider_of(model)
    for source in (_livekit_tts_voices(provider), _env_voices(provider)):
        if source is not None:
            return source
    return _TTS_FALLBACK_VOICES.get(
        provider, [Voice(id="", label="Default voice", description="the vendor default voice")]
    )


# --- Catalog sources (config fallback — the permanent source) --------------
#
# There is no live catalog fetch: ``GET /v1/models`` on the inference
# gateway is a stub returning ``{}`` to every caller (root cause verified
# 2026-11-06 — see the module docstring), so the config fallback lists are
# the catalog. If LiveKit ever ships a real catalog API, feed its ids in
# here as the ``_raw_sources`` buckets.


def _with_configured(ids: list[str], configured: str) -> list[str]:
    """``ids`` with the model a call actually uses guaranteed present (first if
    it was missing), so the picker can always show the real default selected."""
    if configured and configured not in ids:
        return [configured, *ids]
    return ids


def _sources() -> dict[str, object]:
    """Resolved component model ids by category: the config fallback lists
    (the permanent catalog source — see the module docstring). Shared by the
    catalog + validators. The configured Meta-cascade STT/TTS are always
    included. Cartesia ids are withheld from every bucket while Cartesia is
    inactive (:func:`cartesia_enabled`) — the one gate every served list
    inherits."""
    src = _raw_sources()
    src["stt"] = _with_configured(src["stt"], CONFIG.meta_cascade_stt_model)  # type: ignore[arg-type]
    src["tts"] = _with_configured(src["tts"], CONFIG.meta_cascade_tts_model)  # type: ignore[arg-type]
    if not cartesia_enabled():
        for key in ("llm", "stt", "tts", "realtime"):
            src[key] = [m for m in src[key] if not _is_cartesia_model(m)]  # type: ignore[union-attr]
    return src


def _raw_sources() -> dict[str, object]:
    return {
        "source": "fallback",
        "llm": list(CONFIG.voice_cascade_llm_models),
        "stt": list(CONFIG.voice_cascade_stt_models),
        "tts": list(CONFIG.voice_cascade_tts_models),
        "realtime": [],
    }


def _availability(provider: str) -> tuple[bool, str]:
    """``(available, requires)`` for a cascade option, marked TRUTHFULLY.

    The catalog is built from the config fallback lists (there is no live
    catalog to query — ``GET /v1/models`` is a stub; see the module
    docstring), so we trust only the providers known to carry LiveKit
    Inference credits (``CONFIG.voice_credited_providers``). Any other
    option is returned ``available=False`` with a short note, so the UI
    shows it disabled ("needs LiveKit credits") instead of offering a pick
    that would silently fail mid-call. A bare id with no provider segment
    is left available (nothing to check it against). Cartesia never
    reaches this marked-disabled: while its key is missing its ids are
    withheld upstream in :func:`_sources` (see :func:`cartesia_enabled`)."""
    if not provider or provider in CONFIG.voice_credited_providers:
        return True, ""
    return False, "LiveKit credits"


def provider_supports_accent(provider: str) -> bool:
    """Whether ``provider`` honours a free-text ACCENT instruction
    (``ayma_voice_accent``) at session boot — the ONE source of truth for the
    per-provider capability (§13.9). The instruction-driven native-audio realtime
    models (``gemini``, ``openai``) take the accent in their style/instruction
    text; cascade TTS providers here ship only fixed voices and ignore it. Driven
    by ``CONFIG.voice_accent_capable_providers`` so a style-controllable TTS can
    be marked capable with no code change. Accent routing in ``agent.py`` and the
    "switch models to change accent" message in ``set_voice_preference`` both read
    this, so they can never disagree."""
    return (provider or "").strip().lower() in CONFIG.voice_accent_capable_providers


# --- Catalog assembly -------------------------------------------------------
def _realtime_voices_for(model_id: str) -> list[Voice]:
    provider = _provider_of(model_id) or model_id
    if provider.startswith("google") or model_id == REALTIME_GEMINI:
        return _gemini_voices()
    if provider.startswith("openai") or model_id == REALTIME_OPENAI:
        return _OPENAI_REALTIME_VOICES
    return [Voice(id="", label="Default voice", description="the model default voice")]


def _realtime_models(sources: dict[str, object]) -> list[dict[str, object]]:
    langs = _languages()
    models: list[dict[str, object]] = [
        {
            "id": REALTIME_GEMINI,
            "label": "Gemini Live (native audio)",
            "provider": PROVIDER_GEMINI,
            "available": True,
            "requires_secret": "",
            "supports_accent": provider_supports_accent(PROVIDER_GEMINI),
            "voices": [v.to_dict() for v in _gemini_voices()],
            "languages": langs,
        }
    ]
    # OpenAI Realtime: present only behind the flag; inert until the agent has
    # OPENAI_API_KEY (the agent falls back to Gemini Live otherwise). Meta is
    # NEVER here — it serves no realtime audio API, only the cascade brain.
    if CONFIG.voice_openai_realtime_enabled:
        models.append(
            {
                "id": REALTIME_OPENAI,
                "label": "OpenAI Realtime",
                "provider": "openai",
                "available": True,
                "requires_secret": "OPENAI_API_KEY",
                "supports_accent": provider_supports_accent("openai"),
                "voices": [v.to_dict() for v in _OPENAI_REALTIME_VOICES],
                "languages": langs,
            }
        )
    # Any other realtime-type model a future real catalog API exposes
    # (google/openai realtime are already represented by the two canonical
    # options above). The fallback source carries none, so this is empty today.
    for mid in sources.get("realtime", []):  # type: ignore[union-attr]
        prov = _provider_of(mid)
        if prov in ("google", "openai"):
            continue
        models.append(
            {
                "id": mid,
                "label": mid,
                "provider": prov,
                "available": True,
                "requires_secret": "",
                "supports_accent": provider_supports_accent(prov),
                "voices": [v.to_dict() for v in _realtime_voices_for(mid)],
                "languages": langs,
            }
        )
    return models


def brain_route(brain_id: str) -> tuple[str, str] | None:
    """``(route, model_id)`` for a cascade brain id, or ``None`` if unknown.
    The Meta brain is ``meta`` → ``CONFIG.meta_chat_model``; the open-weights
    brain is ``open-weights`` → ``CONFIG.open_weights_model`` (offered only when
    ``OPEN_WEIGHTS_BASE_URL`` is set); every other brain id is itself a LiveKit
    Inference LLM model string (route ``inference``)."""
    if brain_id == BRAIN_META:
        return ROUTE_META, CONFIG.meta_chat_model
    if brain_id == BRAIN_OPEN_WEIGHTS and CONFIG.open_weights_api_base_url:
        return ROUTE_OPEN_WEIGHTS, CONFIG.open_weights_model
    # An extra brain may map its id to a distinct model string.
    for entry in CONFIG.voice_cascade_extra_brains:
        parts = [p.strip() for p in entry.split("|")]
        if len(parts) >= 3 and parts[0] == brain_id:
            return parts[1], parts[2]
    # Every other catalog brain is a LiveKit Inference LLM whose id IS its model.
    for b in catalog()["brains"]:  # type: ignore[index]
        if b["id"] == brain_id and b["route"] == ROUTE_INFERENCE:
            return ROUTE_INFERENCE, brain_id
    return None


def _brains(sources: dict[str, object]) -> list[dict[str, object]]:
    # Meta Muse Spark is a direct-API brain; the rest are LiveKit Inference
    # LLMs from the config fallback lists.
    out: list[dict[str, object]] = [
        {
            "id": BRAIN_META,
            "label": "Meta Muse Spark",
            "provider": "meta",
            "route": ROUTE_META,
            "available": True,
            "requires_secret": "META_API_KEY",
        }
    ]
    # Self-hosted open-weights brain: exposed ONLY when the endpoint is
    # configured (``OPEN_WEIGHTS_BASE_URL`` set), so production (env unset)
    # never lists it. Never a default (see ``_default_from``).
    if CONFIG.open_weights_api_base_url:
        out.append(
            {
                "id": BRAIN_OPEN_WEIGHTS,
                "label": "Llama 3.1 8B (open weights)",
                "provider": PROVIDER_OPEN_WEIGHTS,
                "route": ROUTE_OPEN_WEIGHTS,
                "available": True,
                "requires_secret": "",
            }
        )
    for mid in sources["llm"]:  # type: ignore[index]
        provider = _provider_of(mid)
        available, requires = _availability(provider)
        out.append(
            {
                "id": mid,
                "label": mid,
                "provider": provider,
                "route": ROUTE_INFERENCE,
                "available": available,
                "requires_secret": requires,
            }
        )
    for entry in CONFIG.voice_cascade_extra_brains:
        parts = [p.strip() for p in entry.split("|")]
        if len(parts) >= 3 and parts[0]:
            out.append(
                {"id": parts[0], "label": parts[0], "provider": parts[1],
                 "route": parts[1], "available": True, "requires_secret": ""}
            )
    return out


def _stt(sources: dict[str, object]) -> list[dict[str, object]]:
    out: list[dict[str, object]] = []
    for m in sources["stt"]:  # type: ignore[index]
        provider = _provider_of(m)
        available, requires = _availability(provider)
        out.append({
            "id": m, "label": m, "provider": provider,
            "available": available, "requires_secret": requires,
        })
    return out


def _tts(sources: dict[str, object]) -> list[dict[str, object]]:
    langs = _languages()
    out: list[dict[str, object]] = []
    for m in sources["tts"]:  # type: ignore[index]
        provider = _provider_of(m)
        available, requires = _availability(provider)
        out.append({
            "id": m,
            "label": m,
            "provider": provider,
            "available": available,
            "requires_secret": requires,
            "supports_accent": provider_supports_accent(provider),
            "voices": [v.to_dict() for v in _tts_voices(m)],
            "languages": langs,
        })
    return out


def _build_catalog() -> dict[str, object]:
    sources = _sources()
    return {
        "modes": list(MODES),
        "source": sources["source"],
        "realtime_models": _realtime_models(sources),
        "brains": _brains(sources),
        "stt": _stt(sources),
        "tts": _tts(sources),
        "default": _default_from(sources),
    }


_cache: dict[str, object] = {}


def catalog() -> dict[str, object]:
    """The assembled catalog, cached for :data:`_CATALOG_TTL_SECONDS` (so the
    fallback assembly happens at most once per TTL, never per request)."""
    now = time.monotonic()
    built = _cache.get("catalog")
    at = float(_cache.get("at", 0.0))  # type: ignore[arg-type]
    if built is None or (now - at) > _CATALOG_TTL_SECONDS:
        built = _build_catalog()
        _cache["catalog"] = built
        _cache["at"] = now
    return built  # type: ignore[return-value]


def clear_cache() -> None:
    _cache.clear()


def default_selection() -> dict[str, str]:
    """The stack a user with no saved preference gets — matched to the
    deploy-time ``CONFIG.llm_provider_voice_main`` so behaviour is unchanged."""
    return catalog()["default"]  # type: ignore[return-value]


def _default_from(sources: dict[str, object]) -> dict[str, str]:
    if CONFIG.llm_provider_voice_main == PROVIDER_META:
        # Exactly what agent.py uses at call time for a user with no saved pick:
        # the Meta cascade with the configured TTS voice (``voice_id``), so the
        # "Ayma's models" screen shows the real default voice (Hannah) selected.
        return {
            "mode": MODE_CASCADE, "realtime_model_id": "",
            "brain_id": BRAIN_META,
            "stt_id": CONFIG.meta_cascade_stt_model,
            "tts_id": CONFIG.meta_cascade_tts_model,
            "voice_id": CONFIG.meta_cascade_tts_voice,
        }
    stt = _first(sources["stt"])  # type: ignore[index]
    tts = _first(sources["tts"])  # type: ignore[index]
    return {
        "mode": MODE_REALTIME, "realtime_model_id": REALTIME_GEMINI,
        "brain_id": BRAIN_META, "stt_id": stt, "tts_id": tts,
        "voice_id": "",
    }


def _first(seq) -> str:
    return seq[0] if seq else ""


# --- Validation helpers (used by the endpoint + the agent) ------------------
def is_valid_realtime_model(model_id: str) -> bool:
    return any(m["id"] == model_id for m in catalog()["realtime_models"])  # type: ignore[index]


def is_valid_brain(brain_id: str) -> bool:
    return any(b["id"] == brain_id for b in catalog()["brains"])  # type: ignore[index]


def is_valid_stt(stt_id: str) -> bool:
    return any(s["id"] == stt_id for s in catalog()["stt"])  # type: ignore[index]


def is_valid_tts(tts_id: str) -> bool:
    return any(t["id"] == tts_id for t in catalog()["tts"])  # type: ignore[index]


def realtime_voice_ids(model_id: str) -> set[str]:
    for m in catalog()["realtime_models"]:  # type: ignore[index]
        if m["id"] == model_id:
            return {v["id"] for v in m["voices"]}
    return set()


def tts_voice_ids(tts_id: str) -> set[str]:
    return {v.id for v in _tts_voices(tts_id)}


def safe_tts_voice(tts_id: str, voice: str | None) -> str:
    """The voice id to actually hand ``inference.TTS`` for ``tts_id`` — guaranteed
    valid for that TTS provider: ``voice`` when it is one of the provider's known
    voice ids (:func:`tts_voice_ids`), else ``""`` (the vendor default, which is
    always safe).

    This is the single guard against a CROSS-PROVIDER voice id reaching the
    gateway. The configured cascade default voice (``CONFIG.meta_cascade_tts_voice``
    = a Fish Audio id) is carried onto whatever TTS model is active; when a
    deploy overrides only the TTS *model* to another provider (e.g. ``inworld/
    inworld-tts-1`` on staging) the Fish Audio id is unknown there and the gateway
    raises ``APIError: ... Unknown voice ... not found`` → no audio → the call goes
    silent (founder bug, staging 2026-11-03). Dropping an unknown id to the
    vendor default makes the provider speak in its own default voice instead of
    erroring into dead air. An empty/whitespace ``voice`` already means the vendor
    default, so it is returned unchanged."""
    v = (voice or "").strip()
    if not v:
        return ""
    return v if v in tts_voice_ids(tts_id) else ""


def is_valid_language(code: str) -> bool:
    if not code:
        return True
    return any(lang["code"] == code for lang in _languages())


def language_label(code: str) -> str:
    """Human label for a catalog language code ("ml-IN" -> "Malayalam"), stored
    into ``ayma_voice_language`` so the agent prompt reads naturally and
    ``voices.bcp47_hint`` still resolves it."""
    if not code:
        return ""
    for lang in _languages():
        if lang["code"] == code and lang["code"]:
            return lang["label"]
    return code


# --- Stack-aware runtime voice vocabulary (§13.9) ---------------------------
#
# The voice agent (``agent.py``) must know the voices of the stack it is
# ACTUALLY running, not the Gemini Live presets: on a cascade with a non-Gemini
# TTS (e.g. ``fishaudio/s2.1-pro``) "what voices do you have" must list that
# provider's voices and its real current voice, and ``set_voice_preference``
# must switch only within that set. These helpers read from the one source of
# truth above (``_tts_voices`` / ``_realtime_voices_for``) — no duplicated ids.


@dataclass(frozen=True)
class RuntimeVoices:
    """The voice vocabulary of a running voice session.

    ``provider`` is the active provider key (``gemini`` / ``openai`` / a cascade
    TTS provider segment like ``fishaudio``); ``voices`` are its selectable
    voices; ``current`` is the voice the session is running (``None`` only when
    the set is empty); ``hot_swap`` is True only on Gemini Live realtime, the one
    stack that can change voice mid-call; ``supports_accent`` is True only when
    the active provider honours a free-text ACCENT instruction
    (``provider_supports_accent``) — the agent routes ``ayma_voice_accent`` to
    this session only then, and ``set_voice_preference`` reads it to tell the user
    when this model cannot change accent (§13.9)."""

    provider: str
    voices: tuple[Voice, ...]
    current: Voice | None
    hot_swap: bool
    supports_accent: bool


def _match_current(voice_list: list[Voice], voice_id: str) -> Voice | None:
    vid = (voice_id or "").strip()
    for v in voice_list:
        if v.id == vid:
            return v
    if not vid:
        for v in voice_list:
            if v.id == "":
                return v
        return None
    # A configured/override id not in the documented list — still the real
    # current voice, so report it by id rather than claiming a different one.
    return Voice(id=vid, label=vid)


def runtime_voices(
    *,
    mode: str,
    realtime_model_id: str = "",
    tts_id: str = "",
    current_voice_id: str = "",
) -> RuntimeVoices:
    """The :class:`RuntimeVoices` for the stack a voice session is running.

    ``mode`` ``cascade`` → the TTS provider's voices (``tts_id`` selects them);
    ``realtime`` → the realtime model's voices (``realtime_model_id`` empty means
    Gemini Live). ``current_voice_id`` is the voice the session was actually
    built with (already defaulted by the caller)."""
    if mode == MODE_CASCADE:
        voice_list = _tts_voices(tts_id)
        provider = _provider_of(tts_id) or "default"
        hot_swap = False
    else:
        model_id = realtime_model_id or REALTIME_GEMINI
        voice_list = _realtime_voices_for(model_id)
        if model_id == REALTIME_GEMINI or _provider_of(model_id).startswith("google"):
            provider = "gemini"
        elif model_id == REALTIME_OPENAI or _provider_of(model_id).startswith("openai"):
            provider = "openai"
        else:
            provider = _provider_of(model_id) or model_id
        hot_swap = model_id == REALTIME_GEMINI
    return RuntimeVoices(
        provider=provider,
        voices=tuple(voice_list),
        current=_match_current(voice_list, current_voice_id),
        hot_swap=hot_swap,
        supports_accent=provider_supports_accent(provider),
    )


def accent_supported(prof: dict) -> bool:
    """Whether the stack a user's SAVED preference (``prof`` = their
    ``profile/main`` dict) resolves to honours a free-text accent. Used by the
    text-chat ``set_voice_preference`` path, where there is no live session to
    read the active provider from: the next voice call uses the saved stack, so
    its capability is the honest answer. Mirrors the ``/voice/engines`` default
    resolution — empty fields fall back to the catalog default — and funnels
    through the one :func:`runtime_voices` resolver, so it can never disagree with
    the agent's boot-time routing."""
    import schema

    default = default_selection()
    mode = str(prof.get(schema.PF_AYMA_VOICE_MODE, "")).strip() or default["mode"]
    if mode == MODE_REALTIME:
        realtime_id = (
            str(prof.get(schema.PF_AYMA_REALTIME_MODEL, "")).strip()
            or default["realtime_model_id"]
        )
        return runtime_voices(
            mode=MODE_REALTIME, realtime_model_id=realtime_id
        ).supports_accent
    tts_id = str(prof.get(schema.PF_AYMA_CASCADE_TTS, "")).strip() or default["tts_id"]
    return runtime_voices(mode=MODE_CASCADE, tts_id=tts_id).supports_accent


# Gender synonyms for resolving a free-text voice request within a provider set
# (shared with ``voices`` but kept local so this stays the one resolver the
# cascade/non-Gemini ``set_voice_preference`` path uses).
_FEMININE_WORDS = ("female", "woman", "feminine", "girl", "lady", "she", "her")
_MASCULINE_WORDS = ("male", "man", "masculine", "guy", "boy", "he", "him")


# Words that must never, on their own, pick a voice via description overlap
# (articles/fillers that appear in both requests and "an engaged speaker"-style
# descriptions). "accent"/"voice"/"sound" are request nouns, not timbre words.
_RESOLVE_STOPWORDS = frozenset(
    {"a", "an", "the", "and", "or", "of", "to", "in", "with", "please", "can",
     "you", "your", "me", "my", "i", "is", "it", "that", "this", "more", "bit",
     "like", "sound", "sounds", "voice", "accent", "english", "american"}
)


def resolve_voice(request: str, voice_list, *, gender_only: bool = False) -> Voice | None:
    """Closest match for a free-text voice request within ``voice_list`` (the
    ACTIVE provider's set), or ``None`` when nothing matches / the set is empty.

    Order: an exact label or id; a voice's label as a whole word in the text
    ("use the Hannah voice"); a gendered descriptor → the first voice of that
    gender; then a meaningful word shared with a voice's description ("deep",
    "warm" — stopwords excluded). ``gender_only`` stops after the gender step
    (for the accent/language field, where "a male voice … American English"
    carries a gender but the rest is not a voice character). The bare ``""``
    vendor-default sentinel is never returned — a match is always a concrete,
    nameable voice."""
    req = (request or "").strip().lower()
    pickable = [v for v in voice_list if v.id]
    if not req or not pickable:
        return None
    if not gender_only:
        for v in pickable:
            if req == v.label.lower() or req == v.id.lower():
                return v
        for v in pickable:
            if re.search(rf"\b{re.escape(v.label.lower())}\b", req):
                return v
    want = ""
    if any(re.search(rf"\b{w}\b", req) for w in _FEMININE_WORDS):
        want = "feminine"
    elif any(re.search(rf"\b{w}\b", req) for w in _MASCULINE_WORDS):
        want = "masculine"
    if want:
        for v in pickable:
            if v.gender == want:
                return v
    if gender_only:
        return None
    words = {w for w in re.findall(r"[a-z]+", req) if w not in _RESOLVE_STOPWORDS}
    for v in pickable:
        dwords = {
            w for w in re.findall(r"[a-z]+", v.description.lower())
            if w not in _RESOLVE_STOPWORDS
        }
        if words & dwords:
            return v
    return None


def current_label(rv: RuntimeVoices) -> str:
    """The human name of the running voice ("Hannah", "Aoede"), for the agent's
    "which voice are you on" answer."""
    if rv.current is None or not rv.current.label:
        return "the default voice"
    return rv.current.label


def vocab_lines(rv: RuntimeVoices) -> str:
    """A bulleted "- Label (description)" list of the stack's selectable voices
    for the agent's "what voices do you have" answer. Falls back to a single
    "default voice" line for a provider with no documented named voices."""
    pickable = [v for v in rv.voices if v.id]
    if not pickable:
        return "- the provider's default voice"
    return "\n".join(
        f"- {v.label}" + (f" ({v.description})" if v.description else "")
        for v in pickable
    )
