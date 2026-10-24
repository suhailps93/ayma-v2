"""Per-user Gemini token accounting + a credit balance.

Every Gemini call the user's activity drives — text chat with Ayma, icebreaker
generation, the matching skill, wiki ingest, natural-language Explore parsing,
Ayma's background check-in, and the Gemini Live voice session (recorded by the
agent worker) — adds its token count to ``users/{uid}.token_usage``:

    token_usage: {
      total: <int>,
      input: <int>,   # prompt / input tokens, summed lifetime (cost audits)
      output: <int>,  # candidates / output tokens, summed lifetime
      cached_input: <int>,  # the SUBSET of `input` served from Gemini's
                            # implicit prompt cache (usage_metadata.
                            # cached_content_token_count), summed lifetime —
                            # verifies the byte-stable chat prefix
                            # (2026-09-26) is actually hitting
      cost_usd: <float>,  # real $ cost, summed lifetime since this field
                          # started being written (see below) — starts at
                          # zero, only ever added to, never backfilled
      features: { chat: <int>, voice: <int>, matching: <int>, wiki: <int>,
                  explore: <int>, reengage: <int>, ... },
      cached_features: { chat: <int>, ... },  # per-feature cached_input split
      updated_at: <server ts>
    }

``input``/``output`` are additive accounting fields only — Gemini prices input
and output tokens very differently (see PLAN.md F1/F2), so a real-dollar cost
audit needs the split. ``total`` remains the one number credit charging and
the token cap read (see :func:`_credit_view`); the split is never used there
and never changes what a call costs the user. Note ``total`` can exceed
``input + output`` when thinking or tool-use tokens are billed (Gemini's own
``total_token_count`` includes those; the input/output split here does not).

``cost_usd`` is the running real-dollar cost of the account, computed from
``input``/``output`` at each :func:`add`/:func:`record` call using the
per-model pricing in ``_MODEL_PRICING`` below (founder request, 2026-09-16:
"exact value based on the usage period ... start from zero and then just add
as they go"). It is a Firestore ``Increment`` applied alongside ``input``/
``output`` in the very same write, so it only ever grows from real recorded
calls going forward — usage docs written before the input/output split
existed (pre commit 278c562) have no ``input``/``output`` and contribute
``$0`` here rather than an estimate; this module never re-derives ``cost_usd``
from a full history scan.

Spend is shown to the user as **credits** only (never dollars):
1 credit = $0.01 of real token cost (``CONFIG.credits_per_usd``). The balance
is derived from the ``cost_usd`` meter by :mod:`billing` — free plan (one-time
start grant, then a non-accumulating daily allowance) or a paid RevenueCat
tier (monthly pool, no daily limit). See ``billing`` for the arithmetic and the
grandfathering rule.

:func:`check` raises :class:`TokenCapExceeded` once the balance hits 0; a
daily reset, renewal or top-up clears it. Recording is best-effort and never raises.

**Real-money ledger** (founder request 2026-09-26: "I want to know exactly
how much did I spend in real money for each conversation even if those tokens
come free from Google"): alongside ``cost_usd``, every :func:`add` also

* accumulates ``token_usage.real_money_usd`` — a start-from-zero running
  dollar total that begins the moment this field ships (absent → 0), never a
  retro-estimate of lifetime spend; and
* appends one event to the capped ``users/{uid}/spend_events`` subcollection
  (ts, feature, model, input/output/total tokens, cost_usd, and the
  conversation ``session_id`` when the caller has one — the chat route and
  the voice worker both thread theirs through). :func:`spend_groups` folds
  those events into per-conversation groups for the Credits screen's "Real
  money" tab; :func:`_prune_spend_events` keeps the subcollection at
  ``SPEND_EVENTS_CAP`` docs.

The tab's Reset button (founder request, same day: "resets the tracker to
zero ... show all time and since last reset") is a marker, not a wipe — see
:func:`reset_real_money`.
"""

from __future__ import annotations

import logging
import math
import time
from datetime import datetime, timezone

import billing
import schema
from config import CONFIG, PLAN_FREE
from db import get_db

logger = logging.getLogger("ayma.tokens")

_FIELD = "token_usage"
_REAL_MONEY_FIELD = "real_money_usd"
# Reset-marker pair (founder request 2026-09-26: a Reset button on the Real
# money tab that "resets the tracker to zero" while still showing all time).
# real_money_usd keeps accumulating forever — that IS the all-time number —
# and a reset only stores when it happened plus a baseline snapshot of
# real_money_usd at that moment; "since last reset" = real_money_usd −
# baseline. Nothing in spend_events is ever deleted by a reset.
_REAL_MONEY_RESET_AT_FIELD = "real_money_reset_at"
_REAL_MONEY_BASELINE_FIELD = "real_money_reset_baseline"

# --- spend_events: the start-from-zero per-conversation real-money ledger ---
_SPEND_SUBCOLLECTION = "spend_events"
# Hard cap on stored events per user. Pruning waits for _SPEND_PRUNE_SLACK
# docs of overshoot before deleting back down to the cap, so the (count +
# delete-oldest) pass amortizes instead of running one delete per write.
SPEND_EVENTS_CAP = 500
_SPEND_PRUNE_SLACK = 50
# How many recent events one usage() call reads to build the group view.
_SPEND_FETCH_LIMIT = 400
# Most groups (conversations) the endpoint returns.
SPEND_GROUPS_CAP = 50

