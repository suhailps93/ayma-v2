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

Sourcing. The cascade's model lists are fetched **live** from the LiveKit
Inference catalog: the gateway (``get_default_inference_url`` →
``agent-gateway.livekit.cloud/v1``) is OpenAI-compatible and serves
``GET /v1/models``, where each model carries a TYPE (STT / TTS / LLM / realtime /
TD / INT). :func:`_sources` fetches and categorizes it with the project's
``LIVEKIT_API_KEY``/``SECRET`` (no LLM request, so it costs nothing), cached for
``_CATALOG_TTL_SECONDS``, so when the catalog is populated whatever the project's
credits activate shows up in the dropdowns with no code change.

**Known gap (verified 2026-10-27).** For THIS project ``GET /v1/models`` returns
HTTP 200 with an empty body ``{}`` (an InferenceGrants JWT authenticates fine —
it is simply not populated for our plan; no ``?task=`` filter changes it). So
the live path yields nothing and :func:`_sources` uses the config FALLBACK lists
(``CONFIG.voice_cascade_*_models``, ``source="fallback"``) — the active path in
production today. Those lists enumerate the providers the project has LiveKit
startup credits for, with canonical model ids from the LiveKit docs
(docs.livekit.io/agents/models). On the fallback path availability is marked
TRUTHFULLY (:func:`_availability`): a provider in ``CONFIG.voice_credited_providers``
is enabled; any other (e.g. ``cartesia``) is shown disabled with a "needs LiveKit
credits" note rather than a silently-failing pick. If LiveKit later populates
``/v1/models``, the live path takes over automatically and everything it returns
is enabled. Merged in on top either way: the direct Meta Muse brain (not a
LiveKit model — via the Meta API) and the two realtime models (Gemini Live, the
LOCKED model; OpenAI Realtime, flag-gated).

Per-TTS *voice* lists are a separate concern — ``/v1/models`` lists models, not
each model's voices — so they come from :func:`_livekit_tts_voices` (the live
extension point, empty today) else the **documented** fallback in
:data:`_TTS_FALLBACK_VOICES` (the LiveKit docs' per-provider sample voices;
overridable by ``VOICE_TTS_VOICES_<PROVIDER>``).

