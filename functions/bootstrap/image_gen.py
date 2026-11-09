"""Capped image generation — the founder-authorized restore of Ayma's
in-chat image generation (2026-11-08), rebuilt as a pluggable provider
catalog with the same fail-closed daily cap that web search uses.

THE SCOPED EXCEPTION (read this first): image generation is the ONE Ayma
inference path the founder has authorized to call a model provider
DIRECTLY, outside the LiveKit Inference gateway (founder decision
2026-11-08, relayed by Astro). Direct Gemini image calls bill Google, not
the LiveKit credits — chosen knowingly. **This exception is image
generation ONLY.** Every other inference path (chat, matching, JSON,
vision, and voice STT/TTS/realtime) stays LiveKit-only exactly as before.
The no-direct-Google static scan (``tests/test_llm_call_site_coverage.py``)
names THIS module on its image-generation exception list; no other served
module may construct a direct-Google client. ``gemini.generate_image`` /
``gemini.edit_image`` are the public face of this exception: they route
here and contain no direct call of their own.

How it works (mirrors :mod:`web_search`):

* A pluggable catalog (:data:`_CATALOG`) declares image providers and
  their models. Adding a model — from any provider, including a future
  LiveKit image provider — is adding one catalog entry, nothing else.
  Entry 1 is ``gemini-direct`` (the locked ``gemini_image_edit_model``),
  available and the default. Entry 2 is ``xai-direct``
  (``grok-imagine-image-2.0``), which ships READY-BUT-UNAVAILABLE: with no
  ``XAI_API_KEY`` configured its model is not listed in the picker and any
  routed call returns the honest ``unconfigured`` outcome with no provider
  call. It becomes available with zero code change once the secret lands.
* HARD CAP (the point of the design): a Firestore counter at
  ``image_gen_usage/{YYYY-MM-DD}`` — the America/Los_Angeles day, in this
  environment's own Firestore project — is checked AND incremented inside
  a single transaction BEFORE any provider call. The cap is a named
  constant (100/day). Call 101 is never made. If the counter store is
  unreachable or errors, generation FAILS CLOSED: no provider call. There
  is no path from :func:`generate` to a provider that skips the counter,
  and a cap of 0 pauses generation outright.
* No silent fallback: a selection that cannot be served returns a typed
  outcome naming the vendor + model id; it never quietly switches to
  another provider or to the default model. The one non-failure default is
  for a user who has made NO pick — they get the default entry
  (``gemini-direct``), which is the selection, not a fallback from failure.
* Honest states: callers get a typed :class:`ImageOutcome` — ``ok`` (image
  bytes), ``paused`` (today's cap is used up; it resets at midnight
  Pacific), ``unconfigured`` (the selected provider has no key on this
  server), ``unavailable`` (the selected model is unknown / cannot be
  resolved), ``error`` (the generation or the counter failed). This module
  never raises for those states.
"""

from __future__ import annotations

import asyncio
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from zoneinfo import ZoneInfo

import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.image_gen")

USAGE_COLLECTION = "image_gen_usage"
_DAY_TZ = ZoneInfo("America/Los_Angeles")
_DEFAULT_CAP = 100
_GENERATE_TIMEOUT_SECONDS = 75.0
_RETRIES = 2
_RETRY_BACKOFF = 0.6

# Provider ids (the catalog keys). gemini-direct is the default.
PROVIDER_GEMINI_DIRECT = "gemini-direct"
PROVIDER_XAI_DIRECT = "xai-direct"
DEFAULT_PROVIDER = PROVIDER_GEMINI_DIRECT

# xAI Imagine REST routes (docs.x.ai / x.ai/api). Fixed endpoints — only the
# bearer key + model id are configurable (config.py), mirroring how
# web_search keeps provider URLs as module constants.
_XAI_GENERATE_URL = "https://api.x.ai/v1/images/generations"
_XAI_EDIT_URL = "https://api.x.ai/v1/images/edits"
_XAI_TIMEOUT_SECONDS = 60

STATUS_OK = "ok"
STATUS_PAUSED = "paused"
STATUS_UNCONFIGURED = "unconfigured"
STATUS_UNAVAILABLE = "unavailable"
STATUS_ERROR = "error"