# Feature labels — keep stable, they surface in the client breakdown.
FEATURE_CHAT = "chat"
FEATURE_VOICE = "voice"
FEATURE_ICEBREAKERS = "icebreakers"
FEATURE_MATCHING = "matching"
FEATURE_WIKI = "wiki"
FEATURE_EXPLORE = "explore"  # natural-language Explore search parsing
FEATURE_REENGAGE = "reengage"  # Ayma's background check-in message
FEATURE_DEEPDIVE = "deepdive"  # web deep-dive research on a named person
FEATURE_FACE_REPORT = "face_report"  # honest facial-beauty analysis of a photo
FEATURE_BODY_REPORT = "body_report"  # honest physique analysis of a photo
FEATURE_PHYSICAL_ATTRS = "physical_attrs"  # structured physical-profile extraction
FEATURE_COMPLETENESS = "completeness"  # profile-completeness narrative coverage pass
FEATURE_SUMMARY = "summary"  # rolling conversation-summary maintenance (context_opt)
FEATURE_PERSONA_EVOLUTION = "persona_evolution"  # daily crowd feedback aggregation + eval gate (§15 Part B)
FEATURE_CAREER_TIMELINE = "career_timeline"  # structured career/education timeline extraction
FEATURE_PHOTO_EDIT = "photo_edit"  # edit_photo tool — Gemini image-edit model call
FEATURE_IMAGE_GEN = "image_gen"  # generate_image tool — same Gemini image model, no input photo required
FEATURE_PHOTO_MODERATION = "photo_moderation"  # profile/generated-photo safety check (record-only)
FEATURE_PHOTO_ATTRS = "photo_attrs"  # per-photo shot-type/attribute tagging (record-only)
FEATURE_PHOTO_CAPTION = "photo_caption"  # private photo-log caption (record-only)
FEATURE_DM_INGEST = "dm_ingest"  # DM voice transcription / photo caption for the wiki (record-only)
FEATURE_AI_NOTES = "ai_notes"  # Ayma's assessment (judgment) page generation (ai_assessment.py)

_CREDITS_ADDED_FIELD = "credits_added"  # top-of-doc int, bumped by top-ups


class TokenCapExceeded(RuntimeError):
    """Raised before a metered Gemini call when the user is out of credits."""


# Contexts for :func:`out_of_credits_message` — what the user was trying to do
# when a call site caught `TokenCapExceeded`, phrased as it slots into "so I
# can't {action} right now". Not the same list as the FEATURE_* billing
# buckets above: this is about wording a chat reply, not metering, so a
# context can span several features (e.g. "correction" covers both an
# appearance-finding edit and a deep-dive edit) or split one feature into two
# (deep-dive research vs. a deep-dive correction).
CONTEXT_BODY_REPORT = "body_report"
CONTEXT_FACE_REPORT = "face_report"
CONTEXT_DEEP_DIVE = "deep_dive"
CONTEXT_PHOTO_EDIT = "photo_edit"
CONTEXT_IMAGE_GEN = "image_gen"
CONTEXT_CORRECTION = "correction"
CONTEXT_CHAT = "chat"

_CONTEXT_ACTIONS: dict[str, str] = {
    CONTEXT_BODY_REPORT: "run a body report",
    CONTEXT_FACE_REPORT: "run a face report",
    CONTEXT_DEEP_DIVE: "run a web search",
    CONTEXT_PHOTO_EDIT: "generate an edited photo",
    CONTEXT_IMAGE_GEN: "generate an image",
    CONTEXT_CORRECTION: "make that change",
    CONTEXT_CHAT: "keep chatting",
}


def out_of_credits_message(context: str = CONTEXT_CHAT) -> str:
    """The one user-facing "out of credits" sentence, in Ayma's own
    first-person voice (mirrors the Flutter app's `kAymaOutOfCreditsMessage`
    in `widgets/out_of_credits.dart`, for surfaces that don't run through a
    skill). Every `except TokenCapExceeded:` block that replies to the user
    should build its copy here instead of hand-typing it, so the wording
    stays in exactly one place — `context` (one of the `CONTEXT_*` constants
    above) only changes what the user was trying to do, never the sentence
    shape. An unrecognized context still reads fine (falls back to "do that")
    rather than raising."""
    action = _CONTEXT_ACTIONS.get(context, "do that")
    return (
        f"I'm out of credits, so I can't {action} right now — reload on "
        "your profile to keep going."
    )


UPGRADE_MESSAGE = (
    "Reloading credits for free has ended — upgrade your plan to keep "
    "going. Your daily credits still refresh every day."
)
"""Shown when ``POST /credits/topup`` is disabled (paywall in force)."""