Model ids all live in ``config.py``/the live catalog per ``AGENTS.md``; this
module holds only voice *ids*/labels and catalog metadata (routes, availability).
"""

from __future__ import annotations

import datetime
import logging
import os
import re
import time
from dataclasses import dataclass

import voices
from config import CONFIG
from llm_provider import PROVIDER_GEMINI, PROVIDER_META

logger = logging.getLogger("ayma.voice_catalog")

MODE_REALTIME = "realtime"
MODE_CASCADE = "cascade"
MODES = (MODE_REALTIME, MODE_CASCADE)

# Stable realtime-model + Meta-brain ids persisted on the profile — never
# renamed. Inference brains/STT/TTS use the LiveKit model string as their id.
REALTIME_GEMINI = "gemini-live"
REALTIME_OPENAI = "openai-realtime"
BRAIN_META = "meta-muse-spark"

# Cascade brain ROUTES (how the agent builds the LLM leg).
ROUTE_META = "meta"
ROUTE_INFERENCE = "inference"

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
    "cartesia": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
    ],
    "elevenlabs": [
        Voice(id="", label="Default voice", description="the vendor default voice"),
    ],
}


def _provider_of(model: str) -> str:
    """``"inworld/inworld-tts-1"`` -> ``"inworld"``; bare model -> ``""``."""
    return model.split("/", 1)[0] if "/" in model else ""


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


# --- LIVE LiveKit inference catalog -----------------------------------------
#
# The inference gateway (``get_default_inference_url`` → agent-gateway) is
# OpenAI-compatible and serves ``GET /v1/models`` (the installed SDK calls
# ``client.models.list()`` for prewarm). LiveKit tags each model with a TYPE
# (STT / TTS / LLM / realtime / TD / INT). We fetch that live so the dropdowns
# reflect exactly what the project's credits have activated — new providers
# (Fish Audio, AssemblyAI, Rime, Gradium…) appear with no code change. The call
# needs only the project's ``LIVEKIT_API_KEY``/``SECRET`` (already used to mint
# room tokens) and makes NO LLM request, so it costs nothing. On any failure the
# config fallback lists are used, clearly marked ``source="fallback"``.

_TYPE_ALIASES = {
    "stt": "stt", "speech_to_text": "stt", "speech-to-text": "stt",
    "transcription": "stt", "asr": "stt",
    "tts": "tts", "text_to_speech": "tts", "text-to-speech": "tts",
    "speech": "tts",
    "llm": "llm", "chat": "llm", "language": "llm",
    "realtime": "realtime", "rt": "realtime", "duplex": "realtime",
    "speech_to_speech": "realtime", "realtime_model": "realtime",
}


def _inference_base_url() -> str:
    try:
        from livekit.agents.inference._utils import get_default_inference_url

        return get_default_inference_url().rstrip("/")
    except Exception:  # noqa: BLE001 - SDK layout drift / not installed
        return os.getenv(
            "LIVEKIT_INFERENCE_URL", "https://agent-gateway.livekit.cloud/v1"
        ).rstrip("/")


def _inference_jwt() -> str | None:
    key = os.getenv("LIVEKIT_INFERENCE_API_KEY", os.getenv("LIVEKIT_API_KEY", ""))
    secret = os.getenv(
        "LIVEKIT_INFERENCE_API_SECRET", os.getenv("LIVEKIT_API_SECRET", "")
    )
    if not key or not secret:
        return None
    try:
        from livekit import api

        grant = api.access_token.InferenceGrants(perform=True)
        return (
            api.AccessToken(key, secret)
            .with_identity("ayma-voice-catalog")
            .with_inference_grants(grant)
            .with_ttl(datetime.timedelta(seconds=120))
            .to_jwt()
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("could not mint a LiveKit inference token: %s", exc)
        return None


def _fetch_livekit_models() -> list[dict] | None:
    """Raw ``GET /v1/models`` items from the LiveKit inference gateway, or
    ``None`` when unavailable (no creds, network/SDK error). Best-effort."""
    jwt = _inference_jwt()
    if not jwt:
        return None
    url = _inference_base_url() + "/models"
    try:
        import httpx

        resp = httpx.get(
            url, headers={"Authorization": f"Bearer {jwt}"}, timeout=4.0
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:  # noqa: BLE001 - never let a fetch fail the endpoint
        logger.warning("LiveKit inference catalog fetch failed (%s)", exc)
        return None
    items = data.get("data") if isinstance(data, dict) else data
    return items if isinstance(items, list) else None


def _model_type(item: dict) -> str:
    raw = (
        item.get("type")
        or item.get("model_type")
        or item.get("kind")
        or (item.get("metadata") or {}).get("type")
        or ""
    )
    return _TYPE_ALIASES.get(str(raw).strip().lower(), "")


def _categorize_live(items: list[dict]) -> dict[str, list[str]] | None:
    """Group live model ids by our four categories. ``None`` when not one item
    carries a recognizable TYPE (unknown shape) so we fall back rather than
    misclassify."""
    buckets: dict[str, list[str]] = {"llm": [], "stt": [], "tts": [], "realtime": []}
    saw_type = False
    for item in items:
        if not isinstance(item, dict):
            continue
        mid = str(item.get("id") or item.get("model") or "").strip()
        if not mid:
            continue
        kind = _model_type(item)
        if kind:
            saw_type = True
        if kind in buckets:
            buckets[kind].append(mid)
    return buckets if saw_type else None


def _sources() -> dict[str, object]:
    """Resolved component model ids by category: the live LiveKit catalog when
    reachable, else the config fallback. Shared by the catalog + validators."""
    items = _fetch_livekit_models()
    live = _categorize_live(items) if items else None
    if live and (live["llm"] or live["stt"] or live["tts"]):
        return {
            "source": "livekit",
            "llm": live["llm"] or list(CONFIG.voice_cascade_llm_models),
            "stt": live["stt"] or list(CONFIG.voice_cascade_stt_models),
            "tts": live["tts"] or list(CONFIG.voice_cascade_tts_models),
            "realtime": live["realtime"],
        }
    return {
        "source": "fallback",
        "llm": list(CONFIG.voice_cascade_llm_models),
        "stt": list(CONFIG.voice_cascade_stt_models),
        "tts": list(CONFIG.voice_cascade_tts_models),
        "realtime": [],
    }


def _availability(provider: str, source: str) -> tuple[bool, str]:
    """``(available, requires)`` for a cascade option, marked TRUTHFULLY.

    A LIVE LiveKit catalog lists exactly what the project's credits have
    enabled, so anything it returns is available. On the config FALLBACK path
    (``/v1/models`` is empty for this project — see the module docstring) we
    cannot query the project, so we trust only the providers known to carry
    LiveKit Inference credits (``CONFIG.voice_credited_providers``). Any other
    fallback option is returned ``available=False`` with a short note, so the UI
    shows it disabled ("needs LiveKit credits") instead of offering a pick that
    would silently fail mid-call. A bare id with no provider segment is left
    available (nothing to check it against)."""
    if source == "livekit":
        return True, ""
    if not provider or provider in CONFIG.voice_credited_providers:
        return True, ""
    return False, "LiveKit credits"


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
                "voices": [v.to_dict() for v in _OPENAI_REALTIME_VOICES],
                "languages": langs,
            }
        )
    # Any other realtime-type model LiveKit exposes (google/openai realtime are
    # already represented by the two canonical options above).
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
                "voices": [v.to_dict() for v in _realtime_voices_for(mid)],
                "languages": langs,
            }
        )
    return models


def brain_route(brain_id: str) -> tuple[str, str] | None:
    """``(route, model_id)`` for a cascade brain id, or ``None`` if unknown.
    The Meta brain is ``meta`` → ``CONFIG.meta_chat_model``; every other brain id
    is itself a LiveKit Inference LLM model string (route ``inference``)."""
    if brain_id == BRAIN_META:
        return ROUTE_META, CONFIG.meta_chat_model
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
    # Meta Muse Spark is a direct-API brain (not in LiveKit's catalog); the rest
    # are LiveKit Inference LLMs, so new ones appear automatically.
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
    src = str(sources["source"])
    for mid in sources["llm"]:  # type: ignore[index]
        provider = _provider_of(mid)
        available, requires = _availability(provider, src)
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
    src = str(sources["source"])
    out: list[dict[str, object]] = []
    for m in sources["stt"]:  # type: ignore[index]
        provider = _provider_of(m)
        available, requires = _availability(provider, src)
        out.append({
            "id": m, "label": m, "provider": provider,
            "available": available, "requires_secret": requires,
        })
    return out


def _tts(sources: dict[str, object]) -> list[dict[str, object]]:
    langs = _languages()
    src = str(sources["source"])
    out: list[dict[str, object]] = []
    for m in sources["tts"]:  # type: ignore[index]
        provider = _provider_of(m)
        available, requires = _availability(provider, src)
        out.append({
            "id": m,
            "label": m,
            "provider": provider,
            "available": available,
            "requires_secret": requires,
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
    live LiveKit fetch happens at most once per TTL, never per request)."""
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
    stt = _first(sources["stt"])  # type: ignore[index]
    tts = _first(sources["tts"])  # type: ignore[index]
    if CONFIG.llm_provider_voice_main == PROVIDER_META:
        return {
            "mode": MODE_CASCADE, "realtime_model_id": "",
            "brain_id": BRAIN_META, "stt_id": stt, "tts_id": tts,
        }
    return {
        "mode": MODE_REALTIME, "realtime_model_id": REALTIME_GEMINI,
        "brain_id": BRAIN_META, "stt_id": stt, "tts_id": tts,
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