PAUSED_MESSAGE = (
    "Image generation is used up for today: Ayma gets a fixed number of "
    "free image generations a day and today's are all gone. It comes back "
    "tomorrow — the count resets at midnight Pacific. Tell the user exactly "
    "that, in plain words; do not call it a glitch or an internal error."
)
UNCONFIGURED_MESSAGE = (
    "The selected image model is not available right now: it is not set up "
    "on this server yet. Tell the user you cannot generate the image with "
    "that model at the moment; do not invent an image."
)
UNAVAILABLE_MESSAGE = (
    "That image model is not available. Tell the user the selected image "
    "model could not be used; do not invent an image."
)
ERROR_MESSAGE = (
    "The image did not generate this time. Tell the user it did not work; "
    "do not invent an image."
)


class ImageQuotaUnavailable(RuntimeError):
    """The daily-counter store failed; the caller must not generate."""


class _ProviderError(RuntimeError):
    """One provider generation failed; ``message`` is user-safe (it may be a
    model safety-refusal), ``code`` the HTTP status when known."""

    def __init__(self, message: str, *, code: int | None = None):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ImageModel:
    """One catalog entry — a provider + the model it serves. Fully
    data-driven and provider-agnostic: a future provider (including a LiveKit
    image gateway) is another entry with the same fields, no code branches.
    ``model_attr`` / ``key_attr`` name the ``config.py`` attributes that hold
    the model id and the API key, so whether the entry is listed/available is
    resolved from config at read time, never frozen into the catalog."""

    provider: str
    label: str
    description: str
    model_attr: str
    #: CONFIG attribute holding the provider's API key, or ``None`` when the
    #: provider authenticates without one (gemini-direct uses Vertex ADC / the
    #: ambient GOOGLE_API_KEY, so it needs no catalog key).
    key_attr: str | None


@dataclass
class ImageOutcome:
    status: str
    image_bytes: bytes = b""
    mime: str = ""
    message: str = ""
    provider: str = ""
    model: str = ""
    error_code: int | None = None


# The catalog: the one source for the picker. The dynamic bits (model id,
# whether the provider is configured) come from the named config attributes,
# so adding a model — from any provider — is adding ONE entry here (its two
# config attrs), nothing else. Order is the picker order.
_CATALOG: tuple[ImageModel, ...] = (
    ImageModel(
        provider=PROVIDER_GEMINI_DIRECT,
        label="Gemini (Google)",
        description=(
            "Google's Gemini image model, called directly — the default. "
            "Fast, strong at caricatures and edits of your own photos."
        ),
        model_attr="gemini_image_edit_model",
        key_attr=None,
    ),
    ImageModel(
        provider=PROVIDER_XAI_DIRECT,
        label="Grok Imagine (xAI)",
        description=(
            "xAI's Grok Imagine image model. Only shown once an xAI API key "
            "is configured on the server."
        ),
        model_attr="image_gen_xai_model",
        key_attr="image_gen_xai_api_key",
    ),
)


def _entry(provider: str) -> ImageModel | None:
    for e in _CATALOG:
        if e.provider == provider:
            return e
    return None


def model_id_for(provider: str) -> str:
    """The configured model id for ``provider`` — the single source of truth
    (``config.py`` via the entry's ``model_attr``). Empty for an unknown
    provider or an unset attribute."""
    entry = _entry(provider)
    if entry is None:
        return ""
    return str(getattr(CONFIG, entry.model_attr, "") or "").strip()


def is_configured(provider: str) -> bool:
    """Whether ``provider`` can serve a generation on this deploy: it has a
    model id, and either needs no key (``key_attr is None`` — gemini-direct
    via Vertex ADC) or has its key set. ``xai-direct`` with no ``XAI_API_KEY``
    is unconfigured, so it is never listed and never the default."""
    entry = _entry(provider)
    if entry is None or not model_id_for(provider):
        return False
    if entry.key_attr is None:
        return True
    return bool(str(getattr(CONFIG, entry.key_attr, "") or "").strip())


def default_model_id() -> str:
    """The model id behind the default provider (``gemini-direct``)."""
    return model_id_for(DEFAULT_PROVIDER)