# Real Gemini API pricing, $ per 1,000,000 tokens — fetched from the official
# Gemini Developer API pricing page (https://ai.google.dev/gemini-api/docs/pricing)
# on 2026-09-16, cross-checked against web search results the same day. Only
# the three model ids this app actually calls (config.py's "LOCKED MODELS")
# are listed; an unlisted or unpriceable model contributes $0 rather than a
# guess — see :func:`cost_usd_for`.
_MODEL_PRICING: dict[str, dict[str, float | None]] = {
    # Text / wiki / matching / icebreakers / explore / reengage / deep-dive /
    # face+body report / physical-attrs / completeness / persona-evolution /
    # career-timeline — everything that calls gemini.generate_reply/_json/
    # research, all of which use CONFIG.gemini_model. Standard-tier,
    # introductory rate in effect through 2026-12-31 (rises to $1.50 / $7.50
    # on 2027-01-01 — revisit this table then).
    "gemini-3.7-flash": {"input": 0.75, "output": 3.75},
    # Gemini Live native-audio voice session (agent.py). The pricing page
    # splits text vs. audio/video rates; livekit's RealtimeModelMetrics
    # input_tokens/output_tokens are "each already inclusive of audio" (see
    # the commit that added the split) and every Ayma voice turn is audio
    # in/audio out, so the audio rate applies on both sides.
    "gemini-live-2.5-flash-native-audio": {"input": 3.00, "output": 12.00},
    # Gemini Live 3.8 (Developer API — what voice ACTUALLY runs when
    # GEMINI_LIVE_USE_DEV_API is on, the deployed configuration, since the
    # 2026-09-26 upgrade off the legacy 3.1 preview). Published audio-in/
    # audio-out token rates match the old ones: $3/M input, $12/M output.
    "gemini-3.8-live": {"input": 3.00, "output": 12.00},
    # Gemini Live 3.1 preview — the LEGACY Dev-API model voice ran before the
    # 3.8 upgrade, kept priced so the GEMINI_LIVE_DEV_MODEL rollback flip (and
    # historical rows) still cost correctly. Google published no
    # preview-specific price as of 2026-09-26, so the 2.5 native-audio audio
    # rates above are mirrored here — the closest real published rate.
    "gemini-3.1-flash-live-preview": {"input": 3.00, "output": 12.00},
    # Photo-edit ("Chat about it" -> edit_photo tool) and in-chat image
    # generation (generate_image tool) — same model. Official rates
    # (ai.google.dev/gemini-api/docs/pricing): input (text+image) $0.30/M
    # tokens, text output $2.50/M, **image output $30/M tokens** (a standard
    # image is 1290 output tokens = $0.039). Vertex/the SDK report image
    # output tokens separately in usage_metadata.candidates_tokens_details
    # (modality IMAGE); those are priced at "image_output", the rest of
    # candidates_token_count at "output". See :func:`image_output_share`.
    "gemini-2.5-flash-image": {
        "input": 0.30, "output": 2.50, "image_output": 30.00,
    },
}

# Calls that are deliberately NOT priced here (documented, not guessed):
#   * gemini-embedding-2 face/photo embeddings (media_embed.embed_image_bytes,
#     raw Vertex REST): the :embedContent response carries no usage metadata
#     in this app's call path and the repo cites no published image-embedding
#     rate, so these are unmetered (each costs a fraction of a cent).
#   * gemini-2.5-flash-preview-tts (voice_preview): platform-wide sample clips
#     generated at most once per voice preset and cached in Storage — not a
#     per-user spend, so no uid to charge.

# Implicit-cache discount on the input side. The published Gemini API pricing
# page (https://ai.google.dev/gemini-api/docs/pricing, checked 2026-09-27)
# bills cached input tokens ("context caching" price rows — implicit caching
# grants the same per-token discount automatically) at 10% of the model's
# normal input rate, i.e. 90% off, for the models this app runs (config.py
# LOCKED MODELS). Cached input tokens are a SUBSET of prompt/input tokens
# (usage_metadata.cached_content_token_count is included in
# prompt_token_count), so pricing splits the input side into
# fresh-at-full-rate + cached-at-this-factor — never an extra charge.
CACHED_INPUT_RATE_FACTOR = 0.10


def live_model_id() -> str:
    """The Gemini Live model id voice traffic ACTUALLY uses right now — the
    Developer-API model (``gemini-3.8-live``, or whatever
    ``GEMINI_LIVE_DEV_MODEL`` overrides it to) when ``GEMINI_LIVE_USE_DEV_API``
    is on (the deployed configuration), else the Vertex native-audio model. The one
    source of truth ``agent.build_realtime_model`` and the ledger share, so
    the ledger can never again price voice against a model it isn't running
    (the pre-2026-09-26 accuracy bug: voice was always priced as
    ``gemini-live-2.5-flash-native-audio`` while real traffic ran
    ``gemini-3.1-flash-live-preview``)."""
    return (
        CONFIG.gemini_live_dev_model
        if CONFIG.gemini_live_use_dev_api
        else CONFIG.gemini_live_model
    )


def _model_for_feature(feature: str) -> str:
    """Which LOCKED model (config.py) a usage-ledger ``feature`` bucket was
    actually billed against — the fallback when the caller didn't thread the
    actual model through (see :func:`add`). Every feature except voice,
    photo_edit and image_gen routes through gemini.generate_reply/_json/
    research, which all call ``CONFIG.gemini_model``."""
    if feature == FEATURE_VOICE:
        return live_model_id()
    if feature in (FEATURE_PHOTO_EDIT, FEATURE_IMAGE_GEN):
        return CONFIG.gemini_image_edit_model
    return CONFIG.gemini_model


def cost_usd_for(
    feature: str,
    input_tokens: int,
    output_tokens: int,
    *,
    cached_input_tokens: int = 0,
    model: str | None = None,
    image_output_tokens: int = 0,
) -> float:
    """Real-dollar cost of one recorded call, from :data:`_MODEL_PRICING`.
    ``0.0`` whenever the model isn't in the pricing table, its input/output
    rate isn't known, or the
    token count is 0/absent — never an estimate. ``model`` is the ACTUAL model
    the call ran against, threaded through from the caller; when omitted it
    falls back to :func:`_model_for_feature`'s per-feature mapping.
    ``cached_input_tokens`` is the implicit-cache-hit SUBSET of
    ``input_tokens`` (clamped into ``[0, input_tokens]`` defensively): those
    tokens are billed at :data:`CACHED_INPUT_RATE_FACTOR` × the input rate
    instead of the full rate, so real-money figures reflect the actual
    caching savings. ``0`` (the default) prices exactly as before. Used by
    both :func:`add` (text/vision path) and the voice worker's
    ``relay_token_usage`` (``agent.py``), so pricing lives in exactly one
    place."""
    price = _MODEL_PRICING.get(model or _model_for_feature(feature))
    if not price:
        return 0.0
    cost = 0.0
    in_rate = price.get("input")
    out_rate = price.get("output")
    if input_tokens > 0 and in_rate is not None:
        cached = min(max(int(cached_input_tokens or 0), 0), input_tokens)
        fresh = input_tokens - cached
        cost += (fresh / 1_000_000) * in_rate
        cost += (cached / 1_000_000) * in_rate * CACHED_INPUT_RATE_FACTOR
    img_rate = price.get("image_output")
    image_out = 0
    if img_rate is not None:
        image_out = min(max(int(image_output_tokens or 0), 0), max(output_tokens, 0))
        cost += (image_out / 1_000_000) * img_rate
    rest = output_tokens - image_out
    if rest > 0 and out_rate is not None:
        cost += (rest / 1_000_000) * out_rate
    return cost