def available_models() -> list[dict[str, object]]:
    """The image-model catalog for the Models-screen picker (``GET
    /image-model/preference``): each CONFIGURED provider plus its model id.
    An unavailable provider (e.g. ``xai-direct`` with no key) is left out —
    the UI only ever offers models it can actually run. No model spend."""
    out: list[dict[str, object]] = []
    for entry in _CATALOG:
        if not is_configured(entry.provider):
            continue
        out.append(
            {
                "id": entry.provider,
                "label": entry.label,
                "description": entry.description,
                "model": model_id_for(entry.provider),
                "available": True,
            }
        )
    return out


def read_image_model_pref(uid: str | None) -> str:
    """The user's saved image-model provider id (``ayma_image_model`` on
    ``users/{uid}/profile/main``), or ``""`` when unset / unreadable / no uid.
    Best-effort: a read failure returns ``""`` (→ the default), never raises,
    so image generation can't be taken down by a profile read. Factored out so
    tests can monkeypatch it instead of standing up Firestore."""
    if not uid:
        return ""
    try:
        import schema
        from db import get_db

        snap = schema.profile_doc(get_db(), uid).get()
        return str(
            (snap.to_dict() or {}).get(schema.PF_AYMA_IMAGE_MODEL, "")
        ).strip()
    except Exception:  # noqa: BLE001 - best-effort; fall back to the default
        logger.exception("could not read ayma_image_model for %s", uid)
        return ""


def _today_pt(now: datetime | None = None) -> str:
    """The current America/Los_Angeles calendar day (``YYYY-MM-DD``) — the
    counter's day boundary is midnight Pacific, per the design."""
    if now is None:
        now = datetime.now(_DAY_TZ)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=_DAY_TZ)
    return now.astimezone(_DAY_TZ).strftime("%Y-%m-%d")


def _cap() -> int:
    cap = CONFIG.image_gen_daily_cap
    return cap if isinstance(cap, int) else _DEFAULT_CAP


def _reserve(db, day: str, cap: int) -> bool:
    """Atomically count one generation against ``day``'s cap.

    True means the caller may make exactly one provider call. False means
    the cap is already reached — nothing is counted and no call may follow.
    The read, the limit check and the increment happen in one Firestore
    transaction, so concurrent instances cannot slip past the cap together.
    Raises :class:`ImageQuotaUnavailable` on any store failure: an
    unverifiable budget means no generation (fail closed).

    The transaction MUST run through ``firestore.transactional`` (the
    ``practice_core.append_turns`` / ``web_search._reserve`` pattern fixed in
    565075aa): a transaction object taken straight from ``db.transaction()``
    is never begun, and google-cloud-firestore 2.x raises "Transaction not in
    progress" on the first read through it — the trap that made the 2026-11-07
    web-search switch-on fail closed while its unit tests stayed green. The
    decorator also supplies contention retries; any store failure that still
    surfaces is wrapped as ImageQuotaUnavailable here."""
    if cap <= 0:
        return False
    from google.cloud import firestore

    @firestore.transactional
    def _attempt(transaction) -> bool:
        ref = db.collection(USAGE_COLLECTION).document(day)
        snap = ref.get(transaction=transaction)
        data = snap.to_dict() if snap.exists else None
        count = int((data or {}).get("count", 0) or 0)
        if count >= cap:
            return False
        if snap.exists:
            transaction.update(ref, {"count": count + 1})
        else:
            transaction.set(ref, {"count": 1, "day": day, "cap": cap})
        return True

    try:
        return _attempt(db.transaction())
    except Exception as exc:  # noqa: BLE001 - any store failure fails closed
        raise ImageQuotaUnavailable(
            f"image-gen quota store failed: {exc}"
        ) from exc


# ------------------------------------------------------------------ providers
#
# The SCOPED EXCEPTION lives entirely below this line: this is the only served
# code that constructs a direct-Google (or any direct provider) image client.
# Each caller makes exactly ONE generation request and returns ``(bytes,
# mime)`` or raises :class:`_ProviderError`. Adding a provider is one new
# caller here (same signature) plus its catalog entry + config — nothing else
# in the module moves.


async def _gemini_direct_call(
    prompt: str,
    image: tuple[bytes, str] | None,
    *,
    model_id: str,
    uid: str | None,
    feature: str,
) -> tuple[bytes, str]:
    """Restore of the pre-kill direct Gemini image call: a ``generate_content``
    pass with ``response_modalities=["TEXT", "IMAGE"]`` against the locked
    ``gemini_image_edit_model``, reading the image back out of the first
    ``inline_data`` part. Same Vertex-ADC / API-key client the rest of the
    pre-kill gemini.py used. Meters the spend to the user's ledger exactly as
    before. Raises :class:`_ProviderError` with the model's refusal text when
    no image part comes back (a safety/content-policy refusal or transient
    failure)."""
    # Lazy import so the direct-Google SDK is pulled in only on the one
    # authorized path (and so module import never requires it in tests).
    from google import genai
    from google.genai import types

    if CONFIG.use_vertex:
        # ADC = the Cloud Run runtime service identity; no API key.
        client = genai.Client(
            vertexai=True,
            project=CONFIG.project_id or None,
            location=CONFIG.gemini_location,
        )
    else:
        client = genai.Client()  # picks up GOOGLE_API_KEY from the environment

    parts: list = []
    if image is not None:
        parts.append(types.Part.from_bytes(data=image[0], mime_type=image[1]))
    parts.append(prompt)

    response = None
    for attempt in range(_RETRIES + 1):
        try:
            response = await asyncio.wait_for(
                client.aio.models.generate_content(
                    model=model_id,
                    contents=parts,
                    config=types.GenerateContentConfig(
                        response_modalities=["TEXT", "IMAGE"],
                    ),
                ),
                timeout=_GENERATE_TIMEOUT_SECONDS,
            )
            break
        except asyncio.TimeoutError as exc:
            logger.error(
                "gemini image call timed out after %.0fs",
                _GENERATE_TIMEOUT_SECONDS,
            )
            raise _ProviderError(
                f"{PROVIDER_GEMINI_DIRECT} ({model_id}) timed out"
            ) from exc
        except Exception as exc:  # noqa: BLE001 - broad retry, see web_search
            if attempt >= _RETRIES:
                raise _ProviderError(
                    f"{PROVIDER_GEMINI_DIRECT} ({model_id}) failed: {exc}"
                ) from exc
            logger.warning(
                "gemini image call failed (%s: %s) on attempt %d/%d — retrying",
                type(exc).__name__, exc, attempt + 1, _RETRIES + 1,
            )
            await asyncio.sleep(_RETRY_BACKOFF * (attempt + 1))

    token_ledger.record(uid, feature, response, model=model_id)
    try:
        out_parts = response.candidates[0].content.parts or []
    except (AttributeError, IndexError, TypeError):
        out_parts = []
    for part in out_parts:
        inline = getattr(part, "inline_data", None)
        data = getattr(inline, "data", None) if inline else None
        if data:
            mime = (getattr(inline, "mime_type", "") or "image/png").strip()
            return data, mime
    # No image part — most likely a safety/content-policy refusal carried in
    # the text. Surface it verbatim; the skill relays it as the chat reply.
    refusal = (getattr(response, "text", "") or "").strip()
    raise _ProviderError(
        refusal or f"{PROVIDER_GEMINI_DIRECT} ({model_id}) returned no image"
    )


def _xai_direct_sync(
    prompt: str,
    image: tuple[bytes, str] | None,
    *,
    model_id: str,
    api_key: str,
) -> tuple[bytes, str]:
    """One xAI Imagine image request (generation, or edit when an input image
    is supplied). Bearer auth, JSON body, base64 image back. Raises
    :class:`_ProviderError`. Ships inert: with no ``XAI_API_KEY`` the provider
    is unconfigured and this is never reached — it is correct-shaped so the
    entry becomes live with no code change once the key is set."""
    if image is not None:
        url = _XAI_EDIT_URL
        body = {
            "model": model_id,
            "prompt": prompt,
            "image": _b64(image[0]),
            "response_format": "b64_json",
        }
    else:
        url = _XAI_GENERATE_URL
        body = {
            "model": model_id,
            "prompt": prompt,
            "response_format": "b64_json",
        }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=_XAI_TIMEOUT_SECONDS) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise _ProviderError(
            f"{PROVIDER_XAI_DIRECT} ({model_id}) HTTP {exc.code}", code=exc.code
        ) from exc
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        raise _ProviderError(
            f"{PROVIDER_XAI_DIRECT} ({model_id}) failed: {exc}"
        ) from exc
    items = data.get("data") or []
    for item in items:
        b64 = (item or {}).get("b64_json") or ""
        if b64:
            import base64

            return base64.b64decode(b64), "image/png"
    raise _ProviderError(
        f"{PROVIDER_XAI_DIRECT} ({model_id}) returned no image"
    )