def image_output_share(response, model: str, output_tokens: int) -> int:
    """Image-modality share of ``output_tokens`` for a response from an
    image-capable ``model`` (0 for models without an ``image_output`` rate).
    Read from ``usage_metadata.candidates_tokens_details`` (modality IMAGE);
    when the response carries no modality breakdown the whole output is priced
    at the image rate — the conservative choice, since an image-model call's
    output is overwhelmingly image tokens."""
    price = _MODEL_PRICING.get(model) or {}
    if price.get("image_output") is None or output_tokens <= 0:
        return 0
    meta = getattr(response, "usage_metadata", None)
    details = getattr(meta, "candidates_tokens_details", None)
    if not details:
        return output_tokens
    total = 0
    for d in details:
        modality = str(getattr(d, "modality", "") or "").upper()
        if modality.endswith("IMAGE"):
            total += int(getattr(d, "token_count", 0) or 0)
    return min(total, output_tokens)


def _usage_from_response(response) -> tuple[int, int, int, int]:
    """``(input_tokens, output_tokens, total_tokens, cached_input_tokens)``
    for one ``google-genai`` response (all 0 if unavailable). ``input``/
    ``output`` come straight from ``usage_metadata.prompt_token_count`` /
    ``candidates_token_count`` — the exact attribute names on this SDK's
    ``GenerateContentResponseUsageMetadata``. ``total`` prefers the SDK's own
    ``total_token_count`` (unchanged from before — this is still what credit
    charging uses); it can be larger than ``input + output`` since it also
    folds in thinking/tool-use tokens that this split doesn't break out.
    ``cached_input_tokens`` is ``usage_metadata.cached_content_token_count``
    (0 when absent/None — a call with no cache hit reports neither) — the
    implicit-prompt-cache-hit portion of ``input_tokens``, a subset of it,
    never additional tokens."""
    meta = getattr(response, "usage_metadata", None)
    if meta is None:
        return 0, 0, 0, 0
    input_tokens = int(getattr(meta, "prompt_token_count", 0) or 0)
    output_tokens = int(getattr(meta, "candidates_token_count", 0) or 0)
    total = getattr(meta, "total_token_count", None)
    total_tokens = int(total) if total is not None else input_tokens + output_tokens
    cached_input = max(0, int(getattr(meta, "cached_content_token_count", 0) or 0))
    return input_tokens, output_tokens, total_tokens, cached_input


def _prune_spend_events(events_col) -> None:
    """Keep ``users/{uid}/spend_events`` at ``SPEND_EVENTS_CAP`` docs. Cheap
    on the hot path: one count aggregation per write, and the delete-oldest
    pass only runs once the collection has overshot the cap by
    ``_SPEND_PRUNE_SLACK`` (then trims back down to exactly the cap)."""
    agg = events_col.count().get()
    first = agg[0]
    if isinstance(first, (list, tuple)):
        first = first[0]
    n = int(first.value)
    if n <= SPEND_EVENTS_CAP + _SPEND_PRUNE_SLACK:
        return
    for snap in events_col.order_by("ts").limit(n - SPEND_EVENTS_CAP).stream():
        snap.reference.delete()