def _b64(raw: bytes) -> str:
    import base64

    return base64.b64encode(raw).decode()


async def _xai_direct_call(
    prompt: str,
    image: tuple[bytes, str] | None,
    *,
    model_id: str,
    uid: str | None,
    feature: str,
) -> tuple[bytes, str]:
    return await asyncio.to_thread(
        _xai_direct_sync,
        prompt,
        image,
        model_id=model_id,
        api_key=(CONFIG.image_gen_xai_api_key or "").strip(),
    )


# The provider seam: the selected catalog entry names one of these. Keyed by
# provider id so routing is a dict lookup — no if/else ladder, no silent
# cross-provider fallback.
_PROVIDER_CALLERS = {
    PROVIDER_GEMINI_DIRECT: _gemini_direct_call,
    PROVIDER_XAI_DIRECT: _xai_direct_call,
}


def _resolve_provider(uid: str | None) -> str:
    """The provider id to use for ``uid``: their saved pick when it is a known
    provider, else the default (``gemini-direct``). An empty/unknown saved
    value falls through to the default — the user has effectively not picked.
    Configured-ness is NOT decided here (that is the generate() step), so a
    saved-but-now-unconfigured pick surfaces an honest ``unconfigured``
    outcome rather than a silent switch to the default."""
    pref = read_image_model_pref(uid)
    if pref in _PROVIDER_CALLERS:
        return pref
    return DEFAULT_PROVIDER


async def generate(
    prompt: str,
    *,
    image: tuple[bytes, str] | None = None,
    uid: str | None = None,
    feature: str = "misc",
    db=None,
    now: datetime | None = None,
) -> ImageOutcome:
    """Generate one image through the user's selected provider, capped and
    fail-closed. Never raises for a selection/quota/provider state — the
    outcome's ``status`` says which state it is in. The daily counter is
    consulted (and incremented) BEFORE the provider is called, every time;
    there is no path to a provider from here that skips it, and exactly one
    provider call is made per ``ok``-eligible generation."""
    provider = _resolve_provider(uid)
    model_id = model_id_for(provider)
    caller = _PROVIDER_CALLERS.get(provider)
    if caller is None or not model_id:
        logger.warning("image gen unavailable: provider=%r", provider)
        return ImageOutcome(
            STATUS_UNAVAILABLE, message=UNAVAILABLE_MESSAGE, provider=provider,
            model=model_id,
        )
    if not is_configured(provider):
        logger.warning(
            "image gen unconfigured: provider=%s model=%s", provider, model_id
        )
        return ImageOutcome(
            STATUS_UNCONFIGURED, message=UNCONFIGURED_MESSAGE,
            provider=provider, model=model_id,
        )

    if db is None:
        from db import get_db

        db = get_db()
    day = _today_pt(now)
    try:
        allowed = _reserve(db, day, _cap())
    except ImageQuotaUnavailable as exc:
        logger.warning("image gen fail-closed: %s", exc)
        return ImageOutcome(
            STATUS_ERROR, message=ERROR_MESSAGE, provider=provider,
            model=model_id,
        )
    if not allowed:
        logger.info(
            "image gen paused: daily cap %d reached for %s", _cap(), day
        )
        return ImageOutcome(
            STATUS_PAUSED, message=PAUSED_MESSAGE, provider=provider,
            model=model_id,
        )

    try:
        data, mime = await caller(
            prompt, image, model_id=model_id, uid=uid, feature=feature
        )
    except _ProviderError as exc:
        logger.warning("image gen provider error: %s", exc)
        return ImageOutcome(
            STATUS_ERROR, message=str(exc) or ERROR_MESSAGE,
            provider=provider, model=model_id, error_code=exc.code,
        )
    return ImageOutcome(
        STATUS_OK, image_bytes=data, mime=mime, provider=provider,
        model=model_id,
    )