def add(
    uid: str,
    feature: str,
    tokens: int,
    *,
    input_tokens: int = 0,
    output_tokens: int = 0,
    cached_input: int = 0,
    model: str | None = None,
    session_id: str | None = None,
    image_output_tokens: int = 0,
) -> None:
    """Add ``tokens`` to the user's total and the per-feature bucket. ``tokens``
    still drives the credit cap exactly as before; ``input_tokens``/
    ``output_tokens`` are additive accounting-only fields for cost audits
    (PLAN.md F1/F2) and never affect what a call costs the user.
    ``cached_input`` is the implicit-prompt-cache-hit SUBSET of
    ``input_tokens`` (Gemini's ``cached_content_token_count``) — accounting
    only like the input/output split, but it also discounts the real-dollar
    cost (see :func:`cost_usd_for`); 0 (no hit / a caller that doesn't
    measure it, e.g. the voice worker) leaves every figure exactly as before.
    ``model`` is
    the ACTUAL model the recorded call ran against — threaded through from the
    caller so ``cost_usd`` is priced truthfully even when a feature can run on
    more than one model (voice: Vertex vs. Developer-API Live); omitted, the
    per-feature mapping applies as before. ``session_id`` is the conversation
    this call belongs to (a chat ``s-…`` session or a LiveKit voice room id)
    when the caller knows it — it groups the spend event written here into a
    per-conversation row on the Credits screen's "Real money" tab; without it
    the event falls back to calendar-day grouping."""
    if not uid or tokens <= 0:
        return
    try:
        from firebase_admin import firestore

        payload = {
            "total": firestore.Increment(tokens),
            "features": {feature: firestore.Increment(tokens)},
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if input_tokens > 0:
            payload["input"] = firestore.Increment(input_tokens)
        if output_tokens > 0:
            payload["output"] = firestore.Increment(output_tokens)
        if cached_input > 0:
            # Implicit-cache hit verification: lifetime total + per-feature
            # split of the cached portion of `input` (a subset, see the
            # module docstring). Absent until the first observed hit.
            payload["cached_input"] = firestore.Increment(cached_input)
            payload["cached_features"] = {
                feature: firestore.Increment(cached_input)
            }
        cost = cost_usd_for(
            feature, input_tokens, output_tokens,
            cached_input_tokens=cached_input, model=model,
            image_output_tokens=image_output_tokens,
        )
        if cost > 0:
            payload["cost_usd"] = firestore.Increment(cost)
            # Start-from-zero real-money total (founder request 2026-09-26).
            # Same Increment write as cost_usd, but the field starts absent
            # today — so unlike cost_usd it carries no pre-tracking history.
            payload[_REAL_MONEY_FIELD] = firestore.Increment(cost)
        user_ref = get_db().collection("users").document(uid)
        user_ref.set({_FIELD: payload}, merge=True)
        # Per-event spend record — one doc per recorded call (voice: one per
        # Live turn), so the Credits screen can show real dollars per
        # conversation. Client-side UTC timestamp (not SERVER_TIMESTAMP) so
        # the event is orderable the instant it's written.
        event = {
            "ts": datetime.now(timezone.utc),
            "feature": feature,
            "model": model or _model_for_feature(feature),
            "input": input_tokens,
            "output": output_tokens,
            # The implicit-cache-hit subset of `input` — 0 when the call had
            # no hit (or the caller doesn't measure it, e.g. voice).
            "cached_input": cached_input,
            "total": tokens,
            "cost_usd": cost,
        }
        if image_output_tokens > 0:
            event["image_output"] = image_output_tokens
        if session_id:
            event["session_id"] = str(session_id)
        events_col = user_ref.collection(_SPEND_SUBCOLLECTION)
        events_col.add(event)
        _prune_spend_events(events_col)
        # Exact per-call record on the success path — mirrors agent.py's
        # "voice-usage turn uid=... in=... out=... total=..." line (same
        # field names) so a future grep/analysis script can treat every
        # feature (voice included) uniformly. Numbers only, no content/PII.
        # `cached=` is the implicit-cache-hit subset of `in=` — grep it to
        # verify the byte-stable chat prefix is actually hitting the cache.
        logger.info(
            "token-usage add uid=%s feature=%s model=%s in=%d out=%d "
            "cached=%d total=%d",
            uid, feature, model or _model_for_feature(feature),
            input_tokens, output_tokens, cached_input, tokens,
        )
    except Exception:  # noqa: BLE001 - metering must never break a request
        logger.exception("token add failed for %s/%s", uid, feature)


def record(
    uid: str | None,
    feature: str,
    response,
    *,
    model: str | None = None,
    session_id: str | None = None,
) -> None:
    """Extract the token count from a ``google-genai`` response and add it,
    along with the input/output split for cost audits and the implicit-cache
    hit count (``cached_content_token_count``, 0 when absent). ``model`` is
    the actual model the response came from; ``session_id`` the conversation
    it belongs to, when the caller has one (see :func:`add`)."""
    if not uid:
        return
    input_tokens, output_tokens, total_tokens, cached_input = (
        _usage_from_response(response)
    )
    actual_model = model or _model_for_feature(feature)
    add(
        uid, feature, total_tokens,
        input_tokens=input_tokens, output_tokens=output_tokens,
        cached_input=cached_input,
        model=model, session_id=session_id,
        image_output_tokens=image_output_share(
            response, actual_model, output_tokens
        ),
    )


def _parse(data: dict) -> dict:
    """The ``_read``-shaped view of an already-fetched ``users/{uid}`` doc.
    Factored out so a caller that already has the doc (e.g. the admin
    finance-summary bounded scan, ``admin.finance_summary``) can reuse the
    exact same accounting without a second Firestore read per user."""
    u = data.get(_FIELD) or {}
    reset_at = u.get(_REAL_MONEY_RESET_AT_FIELD)
    return {
        "total": int(u.get("total", 0) or 0),
        # Input/output split — accounting only, see module docstring; never
        # read by _credit_view.
        "input": int(u.get("input", 0) or 0),
        "output": int(u.get("output", 0) or 0),
        # Implicit-cache hits: the cached subset of `input`, lifetime + per
        # feature — accounting only, absent (-> 0/{}) until the first hit.
        "cached_input": int(u.get("cached_input", 0) or 0),
        "cached_features": {
            k: int(v) for k, v in (u.get("cached_features") or {}).items()
        },
        "cost_usd": float(u.get("cost_usd", 0) or 0),
        # Start-from-zero real-money total — absent until the first priced
        # call recorded after this field shipped (2026-09-26), read as 0.
        "real_money_usd": float(u.get(_REAL_MONEY_FIELD, 0) or 0),
        # Reset marker (see :func:`reset_real_money`): baseline snapshot of
        # real_money_usd at the last reset (never reset -> 0, i.e. "since
        # last reset" equals all-time) and when it happened (ISO, or None).
        "real_money_reset_baseline": float(
            u.get(_REAL_MONEY_BASELINE_FIELD, 0) or 0
        ),
        "real_money_reset_at": (
            reset_at.isoformat() if hasattr(reset_at, "isoformat") else None
        ),
        "features": {k: int(v) for k, v in (u.get("features") or {}).items()},
    }


_UNVERIFIED_RECHECK_SECONDS = 60
_pending_until: dict[str, float] = {}
_DUPLICATE_NEIGHBOURS = 5

GRANT_OK = "ok"
GRANT_PENDING = "pending"
GRANT_DUPLICATE = "duplicate"


def _contact_verified(uid: str) -> bool:
    """Whether the Firebase account has a verified phone number or a verified
    email (Google/Apple/email-link sign-ins are verified; anonymous, custom
    token and unconfirmed-email accounts are not). A failed lookup counts as
    unverified (re-checked later)."""
    try:
        from firebase_admin import auth as firebase_auth

        user = firebase_auth.get_user(uid)
        return bool(user.phone_number) or (
            bool(user.email) and bool(user.email_verified)
        )
    except Exception:  # noqa: BLE001 - fail closed, retry on a later read
        logger.exception("verification lookup failed for %s", uid)
        return False


def _is_duplicate_face(db, uid: str, embedding: list[float]) -> bool:
    """True when another account that already holds the start grant has a
    verification-selfie embedding at or above the same-person cosine
    threshold used by the deep-dive face check
    (``deep_dive_images._VERIFY_THRESHOLD``). Uses a native COSINE
    ``find_nearest`` over ``users.face_verification.embedding`` (needs the
    vector index in ``firestore.indexes.json``). A failed query fails closed
    (grant withheld, retried on a later read)."""
    import deep_dive_images
    from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
    from google.cloud.firestore_v1.vector import Vector

    field = f"{schema.FIELD_FACE_VERIFICATION}.{schema.FACE_VERIFICATION_EMBEDDING}"
    query = db.collection("users").find_nearest(
        vector_field=field,
        query_vector=Vector(embedding),
        distance_measure=DistanceMeasure.COSINE,
        limit=_DUPLICATE_NEIGHBOURS + 1,
    )
    for snap in query.stream():
        if snap.id == uid:
            continue
        other = snap.to_dict() or {}
        if (other.get("billing") or {}).get("start_grant_unlocked") is False:
            continue  # holds no grant -> not the original
        vec = deep_dive_images._vec_from_raw(
            (other.get(schema.FIELD_FACE_VERIFICATION) or {}).get(
                schema.FACE_VERIFICATION_EMBEDDING
            )
        )
        if vec and (
            deep_dive_images._cosine(embedding, vec)
            >= deep_dive_images._VERIFY_THRESHOLD
        ):
            logger.warning(
                "start grant withheld for %s: selfie matches account %s",
                uid, snap.id,
            )
            return True
    return False


def _grant_status(uid: str, data: dict) -> str:
    """Whether the one-time start grant may be unlocked for ``uid``:
    ``GRANT_OK`` only when the account has (1) a verified phone/email on its
    Firebase record, (2) a completed verification selfie
    (``users/{uid}.face_verification.embedding``) and (3) a selfie that does
    not match another grant-holding account (``GRANT_DUPLICATE``, permanent).
    ``GRANT_PENDING`` otherwise (re-checked, negatives cached briefly so a
    locked account doesn't cost a Firebase call per metered request).

    Limits, stated honestly: this is evidence the client-side selfie flow
    ran, plus a same-face dedupe. It is NOT liveness detection — a printed or
    screen photo, or a different photo of the same person that scores under
    the threshold, can still pass; an attacker with a second real face or
    heavy edits is not stopped. It raises the cost of farming the grant; it
    does not eliminate it."""
    now = time.monotonic()
    if _pending_until.get(uid, 0.0) > now:
        return GRANT_PENDING
    status = GRANT_PENDING
    try:
        from deep_dive_images import _vec_from_raw

        embedding = _vec_from_raw(
            (data.get(schema.FIELD_FACE_VERIFICATION) or {}).get(
                schema.FACE_VERIFICATION_EMBEDDING
            )
        )
        if embedding and _contact_verified(uid):
            status = (
                GRANT_DUPLICATE
                if _is_duplicate_face(get_db(), uid, embedding)
                else GRANT_OK
            )
    except Exception:  # noqa: BLE001 - fail closed, retry on a later read
        logger.exception("start-grant eligibility check failed for %s", uid)
    if status == GRANT_PENDING:
        _pending_until[uid] = now + _UNVERIFIED_RECHECK_SECONDS
    else:
        _pending_until.pop(uid, None)
    return status


def _load(uid: str) -> tuple[dict, dict]:
    """``(raw user doc, normalised billing map)`` — persists lazy billing
    init / paid-expiry settlement / the daily-allowance day rollover when they
    changed, so the next read starts from the settled state."""
    ref = get_db().collection("users").document(uid)
    snap = ref.get()
    data = (snap.to_dict() or {}) if snap.exists else {}
    status = (
        _grant_status(uid, data) if billing.needs_verification(data) else None
    )
    b, changed = billing.normalize(
        data, datetime.now(timezone.utc), CONFIG, status in (None, GRANT_OK)
    )
    if status == GRANT_DUPLICATE and not b.get("start_grant_blocked"):
        b["start_grant_blocked"] = True
        changed = True
    if changed and snap.exists:
        ref.set({"billing": b}, merge=True)
    return data, b


def _read(uid: str) -> dict:
    snap = get_db().collection("users").document(uid).get()
    data = (snap.to_dict() or {}) if snap.exists else {}
    return _parse(data)


def summary_from_doc(uid: str, data: dict) -> dict:
    """``{uid, total_tokens, cost_usd, credits_used}`` for an already-fetched
    ``users/{uid}`` doc — the same total/cost_usd math :func:`usage`
    computes for one user, reused by the admin finance-summary aggregate
    (``admin.finance_summary``) across its bounded scan so it doesn't issue a
    second Firestore read per user just to get numbers it already has.
    ``credits_used`` stays the legacy token-based display figure (admin only)."""
    u = _parse(data)
    return {
        "uid": uid,
        "total_tokens": u["total"],
        "cost_usd": round(u["cost_usd"], 6),
        "credits_used": _ceil_div(u["total"], max(1, CONFIG.tokens_per_credit)),
    }


def _ceil_div(n: int, d: int) -> int:
    return -(-n // d) if d > 0 else 0


def _credit_view(data: dict, b: dict) -> dict:
    """Client-facing credits (never dollars): the legacy
    ``{grant, added, used, remaining}`` quartet plus ``plan``,
    ``plan_credits``, ``daily_credits_remaining`` and ``period_end``.
    ``grant`` is the pool currently being drawn (paid pool; free start grant,
    or the daily allowance once the start grant is spent) and
    ``used = grant + added - remaining``."""
    bal = billing.balance(data, b, CONFIG)
    to_cr = lambda usd: billing.credits_for(usd, CONFIG)  # noqa: E731
    remaining = to_cr(bal["remaining_usd"])
    plan_credits = to_cr(bal["plan_pool_usd"])
    added = 0
    if bal["plan"] == PLAN_FREE:
        added = int(data.get(_CREDITS_ADDED_FIELD, 0) or 0)
        if bal["start_remaining_usd"] > 0:
            grant = plan_credits
        else:
            grant, added = to_cr(CONFIG.free_daily_allowance_usd), 0
    else:
        grant = plan_credits
    end = b.get("period_end")
    is_trial = bal["plan"] != PLAN_FREE and bool(b.get("is_trial"))
    return {
        "grant": grant,
        "added": added,
        "used": max(0, grant + added - remaining),
        "remaining": remaining,
        "plan": bal["plan"],
        "plan_credits": plan_credits,
        "daily_credits_remaining": to_cr(bal["daily_remaining_usd"]),
        "period_end": end.isoformat() if hasattr(end, "isoformat") else None,
        "is_trial": is_trial,
        "trial_end": (
            end.isoformat() if is_trial and hasattr(end, "isoformat") else None
        ),
    }


def topup(uid: str, amount: int) -> dict:
    """Reload the free-plan balance so the user has **at least ``amount``
    usable credits** afterwards (forgiving any overspend first). Free for now
    — no payment. Best-effort; returns the fresh credit view."""
    if not uid or amount <= 0:
        return credits(uid) if uid else {}
    try:
        from firebase_admin import firestore

        data, b = _load(uid)
        if b.get("plan") == PLAN_FREE:
            bal = billing.balance(data, b, CONFIG)
            cpu = max(1, CONFIG.credits_per_usd)
            base = bal["plan_pool_usd"]
            target_pool = max(bal["pool_usd"], bal["free_spend_usd"]) + amount / cpu
            new_added = max(
                int(data.get(_CREDITS_ADDED_FIELD, 0) or 0),
                math.ceil((target_pool - base) * cpu - 1e-6),
            )
            get_db().collection("users").document(uid).set(
                {
                    _CREDITS_ADDED_FIELD: int(new_added),
                    "credits_updated_at": firestore.SERVER_TIMESTAMP,
                },
                merge=True,
            )
    except Exception:  # noqa: BLE001 - a failed top-up must not 500 the request
        logger.exception("credit top-up failed for %s (+%s)", uid, amount)
    return credits(uid)


def credits(uid: str) -> dict:
    """The user-facing credit view (see :func:`_credit_view`)."""
    return _credit_view(*_load(uid))


def check(uid: str | None) -> None:
    """Raise :class:`TokenCapExceeded` when the user has no credits left
    (free: start grant + today's allowance spent; paid: monthly pool spent).
    A daily reset, renewal or top-up clears it."""
    if not uid:
        return
    try:
        data, b = _load(uid)
        bal = billing.balance(data, b, CONFIG)
    except Exception:  # noqa: BLE001
        logger.exception("credit check read failed for %s", uid)
        return
    if bal["remaining_usd"] <= 1e-9:
        raise TokenCapExceeded(f"out of credits (uid={uid})")


def spend_groups(uid: str) -> list[dict]:
    """Recent real-money spend folded into per-conversation groups, newest
    first, at most ``SPEND_GROUPS_CAP`` — the Credits screen's "Real money"
    list. Reads the last ``_SPEND_FETCH_LIMIT`` events of
    ``users/{uid}/spend_events`` and groups them by their ``session_id``
    (voice = one LiveKit room, text = one chat ``s-…`` session — the same key
    ``raw_turns`` persists under); events recorded with no session (background
    work whose trigger wasn't a conversation) fall back to one group per UTC
    calendar day. Best-effort: an unreadable subcollection yields ``[]``,
    never an error."""
    if not uid:
        return []
    try:
        from firebase_admin import firestore

        events_col = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(_SPEND_SUBCOLLECTION)
        )
        snaps = list(
            events_col.order_by("ts", direction=firestore.Query.DESCENDING)
            .limit(_SPEND_FETCH_LIMIT)
            .stream()
        )
    except Exception:  # noqa: BLE001 - the credits screen must still load
        logger.exception("spend_events read failed for %s", uid)
        return []

    groups: dict[str, dict] = {}
    for snap in snaps:  # newest first — insertion order = display order
        d = snap.to_dict() or {}
        ts = d.get("ts")
        day = ts.strftime("%Y-%m-%d") if hasattr(ts, "strftime") else ""
        iso = ts.isoformat() if hasattr(ts, "isoformat") else ""
        sid = str(d.get("session_id") or "")
        key = sid or f"day:{day or 'unknown'}"
        g = groups.get(key)
        if g is None:
            g = groups[key] = {
                "id": key,
                "session_id": sid,
                "day": day,
                "first_ts": iso,
                "last_ts": iso,  # first event seen is the group's newest
                "events": 0,
                "cost_usd": 0.0,
                # Implicit-cache-hit tokens summed across the group's events
                # (pre-cache-tracking events have no field -> contribute 0),
                # so the app can later show how much of a conversation's
                # input was served from cache.
                "cached_input": 0,
                "features": {},
            }
        g["first_ts"] = iso or g["first_ts"]  # keeps sliding to the oldest
        g["day"] = g["day"] or day
        g["events"] += 1
        g["cached_input"] += int(d.get("cached_input", 0) or 0)
        feature = str(d.get("feature") or "misc")
        cost = float(d.get("cost_usd", 0) or 0)
        g["cost_usd"] += cost
        g["features"][feature] = g["features"].get(feature, 0.0) + cost

    out: list[dict] = []
    for g in list(groups.values())[:SPEND_GROUPS_CAP]:
        feats = g["features"]
        if FEATURE_VOICE in feats:
            kind = "voice"
        elif FEATURE_CHAT in feats:
            kind = "chat"
        else:
            kind = "background"
        out.append({
            **g,
            "kind": kind,
            "cost_usd": round(g["cost_usd"], 6),
            "features": {k: round(v, 6) for k, v in feats.items()},
        })
    return out


def reset_real_money(uid: str) -> dict:
    """Reset the Real money tab's "since last reset" tracker to $0.00
    (founder request 2026-09-26: "That resets the tracker to zero. It should
    show all time and since last reset"). Nothing is deleted: the running
    ``real_money_usd`` total keeps accumulating forever (that IS the all-time
    figure) and ``spend_events`` history stays intact — a reset only stamps
    ``token_usage.real_money_reset_at`` (server timestamp) and snapshots
    ``real_money_reset_baseline`` = the current ``real_money_usd``, so
    "since last reset" (= total − baseline) starts over from zero. Repeatable;
    best-effort like :func:`topup`; returns the fresh :func:`usage` view."""
    if not uid:
        return {}
    try:
        from firebase_admin import firestore

        baseline = _read(uid)["real_money_usd"]
        get_db().collection("users").document(uid).set(
            {
                _FIELD: {
                    _REAL_MONEY_RESET_AT_FIELD: firestore.SERVER_TIMESTAMP,
                    _REAL_MONEY_BASELINE_FIELD: float(baseline),
                }
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001 - a failed reset must not 500 the request
        logger.exception("real-money reset failed for %s", uid)
    return usage(uid, include_dollars=True)


def usage(uid: str, *, include_dollars: bool = False) -> dict:
    """The client-facing view: raw lifetime token accounting (total + a
    per-feature breakdown across chat / voice / matching / wiki / explore /
    reengage) plus the derived credit balance and per-action credit costs.
    ``input``/``output`` are the lifetime prompt/candidates split for cost
    audits (PLAN.md F1/F2) — accounting only, not used by ``credits``.
    ``cost_usd`` is the real infrastructure $ this drove, distinct from and
    never conflated with the credit balance — see the module docstring.
    The real-money trio + ``spend_groups`` feed the Credits screen's "Real
    money" tab: ``real_money_all_time_usd`` is the start-from-zero running
    dollar total, ``real_money_since_reset_usd`` is that total minus the
    baseline stamped by the last :func:`reset_real_money` (never reset →
    equals all-time), ``real_money_reset_at`` is the last reset's ISO
    timestamp (or ``None``), and ``spend_groups`` is the recent
    per-conversation breakdown (see :func:`spend_groups` — rows are history
    and deliberately survive a reset). The legacy ``real_money_usd`` key
    carries the since-reset value so pre-reset-button clients show the reset
    working too.

    End users only ever see credits: ``cost_usd``, the ``real_money_*`` keys
    and ``spend_groups`` (which carries per-conversation ``cost_usd``) are
    included only when ``include_dollars`` is true — set by the admin-claim
    ``GET /usage`` path and the ``/admin/users/{uid}/credits`` inspector.
    """
    u = _read(uid)
    cred = credits(uid)
    all_time = round(u["real_money_usd"], 6)
    since_reset = round(
        max(0.0, u["real_money_usd"] - u["real_money_reset_baseline"]), 6
    )
    view = {
        "total": u["total"],
        "input": u["input"],
        "output": u["output"],
        # Implicit-cache hit accounting (lifetime + per feature) — lets the
        # app surface cache savings later; 0/{} until the first observed hit.
        "cached_input": u["cached_input"],
        "cached_features": u["cached_features"],
        "features": u["features"],
        "credits": cred,
        "plan": cred["plan"],
        "daily_credits_remaining": cred["daily_credits_remaining"],
        "period_end": cred["period_end"],
        "is_trial": cred["is_trial"],
        "trial_end": cred["trial_end"],
        "tokens_per_credit": max(1, CONFIG.tokens_per_credit),
    }
    if include_dollars:
        view.update({
            "cost_usd": round(u["cost_usd"], 6),
            "real_money_usd": since_reset,  # legacy alias, kept for older clients
            "real_money_all_time_usd": all_time,
            "real_money_since_reset_usd": since_reset,
            "real_money_reset_at": u["real_money_reset_at"],
            "spend_groups": spend_groups(uid),
        })
    return view
