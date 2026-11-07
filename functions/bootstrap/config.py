"""Central configuration for the Ayma Main API.

Per ``AGENTS.md``:

* This is the **only** module allowed to define model names. Every Gemini model
  string must flow from here; if a model name is needed and this module has not
  provided it, the caller throws rather than substituting a default.
* Every rate-limit (``RATE_*``) and tuning threshold constant lives here,
  sourced from environment variables (real env in deployment, ``.env.local``
  locally). Nothing here hardcodes a secret — secret *values* are read from the
  environment at their use sites, never stored in the repo.

Step 1 scaffolding: only the values the health check needs. Model names and
``RATE_*`` entries are added in the steps that introduce the endpoints using
them (see ``PLAN.md``).
"""

from __future__ import annotations

import os
from dataclasses import dataclass


PLAN_FREE = "free"


@dataclass(frozen=True)
class PlanTier:
    """One paid RevenueCat subscription tier. ``pool_usd`` is the USD of real
    token cost granted per billing period (internal — clients only ever see
    the credit equivalent). ``price_usd`` is the subscription price."""

    plan_id: str
    product_id: str
    price_usd: int
    pool_usd: float


PLAN_TIERS: dict[str, PlanTier] = {
    "plus": PlanTier("plus", "ayma_plus_monthly", 10, 7.0),
    "pro": PlanTier("pro", "ayma_pro_monthly", 20, 14.0),
    "max": PlanTier("max", "ayma_max_monthly", 100, 80.0),
}
PRODUCT_TO_PLAN: dict[str, str] = {t.product_id: k for k, t in PLAN_TIERS.items()}


@dataclass(frozen=True)
class Config:
    """Immutable snapshot of non-secret runtime configuration."""

    project_id: str
    """GCP / Firebase project id. Empty string if unset (local, no env)."""

    version: str
    """App version string, surfaced by the health check."""

    cap_marketing_turns: int
    """Pre-signup marketing turn cap (§3.3). At the cap Ayma nudges toward
    "get started" once, then refuses further marketing turns."""

    cap_interview_turns: int
    """Preboarding interview turn cap (§3.3). At the cap the client falls back
    to a plain manual form for any unfilled fields."""

    rate_bootstrap: str
    rate_chat_text: str
    """Per-endpoint rate limits (§10.4 — every endpoint has a ``RATE_*``).
    Format ``<n>/<window>`` (e.g. ``30/minute``). Enforcement middleware is
    Step 67; these values exist now so no endpoint ships without one."""

    rate_chat_history: str
    """Rate limit for ``GET /chat/history`` — the transcript read. Kept separate
    from (and more generous than) ``rate_chat_text`` so opening the Ayma tab /
    paging older messages never burns the send-a-message allowance (§10.4)."""

    rate_cron_lint: str
    """Rate limit for ``POST /cron/lint`` (§10.4)."""

    rate_media: str
    """Rate limit for ``POST /media`` (§10.4)."""

    rate_account: str
    """Rate limit for ``POST /account/*`` (§10.4)."""

    rate_cron_purge: str
    """Rate limit for ``POST /cron/purge-deleted`` (§10.4)."""

    account_recovery_days: int
    """Days a soft-deleted account stays recoverable before the purge (§3.6)."""

    match_candidate_pool: int
    """Max candidates Pass 1 sources per user (§5.2)."""

    cron_candidate_pool: int
    cron_score_top_k: int
    """Lighter pools for the scheduled two-pass matching cron (§5.3)."""

    rate_matching: str
    """Rate limit for ``POST /run-matching`` / ``/check-compatibility`` (§10.4)."""

    cron_secret: str
    """Shared secret every ``/cron/*`` route checks against the ``X-Cron-Secret``
    header (§10.5). Empty locally unless set; in deployment it comes from Secret
    Manager (§12.3). An unset value makes ``/cron/*`` refuse every request."""

    dev_view_emails: tuple[str, ...]
    """Verified-email allowlist for the app's founder-only "Dev view" (USD
    usage figures + free reload). Env ``DEV_VIEW_EMAILS`` (comma-separated),
    default: the founder's account. Enforced server-side on every dev route."""

    dev_view_uids: tuple[str, ...]
    """Firebase-uid allowlist for the Dev view. Env ``DEV_VIEW_UIDS``
    (comma-separated), default empty."""

    test_bypass_emails: tuple[str, ...]
    """Demo/judge accounts whose Firebase email need NOT be verified to clear
    the free start-grant contact check (``start_grant.contact_verified``).
    Ayma has no hard email-verification wall; this is the one privilege gate
    that reads ``email_verified``, so the allowlist is scoped to exactly these
    emails and every other account is still gated. Env ``TEST_BYPASS_EMAILS``
    (comma-separated), default: the three public hackathon demo logins
    (``docs/DEMO_ACCOUNTS.md``). Not a secret."""

    all_flags_on_uids: tuple[str, ...]
    # Viewer uids for whom seeded test-fixture hiding in Explore is disabled
    # (e2e/demo viewers). Real users never match, so they always get fixtures hidden.
    explore_fixture_bypass_uids: tuple[str, ...]
    """Firebase uids for which every boolean feature flag resolves ON, honored
    inside ``feature_flags.resolve(name, uid=...)`` without flipping any global
    flag. Scoped to the demo/judge accounts so they can exercise every feature.
    Env ``ALL_FLAGS_ON_UIDS`` (comma-separated), default: the three demo uids
    (``docs/DEMO_ACCOUNTS.md``). Not a secret."""

    dev_panel_password: str
    """Password ``POST /dev/verify`` checks before unlocking the app's
    Developer panel. From Secret Manager (``DEV_PANEL_PASSWORD``) in
    deployment; an unset value makes the endpoint refuse every unlock."""

    admin_password: str
    """Password the ``/admin/*`` console checks against the ``X-Admin-Password``
    header (§14.3). From Secret Manager in deployment (§12.3); an unset value
    makes every ``/admin/*`` route refuse."""

    mcp_server: bool
    """Master switch for the Ayma MCP server (``docs/MCP_SERVER.md``). Default
    OFF — merging the MCP code exposes nothing until this is flipped on (env
    ``MCP_SERVER`` / the ``mcp_server`` feature flag). When off, every ``/mcp``
    request answers 503. Needs no secret: MCP access tokens are opaque and
    validated by a Firestore lookup, not signed."""

    mcp_token_ttl_days: int
    """Lifetime of an issued MCP access token in days (``MCP_TOKEN_TTL_DAYS``,
    default 30). A token is revocable at any time regardless of this."""

    rate_mcp: str
    """Per-client rate limit on the whole ``/mcp`` surface (the OAuth endpoints
    and the MCP endpoint). Per-token limiting is additionally enforced inside
    the MCP auth wrapper. ``RATE_MCP``."""

    # ---------------------------------------------------------------- #
    # LOCKED MODELS — do not change any of the four model ids or their
    # three locations below without an explicit, written instruction from
    # the project owner. They were chosen and verified together on
    # 2026-08-30 (grounded against the live Vertex / Gemini APIs):
    #
    #   text / wiki / matching / icebreakers
    #       gemini-3.7-flash            @ Vertex location "global"
    #       (3.x flash is Vertex-global-only — 404 in us-central1)
    #   photo / face embeddings
    #       gemini-embedding-2         @ Vertex location "global"  (3072-d)
    #   voice agent (LiveKit worker)
    #       gemini-live-2.5-flash-native-audio @ Vertex "us-central1"
    #       (the only Live model on Vertex; Live-3.1 is Developer-API-only)
    #   voice-preset previews (settings picker TTS samples)
    #       gemini-2.5-flash-preview-tts       @ the same client as gemini_model
    #       (prebuilt voice names — Aoede / Puck / Kore / … — are shared with
    #       the Live model; generate_content with response_modalities=["AUDIO"])
    #   default HD voice
    #       Aoede
    #   photo edit ("Chat about it" → edit_photo tool, founder request
    #   2026-09-16: "If it's easy enough to call Gemini image edit models
    #   let's do it")
    #       gemini-2.5-flash-image      @ Vertex location "global", the same
    #       client/location as gemini_model — verified live against Vertex
    #       (ayma-ai, ADC, no new billing/API-enablement) on 2026-09-16;
    #       reached GA 2025-10-02. generate_content with
    #       response_modalities=["TEXT", "IMAGE"]; the model returns the
    #       edited image as an ``inline_data`` part.
    #
    # Env vars still override for a one-off experiment, but the committed
    # defaults ARE the lock — deploy scripts no longer set model ids.
    #
    # Voice provider flip (hackathon Deliverable A): the locked Gemini Live
    # voice above stays here as the always-available FALLBACK. The dedicated flag
    # ``llm_provider_voice_main`` (below) QLOO-PHASE DEFAULTS to ``gemini``
    # (founder directive — Qloo judged before Meta, best-experience stack), so
    # the MAIN voice call runs on the locked Gemini Live native-audio voice for a
    # user with no saved preference; ``LLM_PROVIDER_VOICE_MAIN=meta`` flips it to
    # the Meta cascade (Muse Spark), which is the post-Qloo default for Meta.
    # A build failure or any mid-call cascade error still falls back to Gemini Live.
    # The flag only selects which stack builds — the model ids here are never
    # changed or removed, so the lock stays in force for the fallback path.
    # ---------------------------------------------------------------- #

    gemini_model: str
    """The Gemini model id for text chat / wiki / matching / icebreakers.
    Per ``AGENTS.md`` every Gemini model string flows from this module. LOCKED
    to ``gemini-3.7-flash`` (see the block above)."""

    gemini_location: str
    """Vertex location for ``gemini_model`` and ``image_embedding_model`` calls.
    LOCKED to ``global`` — Gemini 3.x flash and Gemini Embedding 2 are only
    served from ``global`` on Vertex (404 in regional endpoints)."""

    gemini_live_model: str
    """The Gemini Live model id for the voice agent worker (§1.1). Same
    ``AGENTS.md`` rule — the agent worker reads it from here, never hardcodes.
    LOCKED to ``gemini-live-2.5-flash-native-audio`` (see the block above)."""

    gemini_live_location: str
    """Vertex location for the Gemini Live voice model. LOCKED to
    ``us-central1`` — the native-audio Live model is not served from
    ``global``."""

    gemini_live_use_dev_api: bool
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): voice always runs on LiveKit Inference, never the Developer
    API. ``GEMINI_LIVE_USE_DEV_API``."""

    gemini_live_dev_model: str
    """The Gemini Live model id used only when ``gemini_live_use_dev_api`` is
    on. LOCKED to ``gemini-3.8-live`` — the current GA Live model (Google
    marks ``gemini-3.1-flash-live-preview`` "Legacy — update to Gemini 3.8
    Live"), Developer-API-only (not on Vertex / Agent Platform). Rollback to
    the old preview is a config flip:
    ``GEMINI_LIVE_DEV_MODEL=gemini-3.1-flash-live-preview`` — no code deploy.
    Capabilities verified live against the real Dev API on 2026-09-26 before
    the switch: setup with our full tool roster + both audio transcriptions
    accepted, tool round-trip works, and ``context_window_compression``
    genuinely EVICTS on this model (unlike 3.1 — see context_opt.py)."""

    gemini_live_voice: str
    """Default Gemini Live built-in HD voice preset the agent speaks with
    (§13.3). Overridden per-user by ``ayma_voice_name`` in a later step.
    LOCKED to ``Aoede``."""

    gemini_live_affective_dialog: bool
    """Native-audio-only Live feature: Ayma reads the caller's vocal
    tone/emotion and answers with matching prosody. **On by default** — the
    Live model we run rejects session setup when it's set, which breaks voice
    outright. Set ``GEMINI_LIVE_AFFECTIVE_DIALOG=true`` only on a native-audio
    Live model."""

    gemini_live_proactivity: bool
    """Native-audio-only Live feature: Ayma can volunteer a thought or skip a
    reply that doesn't need one. **On by default** for the same reason as
    ``gemini_live_affective_dialog``; ``GEMINI_LIVE_PROACTIVITY=true`` to opt
    in on a native-audio model."""

    gemini_web_search: bool
    """Let Ayma's **text** chat ground answers on live Google Search + read
    URLs the user pastes (``google_search`` + ``url_context`` built-in tools,
    alongside the session function tools). **Off by default** while grounded
    research is disabled (direct-Google kill, 2026-11-04): the research
    backend always raises ``DirectGoogleDisabledError``, so a
    guaranteed-to-fail tool must not be offered — every call surfaced as an
    internal error. Set ``GEMINI_WEB_SEARCH=true`` only once a LiveKit-routed
    search backend exists. Voice is unaffected — the Live model wires search
    separately."""

    gemini_maps_grounding: bool
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): Maps grounding only existed on the direct-Google path.
    ``GEMINI_MAPS_GROUNDING``."""

    image_search_api_key: str
    """Google Programmable Search (Custom Search JSON API) key for the deep-dive
    **web image search** — finding photos of a person online to face-verify
    against their profile photos. Empty = the image step is skipped (the dive
    still runs). Provide via ``IMAGE_SEARCH_API_KEY`` + ``IMAGE_SEARCH_CSE_ID``."""

    image_search_cse_id: str
    """The Programmable Search Engine id (``cx``) paired with
    ``image_search_api_key``. Empty = image step skipped."""

    gemini_chat_thinking_level: str
    """Thinking effort for **text chat** replies (``generate_reply``) — chat is
    conversational, not a reasoning task, so ``low`` keeps replies fast and the
    per-turn cost down. ``GEMINI_CHAT_THINKING_LEVEL`` = ``low`` | ``medium`` |
    ``high``, or ``""`` to leave the model default. Background JSON calls
    (matching explanations, wiki compilation) are deliberately untouched."""

    gemini_tts_model: str
    """Gemini text-to-speech model id for the voice-preset previews on the
    settings picker (§13.3) — a short spoken "Hi, I'm Ayma…" sample per preset,
    generated once and cached in Storage. Same ``AGENTS.md`` rule: the model
    string lives only here. LOCKED to ``gemini-2.5-flash-preview-tts`` — it
    accepts the shared prebuilt ``voice_name`` values (Aoede / Puck / Kore /
    …) via ``generate_content`` with ``response_modalities=["AUDIO"]``."""

    image_embedding_model: str
    """Vertex multimodal-embedding model id for face/photo embeddings (§2.5).
    Same ``AGENTS.md`` rule — model strings live only here. LOCKED to
    ``gemini-embedding-2`` (3072-d, Vertex ``global``)."""

    web_photo_facematch_threshold: float
    """Cosine-similarity cutoff the web-research / reverse-image-search
    face-match gate (``reverse_image_search.scan`` →
    ``deep_dive_images.classify_face_match``) must clear before a web-found
    photo is staged as a "Photos to confirm" candidate. Deliberately
    *stricter* than the shared ``deep_dive_images._VERIFY_THRESHOLD`` (0.55)
    used elsewhere: reverse-image Web Detection candidates are whole-image
    multimodal embeddings of strangers' photos (YouTube thumbnails, news
    stills, etc.) that merely look visually similar, so this path has a
    materially higher misidentification risk and must err toward precision —
    better to miss a real photo than ever surface a stranger against the user.
    ``WEB_PHOTO_FACEMATCH_THRESHOLD``; default 0.65."""

    gemini_image_edit_model: str
    """Gemini image-editing model id for the ``edit_photo`` tool (the "Chat
    about it" photo flow — see the "LOCKED MODELS" block above). Same
    ``AGENTS.md`` rule. LOCKED to ``gemini-2.5-flash-image`` — same Vertex
    client/location as ``gemini_model`` (``global``), takes an input image +
    text instruction and returns an edited image via ``generate_content``
    with ``response_modalities=["TEXT", "IMAGE"]``."""

    storage_bucket: str
    """Firebase Storage bucket the backend reads uploaded photos from."""

    use_vertex: bool
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): no served path calls Gemini via Vertex or the Developer API
    anymore — all inference goes through LiveKit."""

    vertex_location: str

    livekit_url: str
    """Public LiveKit Cloud ``wss://`` endpoint the client connects to (§1.1).
    Non-secret — the API key/secret used to *sign* room tokens are read from the
    environment at the call site, never stored here."""

    livekit_inference_url: str
    """Base URL of the LiveKit Inference gateway (an OpenAI-compatible
    ``/v1`` endpoint, authenticated with a JWT minted from the existing
    ``LIVEKIT_API_KEY`` / ``LIVEKIT_API_SECRET`` — see ``inference_llm.py``).
    Non-secret. ``LIVEKIT_INFERENCE_URL`` overrides it."""

    llm_route_json: str
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): structured-JSON text jobs always run on LiveKit Inference.
    ``LLM_ROUTE_JSON``."""

    llm_route_vision: str
    """INERT since the 2026-11-04 direct-Google kill: JSON calls that carry
    images always run on LiveKit Inference. ``LLM_ROUTE_VISION``."""

    llm_route_chat: str
    """INERT since the 2026-11-04 direct-Google kill: the text chat turn
    always runs on LiveKit Inference. ``LLM_ROUTE_CHAT``."""

    llm_percent_json: int
    llm_percent_vision: int
    llm_percent_chat: int
    llm_percent_voice: int
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): every group always sends 100% to LiveKit Inference.
    ``LLM_PERCENT_JSON`` / ``_VISION`` / ``_CHAT`` / ``_VOICE``."""

    inference_json_model: str
    """LiveKit Inference model id for the JSON jobs when routed to Inference.
    Provider-prefixed (``google/…``); the only place this string lives.
    Defaults to the SAME locked model as ``gemini_model`` (model lock: changing
    it needs the founder's explicit approval)."""

    inference_chat_model: str
    """LiveKit Inference model id for chat when routed to Inference."""

    inference_chat_max_tokens: int
    """Completion-token budget for a LiveKit Inference chat call. The chat model
    is a *thinking* model and ``completion_tokens`` counts reasoning tokens, so
    this budget must leave room for visible content *after* the model reasons —
    a value too small (e.g. 1024 against Ask-Ayma's ~17-18k-token prompt) burns
    the whole budget on reasoning and returns empty content.
    ``INFERENCE_CHAT_MAX_TOKENS`` (default 8192)."""

    llm_inference_fallback: bool
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): a failed Inference call is never retried on a direct provider.
    ``LLM_INFERENCE_FALLBACK``."""

    inference_timeout_seconds: float
    """Per-call timeout for a LiveKit Inference completion."""

    voice_provider: str
    """INERT since the 2026-11-04 direct-Google kill (kept so existing envs
    validate): voice always runs on ``livekit.agents.inference.RealtimeModel``.
    ``VOICE_PROVIDER``."""

    inference_live_model: str
    """LiveKit Inference realtime model id used when ``voice_provider`` is
    ``inference``."""

    livekit_room_prefix: str
    """Prefix for the per-user voice room name minted by ``POST /bootstrap``."""

    livekit_token_ttl_seconds: int
    """TTL of the short-lived, room-scoped LiveKit access token (§3.4)."""

    voice_idle_timeout_seconds: float
    """Voice calls: end the session after this many seconds with no activity
    (user speech, agent speech, tool call, data message) so a forgotten call
    stops billing LiveKit participant-minutes. ``0`` or negative disables it."""

    livekit_room_empty_timeout_seconds: int
    """Room-level safety net: seconds a freshly created room waits for its
    first participant before LiveKit closes it."""

    livekit_room_departure_timeout_seconds: int
    """Room-level safety net: seconds a room stays open after its last
    participant leaves."""

    agent_url: str
    """``ayma-agent``'s own Cloud Run URL (e.g.
    ``https://ayma-agent-xxxx-uc.a.run.app``) — empty unless set. Used only to
    "wake" the scale-to-zero worker (``agent_wake.py``): Cloud Run scales an
    instance up only in response to inbound HTTP traffic hitting the
    service's *own* URL, and nothing in the LiveKit room-creation flow ever
    does that (automatic dispatch is a push from LiveKit Cloud to whichever
    workers are already registered) — so with ``min-instances=0`` this is the
    only thing that starts the container before the client tries to join."""

    agent_runtime: str
    """Which cloud hosts THIS agent-worker process: ``""`` / ``cloudrun`` (GCP
    Cloud Run — the default and all of production) or ``livekit`` (LiveKit Cloud
    Agents, opt-in behind the per-user ``voice_agent_cloud`` flag). ``AGENT_RUNTIME``.
    Read by ``agent.py`` to pick its dispatch model (automatic on Cloud Run,
    explicit ``agent_name`` on LiveKit) and its Firestore credential source
    (runtime identity on Cloud Run, a mounted service-account key on LiveKit)."""

    agent_name_livekit: str
    """The explicit LiveKit agent-dispatch name the LiveKit-Cloud-hosted worker
    registers under (``agent.py`` ``worker_options`` when ``agent_runtime ==
    'livekit'``), and the name ``POST /bootstrap`` routes a room to when a user's
    ``voice_agent_cloud`` is ``livekit``. The Cloud Run worker keeps AUTOMATIC
    dispatch (no name) so production voice is unchanged. ``AGENT_NAME_LIVEKIT``."""

    push_preview_len: int
    """Max chars of underlying message/event text in a push preview (§7.4)."""

    push_cooldown_seconds: int
    """Backend-enforced cap: at most one push per user per this window (§7.5).
    Bursts still write notification-center docs — only the push is throttled."""

    max_fcm_tokens: int
    """Cap on the ``fcm_tokens`` array per user — multi-device (§3.8) with a
    bound so a churning device can't grow it without limit."""

    dm_viewing_window_seconds: int
    """A DM push is suppressed if the recipient's ``last_read_at`` on that
    thread is newer than this many seconds — they're still looking at it
    (§7.1, §7.9 step 4)."""

    reengage_inactive_days: int
    """A user idle at least this many days is a re-engagement candidate (§7.1)."""

    reengage_backoff_start_days: int
    """First gap after a re-engagement message; it doubles each subsequent
    send (7 → 14 → 28 …) until the user returns, then resets (§7.1)."""

    reengage_min_match_score: float
    """A scored match at/above this feeds a profile-share re-engagement
    instead of a generic check-in (§7.1)."""

    reengage_user_limit: int
    """Max users the re-engagement cron scans per run."""

    rate_cron_reengage: str
    """Rate limit for ``POST /cron/reengage`` (§10.4)."""

    rate_cron_ingest_backfill: str
    """Rate limit for ``POST /cron/ingest-backfill`` (§10.4, §15)."""

    tokens_per_credit: int
    """Display ratio: how many Gemini tokens one user-facing *credit* is worth.
    Credits are a pure display layer over ``token_usage.total`` — nothing is
    stored per credit. Default 1_000 (so the 100k token cap == 100 credits)."""

    credits_per_usd: int
    """The ONE credits<->dollars scale. 1 credit = $0.01 of real token cost, so
    100 credits per USD. Dollars are internal only: every client-facing
    figure (balance, allowance, tier grant) is expressed in credits."""

    free_start_grant_usd: float
    """One-time starting grant for every account, in USD of token cost
    (internal). $5.00 == 500 credits. Never re-granted after a paid lapse."""

    free_daily_allowance_usd: float
    """Daily allowance once the start grant is spent, in USD of token cost
    (internal). $1.00 == 100 credits. Resets at 00:00 UTC, never accumulates.
    Applies to the free plan only. Env ``FREE_DAILY_ALLOWANCE_USD`` tunes it
    without a code change (raised from $0.25 on 2026-10-27: 25 credits was a
    single voice turn / report, so the "daily credits refresh every day"
    free tier read as permanently empty — see billing.py)."""

    billing_expiry_grace_seconds: int
    """How long past ``period_end`` a paid plan stays active before the ledger
    lazily falls back to free — absorbs RevenueCat renewal-webhook lag."""

    pro_trial_credits: int
    """Credits granted once when a Pro free trial starts (RevenueCat
    ``INITIAL_PURCHASE`` with ``period_type == TRIAL``). Env
    ``PRO_TRIAL_CREDITS``; defaults to the Pro monthly pool. Converted to the
    internal USD pool with ``credits_per_usd``; the trial length itself is the
    store offer's, never configured here."""

    revenuecat_webhook_secret: str
    """Shared secret RevenueCat sends in the ``Authorization`` header of its
    webhook. Sourced from Secret Manager env var ``REVENUECAT_WEBHOOK_SECRET``;
    when empty ``POST /webhooks/revenuecat`` refuses everything (fail closed)."""

    revenuecat_secret_api_key: str
    """RevenueCat REST secret API key (``sk_...``) used server-side by
    ``POST /billing/sync`` to read a user's active entitlement authoritatively
    (``GET /v1/subscribers/{app_user_id}``). Sourced from Secret Manager env
    var ``REVENUECAT_SECRET_API_KEY``. When empty, ``/billing/sync`` falls back
    to a dev-view caller's client-reported entitlement (debug testing only) and
    credits nobody else — the webhook stays the production source of truth."""

    rate_webhooks: str
    """Rate limit for ``POST /webhooks/*`` (RevenueCat)."""

    credit_free_topup_enabled: bool
    """Whether ``POST /credits/topup`` (a free reload) works. Default OFF
    (env ``CREDITS_FREE_TOPUP_ENABLED``) — a free reload undercuts the
    paywall; when off the endpoint answers 402 ``upgrade_required``."""

    credit_topup_amount: int
    """Credits added per ``POST /credits/topup`` when the free top-up flag is
    on. Default 100."""

    rate_credits_topup: str
    """Rate limit for ``POST /credits/topup`` (§10.4)."""

    rate_feedback: str
    """Rate limit for ``POST /feedback`` (conduct) and ``POST /feedback/submit``
    (the product feedback catcher) (§10.4, §15)."""

    instagram_app_id: str
    """Meta/Instagram OAuth client id (non-secret). The app *secret* is read
    from ``INSTAGRAM_APP_SECRET`` at the call site, never stored here (§8.6)."""

    instagram_redirect_uri: str
    """Registered OAuth redirect URI for the Instagram connect flow (§8.1)."""

    instagram_media_limit: int
    """Max photos pulled on an Instagram connect (§8.1 — capped at 20)."""

    rate_instagram: str
    """Rate limit for ``POST /instagram/*`` (§10.4)."""

    google_import_client_id: str
    """Google Cloud OAuth 2.0 client id (non-secret) for the Google account
    import flow (Gmail/Calendar — new, mirrors §8.6's Instagram pattern;
    Google Photos was dropped, see google_account.py's module docstring).
    The client *secret* is read from
    ``GOOGLE_IMPORT_CLIENT_SECRET`` at the call site, never stored here. A
    distinct OAuth client from any Firebase Google Sign-In client — this one
    requests read-only data scopes and needs its own Google Cloud Console
    OAuth consent screen + client registration (see the human provisioning
    steps in the feature's report)."""

    google_import_redirect_uri: str
    """Registered OAuth redirect URI for the Google account import flow."""

    google_sync_window_days: int
    """How far back (and, for Calendar, forward) a Google sync looks — never
    a full-history pull. Default 30 days."""

    google_gmail_limit: int
    """Max Gmail messages pulled per sync, metadata pass (Subject/From
    headers only — the cheap first filter). Default 100."""

    google_gmail_body_limit: int
    """Of the ``google_gmail_limit`` metadata results, the max number whose
    body is actually read (``format=full``), after excluding senders on the
    ``admin_config/gmail_exclude_domains`` list (see google_account.py).
    Deliberately small — this is a bounded, opt-in-by-connecting deep read,
    not a bulk pull. Default 8."""

    google_calendar_limit: int
    """Max Calendar events pulled per sync (title + attendee count only).
    Default 100."""

    google_sync_min_interval_hours: int
    """Minimum hours between scheduled re-syncs for one user (the
    ``/cron/google-sync`` sweep skips a user synced more recently than this).
    Default 20 — roughly once a day."""

    rate_google: str
    """Rate limit for ``POST /google/*`` and ``GET /google/*`` (§10.4)."""

    rate_cron_google_sync: str
    """Rate limit for ``POST /cron/google-sync`` (§10.4)."""

    rate_explore: str
    rate_block: str
    rate_profile_share: str
    rate_dm_send: str

    share_base_url: str
    """Public origin of shareable-report links (``{base}/s/{token}``). Must be
    mapped to the ``ayma-api`` Cloud Run service (docs/deploy.md). Env
    ``SHARE_BASE_URL``."""

    share_android_store_url: str
    share_ios_store_url: str
    """Store listings the public share page's "Get Ayma" buttons point at
    (envs ``SHARE_ANDROID_STORE_URL`` / ``SHARE_IOS_STORE_URL``). An empty
    value hides that button."""

    share_android_package: str
    share_assetlinks_sha256: tuple[str, ...]
    """Android package + signing-cert SHA-256 fingerprint(s) (comma-separated
    env ``SHARE_ASSETLINKS_SHA256``) served at ``/.well-known/assetlinks.json``
    so Android verifies the app-link for ``/s/*``. Empty -> that route 404s."""

    rate_share: str
    """Rate limit for the authenticated ``/share`` create/revoke endpoints."""

    rate_share_public: str
    """Rate limit for the public ``/s/*`` page, card and data routes."""
    rate_cron_match: str
    rate_wiki_reset: str
    rate_voice: str
    rate_voice_preview: str
    """Rate limit for ``GET /voice/preview/{voice_name}`` (§10.4). Tighter than
    ``rate_voice`` — a cache miss runs a Gemini TTS call. Sized to survive the
    picker's open-time prewarm burst (one call per preset) plus rapid taps."""
    rate_default: str
    """Per-endpoint limits for the remaining §10.2 routes (§10.4, §10.6 step 2).
    ``rate_default`` is the fallback the middleware applies to any route not in
    its explicit table — so no endpoint ships without a limit."""

    sentry_traces_sample_rate: float
    """Fraction of transactions Sentry traces (``SENTRY_TRACES_SAMPLE_RATE``,
    default 0.05). The DSN itself is a secret read from ``SENTRY_DSN`` at the
    init site (``monitoring.py``); with no DSN Sentry is never initialised."""

    sentry_error_sample_rate: float
    """Fraction of errors Sentry reports (``SENTRY_ERROR_SAMPLE_RATE``,
    default 1.0)."""

    sentry_enabled: bool
    """Kill switch (``SENTRY_ENABLED``, default true). Set to ``false`` and
    redeploy / update the env to stop all Sentry init and events even with a
    DSN mounted."""

    sentry_environment: str
    """Sentry ``environment`` tag (``SENTRY_ENVIRONMENT``)."""

    meta_integrations: bool
    """Instagram / Facebook connect, sign-in and photo import (V2; off for V1).
    ``META_INTEGRATIONS``."""

    deepdive_public_profiles: bool
    """Deep-dive discovery of public social-profile photos
    (``deep_dive_public_profiles.py``). ``DEEPDIVE_PUBLIC_PROFILES``."""

    deepdive_blocked_regions: tuple[str, ...]
    """Region tokens (lowercase substrings of the subject's location) for which
    the public-profile step is skipped. ``DEEPDIVE_PUBLIC_PROFILES_BLOCKED_REGIONS``."""

    vertex_ai_search: bool
    """Second deep-dive discovery source: Vertex AI Search over a public-website
    data store (``vertex_search.py``). ``VERTEX_AI_SEARCH``."""

    vertex_ai_search_daily_cap: int
    """Hard per-day cap on Vertex AI Search queries (all instances share it via
    Firestore). ``VERTEX_AI_SEARCH_DAILY_CAP``; at the cap the source is
    skipped, never errors."""

    vertex_ai_search_engine: str
    """Discovery Engine engine id (Enterprise tier; website search is not
    served by a bare data store). ``VERTEX_AI_SEARCH_ENGINE``."""

    rate_notifications: str
    """Rate limit for ``POST /notifications/*`` client routes (§10.4)."""
    voice_opener_grace_seconds: float
    """Voice calls: how long Ayma waits for the caller to speak first before
    opening the conversation herself. ``0`` (or negative) disables the opener."""

    # ---------------------------------------------------------------- #
    # PERSISTENT AI-AVATAR SNAPSHOT — founder directive 2026-10-27.
    # ``persona_snapshot.py``: one standing snapshot per user at
    # ``users/{uid}/persona/avatar`` that date-sims (and, as a follow-up,
    # human<->AI voice) spawn from instantly. See docs/PRACTICE_DATE.md §Avatar
    # snapshot. All caps/weights live here (no scattered magic numbers).
    # ---------------------------------------------------------------- #
    persona_snapshot_min_interval_seconds: int
    """Minimum seconds between background LLM rebuilds of one user's avatar
    snapshot — the strict cost cap (at most one rebuild per hour per user).
    ``PERSONA_SNAPSHOT_MIN_INTERVAL_SECONDS``, default 3600."""

    persona_snapshot_sweep_limit: int
    """Max users the ``POST /cron/persona-snapshot`` sweep walks per tick.
    ``PERSONA_SNAPSHOT_SWEEP_LIMIT``, default 50."""

    # --- Avatar readiness score (0-100) stored on the snapshot doc ----------
    # readiness = round(100 * (profile_weight * profile_completeness
    #                          + conversation_weight * conversation_volume)),
    # each sub-metric normalized to 0..1. Weights are LOCKED at 80/20.
    persona_readiness_profile_weight: float
    """Weight of profile completeness in the avatar readiness score. LOCKED at
    0.80. ``PERSONA_READINESS_PROFILE_WEIGHT``."""

    persona_readiness_conversation_weight: float
    """Weight of conversation volume in the avatar readiness score. LOCKED at
    0.20. ``PERSONA_READINESS_CONVERSATION_WEIGHT``."""

    persona_readiness_low_context_threshold: int
    """A snapshot is flagged ``low_context`` when ``readiness_score`` is below
    this (the UI then warns the match "doesn't have much context yet").
    ``PERSONA_READINESS_LOW_CONTEXT_THRESHOLD``, default 20."""

    persona_readiness_wiki_page_target: int
    """Number of wiki pages at which the wiki-presence signal of profile
    completeness saturates (1.0). ``PERSONA_READINESS_WIKI_PAGE_TARGET``,
    default 5."""

    persona_readiness_conversation_target: int
    """Number of the user's own captured texting-style exemplars at which
    conversation volume saturates (1.0). ``PERSONA_READINESS_CONVERSATION_TARGET``,
    default 20."""

    # ---------------------------------------------------------------- #
    # META MODEL API — hackathon Deliverable A (NEW work, Oct 2026).
    # An OpenAI-compatible provider (Meta Muse Spark) selectable per
    # surface behind the ``LLM_PROVIDER_<SURFACE>`` flags below; Gemini
    # stays the default and the fallback. See ``docs/META_PROVIDER.md``.
    #
    # Per ``AGENTS.md`` every model id (Gemini OR Meta) lives only in this
    # module. The ``META_API_KEY`` is a SECRET — it is read from the
    # environment (Secret Manager → Cloud Run) at the call site in
    # ``llm_provider.py``, never stored here. The base URL is non-secret
    # config and MUST be confirmed against https://dev.meta.ai/docs/quickstart
    # before any live call (override with ``META_API_BASE_URL``).
    # ---------------------------------------------------------------- #

    meta_api_base_url: str
    """OpenAI-compatible base URL of the Meta Model API. Non-secret; the
    ``META_API_KEY`` secret authenticates against it. The committed default is
    a placeholder — confirm the real base path from the Meta quickstart and set
    ``META_API_BASE_URL`` before going live. No live call can succeed until both
    this and the ``META_API_KEY`` secret are correct."""

    meta_chat_model: str
    """Meta Muse Spark LLM id used for the chat / matching / reports / practice
    surfaces when their ``LLM_PROVIDER_*`` flag is ``meta``. Override with
    ``META_CHAT_MODEL``."""

    meta_open_weights_model: str
    """Open-weights Muse Spark id (Baseten-hostable; the hackathon's
    ``$10k Best Build on Meta Open Weight Models`` target). Override with
    ``META_OPEN_WEIGHTS_MODEL``. Wired into the ``open-weights`` provider
    (``llm_provider.OpenWeightsProvider``) — a surface whose
    ``LLM_PROVIDER_*`` flag is ``open-weights`` sends its calls to this model
    id on ``open_weights_api_base_url``."""

    open_weights_api_base_url: str
    """OpenAI-compatible base URL serving the open-weights Muse Spark model
    (Baseten-hosted for the hackathon). Non-secret config; the
    ``OPEN_WEIGHTS_API_KEY`` secret authenticates against it and is read from
    the environment at the call site in ``llm_provider.py``, never stored
    here. Env ``OPEN_WEIGHTS_BASE_URL``, default empty = unconfigured: a
    surface routed to ``open-weights`` then fails with an explicit
    ``OpenWeightsUnconfiguredError`` and never falls back to a paid route.
    Also gates the VOICE cascade's open-weights brain (§13.9): the Brain (LLM)
    dropdown offers ``Llama 3.1 8B (open weights)`` only when this is set, so
    production (env unset) never shows or defaults to it."""

    open_weights_model: str
    """Model id the VOICE cascade's open-weights brain requests from
    ``open_weights_api_base_url`` — a self-hosted OpenAI-compatible server
    (e.g. a Modal-hosted ``Llama-3.1-8B``). Distinct from
    ``meta_open_weights_model`` (the Muse Spark open-weights id the TEXT
    ``OpenWeightsProvider`` uses) because the voice endpoint may serve a
    different model. Env ``OPEN_WEIGHTS_MODEL``, default empty: the voice brain
    is offered only when ``OPEN_WEIGHTS_BASE_URL`` is set, and the agent throws
    (never substitutes a hardcoded id, per AGENTS.md) if this is empty, falling
    the call safely back to Gemini Live."""

    open_weights_cold_start_timeout_s: float
    """First-token/connect timeout (seconds) for the VOICE cascade's
    open-weights LLM leg. The open-weights endpoint is a self-hosted,
    scale-to-zero Modal container whose cold start is ~100s; the LiveKit
    AgentSession default (``APIConnectOptions(timeout=10)``, 3 retries) can never
    survive that, so every turn times out and the call never replies (founder
    bug, 2026-11-02). This widens ONLY the open-weights leg's timeout to cover
    the cold start (§13.9). Env ``OPEN_WEIGHTS_COLD_START_TIMEOUT_S``, default
    ``120``. Does not affect the Meta/Inference legs, which keep the default."""

    open_weights_max_context_tokens: int
    """Hard context window (tokens) the VOICE cascade's open-weights model
    serves — vLLM's ``--max-model-len`` in ``scripts/modal_open_weights.py``.
    The LiveKit AgentSession sends the full, growing chat context every turn, so
    once system prompt + history + the new turn exceed this window the
    self-hosted server returns ``400 This model's maximum context length is …``
    (retryable=False) → the turn fails → the voice sticks on "Listening"
    (founder bug, 2026-11-02). The agent caps the open-weights leg's context to
    stay under this minus ``open_weights_response_token_margin`` (§13.9).
    Large-context brains (Meta Muse Spark, Gemini Live) never hit this and are
    never trimmed. Env ``OPEN_WEIGHTS_MAX_CONTEXT_TOKENS``, default ``16384`` —
    keep it matched to the Modal ``--max-model-len`` (both default 16384; a
    smaller value is always safe, a larger one must not exceed what the server
    serves or the cap stops protecting against the 400)."""

    open_weights_response_token_margin: int
    """Tokens reserved out of ``open_weights_max_context_tokens`` for the
    model's own reply (prompt + completion must both fit the window). The
    cascade trims the sent context to ``max_context - this`` so a full reply can
    always be generated without overflowing. Env
    ``OPEN_WEIGHTS_RESPONSE_TOKEN_MARGIN``, default ``1200`` (≈ a long voice
    turn, leaving ~15000 prompt tokens on a 16384 model, ~7000 on an 8192
    one)."""

    meta_transcribe_model: str
    """Meta Muse Voice Transcribe (STT) id. Listed in the Meta Model API's
    ``GET /v1/models``, but Meta serves no working OpenAI-compatible REST STT
    endpoint (every transcription path 404s; only a WebSocket ``/v1/realtime``
    exists), so the Practice Date voice cascade canNOT use it — its STT leg runs
    on LiveKit Inference (``meta_cascade_stt_model``) instead. Kept here as the
    Deliverable-A record of the Meta STT id. Override with ``META_TRANSCRIBE_MODEL``."""

    meta_cascade_stt_model: str
    """STT model for the Meta voice cascade's speech-to-text leg, in LiveKit
    Inference ``provider/model`` form (the gateway is LiveKit-credit covered,
    authed with the worker's ``LIVEKIT_API_KEY``/``SECRET`` — same path as the
    cascade's TTS and VAD). Meta has no usable REST STT (see
    ``meta_transcribe_model``), so the cascade transcribes through Inference
    while the LLM leg stays Meta Muse Spark. Default a low-latency streaming
    model; override with ``META_CASCADE_STT_MODEL``."""

    meta_cascade_tts_model: str
    """TTS model for the Meta voice cascade, in LiveKit Inference
    ``provider/model[:voice]`` form (the gateway is LiveKit-credit covered, authed
    with the worker's ``LIVEKIT_API_KEY``/``SECRET``). Default Fish Audio
    ``s2.1-pro`` (the founder's selected default); Inworld and Rime are documented
    A/B alternatives (``docs/META_PROVIDER.md``). The vendor lives here, not in
    ``agent.py``, so the flag can reach it. Override with ``META_CASCADE_TTS_MODEL``."""

    meta_cascade_tts_voice: str
    """Optional voice preset for ``meta_cascade_tts_model`` (empty = the vendor
    default voice). Defaults to Fish Audio ``Hannah`` (a conversational
    specialist, feminine) — the founder's selected default voice. Fish Audio
    voices are addressed by id, so the value is Hannah's documented voice id
    (``voice_catalog._TTS_FALLBACK_VOICES["fishaudio"]``), never the label.
    Override with ``META_CASCADE_TTS_VOICE``."""

    meta_cascade_tts_voice_female: str
    """Gender-matched TTS voice preset for the cascade when it simulates a
    FEMALE Practice Date persona (``agent.build_meta_cascade_session``). The
    vendor's own voice id lives here, never hardcoded in ``agent.py``; defaults
    to the feminine Fish Audio voice ``Hannah`` so female personas sound female.
    If set empty it falls back to ``meta_cascade_tts_voice``. Override with
    ``META_CASCADE_TTS_VOICE_FEMALE``."""

    meta_cascade_tts_voice_male: str
    """Gender-matched TTS voice preset for the cascade when it simulates a MALE
    Practice Date persona. Defaults to the masculine Fish Audio voice ``Adrian``
    (friendly, casual American) so male personas sound male. If set empty it
    falls back to ``meta_cascade_tts_voice``. Override with
    ``META_CASCADE_TTS_VOICE_MALE``."""

    meta_cascade_vad_model: str
    """VAD model that segments speech for the Meta cascade (the cascade has no
    server-side turn detection, unlike Gemini Live). Bundled Silero via
    ``livekit.agents.inference.VAD`` — runs locally in the worker, no extra
    credential. Override with ``META_CASCADE_VAD_MODEL``."""

    voice_isolation: str
    """Agent-side voice isolation for voice sessions (``VOICE_ISOLATION``):
    ``krisp`` (Krisp VIVA, the default), ``aicoustics`` (ai-coustics
    QUAIL_VF_S), or ``off``. The filter runs in the agent on the user's
    inbound audio before VAD/STT/turn detection, metered through LiveKit
    Cloud — covered by the Scale plan's included voice-isolation minutes
    (verified 2026-11-06). Founder rule (2026-11-06): on by default wherever
    the stack supports it and the plan covers it; it never restricts which
    model the user can pick."""

    async_voice_tts_model: str
    """TTS model for async voice-message replies (``async_voice.py``), in
    LiveKit Inference ``provider/model`` form — the same gateway the live
    voice cascade's TTS leg uses (``inference_tts.synthesize`` speaks the
    gateway's ``/tts`` websocket protocol, mirroring ``inference.TTS``).
    Defaults to the founder-selected cascade voice (Fish Audio ``s2.1-pro``).
    Override with ``ASYNC_VOICE_TTS_MODEL``."""

    async_voice_tts_voice: str
    """Voice preset for ``async_voice_tts_model`` (empty = the vendor default
    voice). Fish Audio voices are addressed by id, so the default is
    ``Hannah``'s documented voice id (the founder's selected default voice),
    the same default the Meta cascade uses. Override with
    ``ASYNC_VOICE_TTS_VOICE``."""

    async_voice_max_clip_bytes: int
    """Largest accepted async voice-message clip in bytes (``POST
    /voice/async``). A 16kHz mono wav (what the client records) runs ~32KB/s,
    so the default 8MB covers a ~4-minute message; larger clips are refused
    honestly rather than billed as giant audio-token turns. Override with
    ``ASYNC_VOICE_MAX_CLIP_BYTES``."""

    meta_reasoning_effort: str
    """Reasoning budget for Muse Spark chat calls. Every Muse Spark variant is a
    reasoning model (there is no non-reasoning Meta chat model); the API floor is
    ``minimal`` (``none`` is rejected). We pin ``minimal`` so conversational
    replies stay fast (~0.6s, ~20 reasoning tokens) instead of burning the token
    budget on reasoning (~450 tokens, content truncated). Override with
    ``META_REASONING_EFFORT`` (minimal|low|medium|high|xhigh|max)."""

    llm_provider_chat: str
    llm_provider_matching: str
    llm_provider_reports: str
    llm_provider_practice: str
    llm_provider_voice: str
    llm_provider_dm_coach: str
    llm_provider_translate: str
    """Per-surface provider switch, ``gemini`` | ``meta`` | ``open-weights``.
    Each surface flips and rolls back independently via
    ``LLM_PROVIDER_<SURFACE>`` (e.g. ``LLM_PROVIDER_CHAT=meta``);
    ``LLM_PROVIDER`` sets the default for any surface whose own var is unset.
    ``open-weights`` routes the surface to the cheap open-weights Muse Spark
    endpoint (``open_weights_api_base_url`` + ``OPEN_WEIGHTS_API_KEY``) with
    no paid fallback. All default to ``gemini`` EXCEPT
    ``llm_provider_dm_coach`` (see below) — production behaviour is unchanged
    until a surface is explicitly flipped. Read by
    ``llm_provider.get_llm_provider(surface)``.

    NOTE: ``llm_provider_voice`` is the **Practice Date** voice switch only (the
    simulated-match roleplay). The normal/main Ayma voice call is a SEPARATE
    switch, ``llm_provider_voice_main`` below, so Practice and the main voice
    flip independently.

    NOTE: ``llm_provider_dm_coach`` is the switch for the "Ayma in your DMs"
    assistant (``dm_assist.py``: opener chips on an empty thread + live coaching
    on an active one). Unlike the other surfaces it DEFAULTS to ``meta`` (Muse
    Spark) — founder directive for the hackathon that the DM assistant runs on
    the Meta brain. It still inherits a global ``LLM_PROVIDER`` override and the
    Gemini fallback (``llm_meta_fallback``), so a flip can never take it down.

    NOTE: ``llm_provider_translate`` is the switch for cross-language DM
    translation (``dm_translate.py`` / ``POST /dm/translate``: translate an
    incoming message into the reader's language, or the reader's draft into the
    match's language). Like ``dm_coach`` it DEFAULTS to ``meta`` (Muse Spark) —
    the hackathon's cross-language dating feature is "powered by Muse" — and
    inherits the global ``LLM_PROVIDER`` override and the Gemini fallback, so a
    flip can never take it down. Translation is a nicety that must never block a
    thread: on any failure the client keeps the original text (see
    ``docs/META_PROVIDER.md`` and ``docs/ARCHITECTURE.md`` §6.12)."""

    llm_provider_voice_main: str
    """Provider switch for the MAIN (normal, non-practice) Ayma voice call,
    ``gemini`` | ``meta``. ``LLM_PROVIDER_VOICE_MAIN=meta`` flips it to Muse.

    QLOO-PHASE default ``gemini`` (founder directive — Qloo is judged BEFORE
    Meta, so a user with no saved voice preference gets the best-experience
    stack: Gemini Live native-audio voice, Realtime mode, voice Aoede). This is
    both the ``/voice/engines`` user-facing default (``voice_catalog._default_from``)
    and the stack the agent actually builds at call time (``agent.py``). It flips
    back to ``meta`` (Meta cascade / Muse Spark) post-Qloo for the Meta hackathon.
    Unlike the
    other per-surface switches it does NOT inherit the global ``LLM_PROVIDER``
    default: it is its own dedicated var so a global ``LLM_PROVIDER`` change never
    sweeps the main voice. When set to ``meta`` the main voice is built as the
    Meta cascade
    (LiveKit Inference STT -> Meta Muse Spark LLM -> Fish Audio TTS + Silero VAD,
    :func:`agent.build_meta_cascade_session`), intentionally BYPASSING the
    locked Gemini Live voice for Muse Spark; a build failure or any mid-call
    cascade error falls back to Gemini Live so the flip can never take the main
    voice down. See ``docs/META_PROVIDER.md`` and ``docs/FEATURE_FLAGS.md``."""

    llm_meta_fallback: bool
    """When a surface is routed to ``meta`` and the Meta call fails (no key yet,
    transport error, bad response), retry once on Gemini. Default True — so a
    flip can never take a surface down. ``LLM_META_FALLBACK=false`` to disable
    (e.g. in an eval that must measure Meta on its own)."""

    brain_default: str
    """The unified **Brain** shown pre-selected on the "Ayma's models" screen
    and used as the fallback brain for the text surfaces when a user has NOT
    saved an ``ayma_brain_model`` preference, ``gemini`` | ``meta`` (vendor
    name, not a model id). QLOO-PHASE default ``gemini`` (founder directive —
    Qloo is judged before Meta; new/unset users get the best-experience stack),
    flips back to ``meta`` (Muse Spark) post-Qloo. A brain that lacks a
    needed capability (web, vision) is still resolved to Gemini per the
    capability map in ``llm_provider`` — so the Muse default never silently
    drops web reading or image analysis. Override with ``AYMA_BRAIN_DEFAULT``.
    This selects a VENDOR only; the locked Gemini/Meta model ids above are never
    changed. See ``docs/ARCHITECTURE.md`` §13.10 and ``docs/META_PROVIDER.md``."""

    # --- Voice ENGINE picker (§13.9, docs/META_PROVIDER.md) ---------------- #
    # The per-user voice stack (dev-settings "Voice engine"): a CASCADE
    # (brain/STT/TTS, independently selectable) or an all-in-one REALTIME model.
    # Every model id below lives here per AGENTS.md; ``voice_catalog.py`` only
    # assembles them into the catalog (labels, voices, availability).

    openai_realtime_model: str
    """OpenAI Realtime (speech-to-speech) model id for the voice-engine picker's
    REALTIME mode (``livekit-plugins-openai`` ``openai.realtime.RealtimeModel``).
    INERT until both ``voice_openai_realtime_enabled`` is set AND an
    ``OPENAI_API_KEY`` secret is mounted on the agent (Secret Manager) — the
    agent falls back to Gemini Live otherwise, so selecting it can never take
    voice down. Override with ``OPENAI_REALTIME_MODEL``."""

    voice_openai_realtime_enabled: bool
    """Flag that EXPOSES OpenAI Realtime as a selectable realtime model in the
    catalog. Default False (present but hidden/disabled in the UI until the
    founder enables it and adds the ``OPENAI_API_KEY`` secret). ``gemini`` needs
    no key and is always available. ``VOICE_OPENAI_REALTIME=true`` to enable."""

    voice_cascade_stt_models: tuple[str, ...]
    """Selectable STT model ids for CASCADE mode, LiveKit Inference
    ``provider/model`` form (credit-covered, no key). The id IS the model string.
    ``VOICE_CASCADE_STT_MODELS`` (CSV) overrides; extend by adding ids. The
    ``cartesia/ink-2`` (primary) / ``cartesia/ink-whisper`` (wide-language
    fallback) ids ride the grant-funded Cartesia plugin when the agent has
    ``CARTESIA_API_KEY``, else the Inference construction (``agent.py``). The
    served catalog withholds ``cartesia/*`` ids until that key is wired
    (``voice_catalog.cartesia_enabled``) — an inactive Cartesia never appears
    in a selection list (founder ruling 2026-11-05)."""

    voice_cascade_tts_models: tuple[str, ...]
    """Selectable TTS model ids for CASCADE mode, LiveKit Inference
    ``provider/model`` form. Voices per provider come from ``voice_catalog``
    (LiveKit catalog when it ships one, else a documented fallback).
    ``VOICE_CASCADE_TTS_MODELS`` (CSV) overrides; extend by adding ids."""

    cartesia_tts_model: str
    """Plugin model string for Cartesia cascade TTS
    (``livekit-plugins-cartesia`` ``cartesia.TTS``) — the pinned Sonic
    flagship, NOT the catalog id. The catalog's persisted TTS id stays
    ``cartesia/sonic-3`` (in ``voice_cascade_tts_models``); the agent builds
    the plugin with THIS model whenever a ``cartesia/*`` TTS is selected
    and ``CARTESIA_API_KEY`` is present, so usage bills the Cartesia grant
    instead of LiveKit credits. Key or plugin missing → the agent warns and
    keeps the Inference construction, so the selection can never take voice
    down. ``CARTESIA_TTS_MODEL`` overrides (staging-first; production
    defaults unchanged)."""

    voice_cascade_llm_models: tuple[str, ...]
    """FALLBACK brain (LLM) model ids for CASCADE mode when the live LiveKit
    inference catalog can't be fetched. LiveKit Inference ``provider/model``
    form; the live catalog (``voice_catalog``, type=LLM) supersedes these.
    ``VOICE_CASCADE_LLM_MODELS`` (CSV)."""

    voice_cascade_extra_brains: tuple[str, ...]
    """Optional extra CASCADE brains beyond the two built-ins (Meta Muse Spark,
    Gemini via Inference), each ``id|route|model`` where route is ``meta`` |
    ``inference`` and ``model`` is the model id (config, per AGENTS.md).
    ``VOICE_CASCADE_EXTRA_BRAINS`` (CSV) — empty by default."""

    voice_credited_providers: tuple[str, ...]
    """LiveKit-Inference provider segments (``inworld``, ``deepgram``, …) this
    project has confirmed credits for. The catalog is ALWAYS built from the
    config fallback lists: ``GET /v1/models`` on the inference gateway is a
    stub route returning ``{}`` to every caller (root cause verified
    2026-11-06; the same token completes real inference calls, so the
    project is provisioned — the route is simply not a catalog API), so
    there is no live catalog to query the project against. A cascade
    option whose provider is in THIS set is shown enabled; any other provider in
    a fallback list is shown DISABLED with a "needs enabling" note rather than
    as a silently-failing option (``voice_catalog``). ``cartesia`` is the
    exception: it is hidden entirely (not shown disabled) until its grant key
    is wired — see ``voice_catalog.cartesia_enabled``.

    Default = the union verified live on staging 2026-11-06 (``inworld``,
    ``deepgram``, ``fishaudio``, ``assemblyai``, ``rime``, ``gradium``,
    ``google``, ``elevenlabs``, ``openai``, ``cartesia``) — the live
    staging list plus the previously committed ``assemblyai``; no entries
    dropped. The cascade providers ``inworld``/``fishaudio``/``rime``/
    ``gradium`` were wrongly marked unavailable by the old static list
    even though the founder had tested cascade with them successfully.
    ``VOICE_CREDITED_PROVIDERS`` (CSV, lowercase) overrides, and
    ``scripts/deploy-staging.sh`` pins the same union on staging.
    ``cartesia`` is grant-funded via its own plugin + ``CARTESIA_API_KEY``
    (Route A), not LiveKit credits, and the catalog still serves it only
    once that key lands — the key, not this list, is its gate."""

    voice_accent_capable_providers: tuple[str, ...]
    """Provider segments whose voice honours a free-text ACCENT instruction
    (``ayma_voice_accent``) at session boot. The instruction-driven native-audio
    realtime models take an accent in their style/instruction text, so ``gemini``
    and ``openai`` are accent-capable by default. Cascade TTS providers here ship
    only fixed voices, so they are NOT listed and ignore the accent gracefully;
    add one (e.g. a style-controllable TTS) here when it genuinely honours an
    accent description. The single source of truth for
    ``voice_catalog.provider_supports_accent``, which the agent uses to route
    the accent only to capable providers and ``set_voice_preference`` uses to
    tell the user when a model cannot change accent (§13.9). Lowercase.
    ``VOICE_ACCENT_CAPABLE_PROVIDERS`` (CSV, lowercase) overrides."""

    image_variants_enabled: bool
    """Cloud profile-photo variants (Perf Phase 2 PREP, ``image_variants``).
    ``IMAGE_VARIANTS_ENABLED`` — set to ``true`` ONLY on ``ayma-api-staging``.
    Both variant routes refuse when this is unset, so the code is inert on
    any deploy (incl. prod) that never sets it."""

    image_variants_push_sa: str
    """Service-account email allowed to push storage notifications to
    ``POST /internal/storage/image-finalized`` (``IMAGE_VARIANTS_PUSH_SA``,
    staging-only). The push OIDC token's ``email`` claim must equal this
    exactly; an unset value refuses every push (fail closed)."""


def _csv(name: str, default: str, *, lower: bool = False) -> tuple[str, ...]:
    raw = os.getenv(name, default)
    items = (x.strip() for x in raw.split(","))
    return tuple((x.lower() if lower else x) for x in items if x)


_LLM_ROUTES = ("vertex", "inference")
_VOICE_PROVIDERS = ("google", "inference")
_VOICE_ISOLATION_PROVIDERS = ("off", "krisp", "aicoustics")


def _choice(name: str, default: str, allowed: tuple[str, ...]) -> str:
    """An env var restricted to ``allowed`` — a typo must fail loudly at boot,
    never silently fall back to the other provider."""
    value = os.getenv(name, default).strip().lower()
    if value not in allowed:
        raise ValueError(f"{name} must be one of {allowed}, got {value!r}")
    return value


def _percent(name: str) -> int:
    value = int(os.getenv(name, "100"))
    if not 0 <= value <= 100:
        raise ValueError(f"{name} must be 0-100, got {value}")
    return value


def _load() -> Config:
    return Config(
        project_id=(
            os.getenv("GOOGLE_CLOUD_PROJECT")
            or os.getenv("GCLOUD_PROJECT")
            or ""
        ),
        version=os.getenv("APP_VERSION", "0.1.0"),
        cap_marketing_turns=int(os.getenv("CAP_MARKETING_TURNS", "10")),
        cap_interview_turns=int(os.getenv("CAP_INTERVIEW_TURNS", "40")),
        rate_bootstrap=os.getenv("RATE_BOOTSTRAP", "30/minute"),
        rate_chat_text=os.getenv("RATE_CHAT_TEXT", "20/minute"),
        rate_chat_history=os.getenv("RATE_CHAT_HISTORY", "60/minute"),
        rate_cron_lint=os.getenv("RATE_CRON_LINT", "2/minute"),
        rate_media=os.getenv("RATE_MEDIA", "10/minute"),
        rate_account=os.getenv("RATE_ACCOUNT", "5/minute"),
        rate_cron_purge=os.getenv("RATE_CRON_PURGE", "2/minute"),
        account_recovery_days=int(os.getenv("ACCOUNT_RECOVERY_DAYS", "30")),
        match_candidate_pool=int(os.getenv("MATCH_CANDIDATE_POOL", "200")),
        cron_candidate_pool=int(os.getenv("CRON_CANDIDATE_POOL", "50")),
        cron_score_top_k=int(os.getenv("CRON_SCORE_TOP_K", "5")),
        rate_matching=os.getenv("RATE_MATCHING", "6/minute"),
        cron_secret=os.getenv("CRON_SECRET", ""),
        dev_view_emails=_csv("DEV_VIEW_EMAILS", "suhailps@gmail.com", lower=True),
        dev_view_uids=_csv("DEV_VIEW_UIDS", ""),
        test_bypass_emails=_csv(
            "TEST_BYPASS_EMAILS",
            "test1@gmail.com,test2@gmail.com,test3@gmail.com",
            lower=True,
        ),
        all_flags_on_uids=_csv(
            "ALL_FLAGS_ON_UIDS", "demo-test1,demo-test2,demo-test3"
        ),
        explore_fixture_bypass_uids=_csv(
            "EXPLORE_FIXTURE_BYPASS_UIDS", "demo-test1,demo-test2,demo-test3"
        ),
        admin_password=os.getenv("ADMIN_PASSWORD", ""),
        dev_panel_password=os.getenv("DEV_PANEL_PASSWORD", ""),
        mcp_server=os.getenv("MCP_SERVER", "false").strip().lower()
        in ("1", "true", "yes", "on"),
        mcp_token_ttl_days=int(os.getenv("MCP_TOKEN_TTL_DAYS", "30")),
        rate_mcp=os.getenv("RATE_MCP", "120/minute"),
        # LOCKED — see the "LOCKED MODELS" block in the Config dataclass.
        gemini_model=os.getenv("GEMINI_MODEL", "gemini-3.7-flash"),
        gemini_location=os.getenv("GEMINI_LOCATION", "global"),
        gemini_live_model=os.getenv(
            "GEMINI_LIVE_MODEL", "gemini-live-2.5-flash-native-audio"
        ),
        gemini_live_location=os.getenv("GEMINI_LIVE_LOCATION", "us-central1"),
        gemini_live_use_dev_api=os.getenv(
            "GEMINI_LIVE_USE_DEV_API", "false"
        ).lower() == "true",
        gemini_live_dev_model=os.getenv(
            "GEMINI_LIVE_DEV_MODEL", "gemini-3.8-live"
        ),
        gemini_live_voice=os.getenv("GEMINI_LIVE_VOICE", "Aoede"),
        gemini_live_affective_dialog=os.getenv(
            "GEMINI_LIVE_AFFECTIVE_DIALOG", "false"
        ).lower()
        == "true",
        gemini_live_proactivity=os.getenv(
            "GEMINI_LIVE_PROACTIVITY", "false"
        ).lower()
        == "true",
        gemini_web_search=os.getenv("GEMINI_WEB_SEARCH", "false").lower()
        == "true",
        gemini_maps_grounding=os.getenv("GEMINI_MAPS_GROUNDING", "true").lower()
        == "true",
        image_search_api_key=os.getenv("IMAGE_SEARCH_API_KEY", ""),
        image_search_cse_id=os.getenv("IMAGE_SEARCH_CSE_ID", ""),
        gemini_chat_thinking_level=os.getenv(
            "GEMINI_CHAT_THINKING_LEVEL", "low"
        ),
        gemini_tts_model=os.getenv(
            "GEMINI_TTS_MODEL", "gemini-2.5-flash-preview-tts"
        ),
        image_embedding_model=os.getenv(
            "IMAGE_EMBEDDING_MODEL", "gemini-embedding-2"
        ),
        web_photo_facematch_threshold=float(
            os.getenv("WEB_PHOTO_FACEMATCH_THRESHOLD", "0.65")
        ),
        gemini_image_edit_model=os.getenv(
            "GEMINI_IMAGE_EDIT_MODEL", "gemini-2.5-flash-image"
        ),
        storage_bucket=os.getenv(
            "STORAGE_BUCKET", "ayma-ai.firebasestorage.app"
        ),
        use_vertex=os.getenv("USE_VERTEX", "true").lower() == "true",
        vertex_location=os.getenv("VERTEX_LOCATION", "us-central1"),
        livekit_url=os.getenv("LIVEKIT_URL", ""),
        livekit_inference_url=os.getenv(
            "LIVEKIT_INFERENCE_URL", "https://agent-gateway.livekit.cloud/v1"
        ).rstrip("/"),
        llm_route_json=_choice("LLM_ROUTE_JSON", "inference", _LLM_ROUTES),
        llm_route_vision=_choice("LLM_ROUTE_VISION", "inference", _LLM_ROUTES),
        llm_route_chat=_choice("LLM_ROUTE_CHAT", "inference", _LLM_ROUTES),
        llm_percent_json=_percent("LLM_PERCENT_JSON"),
        llm_percent_vision=_percent("LLM_PERCENT_VISION"),
        llm_percent_chat=_percent("LLM_PERCENT_CHAT"),
        llm_percent_voice=_percent("LLM_PERCENT_VOICE"),
        inference_json_model=os.getenv(
            "INFERENCE_JSON_MODEL", "google/gemini-3.7-flash"
        ),
        inference_chat_model=os.getenv(
            "INFERENCE_CHAT_MODEL", "google/gemini-3.7-flash"
        ),
        inference_chat_max_tokens=int(
            os.getenv("INFERENCE_CHAT_MAX_TOKENS", "8192")
        ),
        llm_inference_fallback=os.getenv(
            "LLM_INFERENCE_FALLBACK", "false"
        ).lower() == "true",
        inference_timeout_seconds=float(
            os.getenv("INFERENCE_TIMEOUT_SECONDS", "75")
        ),
        voice_provider=_choice("VOICE_PROVIDER", "inference", _VOICE_PROVIDERS),
        inference_live_model=os.getenv(
            "INFERENCE_LIVE_MODEL", "google/gemini-3.8-live"
        ),
        livekit_room_prefix=os.getenv("LIVEKIT_ROOM_PREFIX", "ayma-"),
        livekit_token_ttl_seconds=int(
            os.getenv("LIVEKIT_TOKEN_TTL_SECONDS", "900")
        ),
        voice_idle_timeout_seconds=float(
            os.getenv("VOICE_IDLE_TIMEOUT_SECONDS", "180")
        ),
        livekit_room_empty_timeout_seconds=int(
            os.getenv("LIVEKIT_ROOM_EMPTY_TIMEOUT_SECONDS", "120")
        ),
        livekit_room_departure_timeout_seconds=int(
            os.getenv("LIVEKIT_ROOM_DEPARTURE_TIMEOUT_SECONDS", "20")
        ),
        agent_url=os.getenv("AYMA_AGENT_URL", ""),
        agent_runtime=os.getenv("AGENT_RUNTIME", "").strip().lower(),
        agent_name_livekit=os.getenv("AGENT_NAME_LIVEKIT", "ayma-lk").strip(),
        push_preview_len=int(os.getenv("PUSH_PREVIEW_LEN", "100")),
        push_cooldown_seconds=int(os.getenv("PUSH_COOLDOWN_SECONDS", "900")),
        max_fcm_tokens=int(os.getenv("MAX_FCM_TOKENS", "10")),
        rate_notifications=os.getenv("RATE_NOTIFICATIONS", "20/minute"),
        voice_opener_grace_seconds=float(
            os.getenv("VOICE_OPENER_GRACE_SECONDS", "1.5")
        ),
        # PERSISTENT AI-AVATAR SNAPSHOT (founder directive 2026-10-27).
        persona_snapshot_min_interval_seconds=int(
            os.getenv("PERSONA_SNAPSHOT_MIN_INTERVAL_SECONDS", "3600")
        ),
        persona_snapshot_sweep_limit=int(
            os.getenv("PERSONA_SNAPSHOT_SWEEP_LIMIT", "50")
        ),
        persona_readiness_profile_weight=float(
            os.getenv("PERSONA_READINESS_PROFILE_WEIGHT", "0.80")
        ),
        persona_readiness_conversation_weight=float(
            os.getenv("PERSONA_READINESS_CONVERSATION_WEIGHT", "0.20")
        ),
        persona_readiness_low_context_threshold=int(
            os.getenv("PERSONA_READINESS_LOW_CONTEXT_THRESHOLD", "20")
        ),
        persona_readiness_wiki_page_target=int(
            os.getenv("PERSONA_READINESS_WIKI_PAGE_TARGET", "5")
        ),
        persona_readiness_conversation_target=int(
            os.getenv("PERSONA_READINESS_CONVERSATION_TARGET", "20")
        ),
        # META MODEL API (hackathon Deliverable A) — see the block above.
        meta_api_base_url=os.getenv(
            "META_API_BASE_URL", "https://api.meta.ai/v1"
        ).rstrip("/"),
        meta_chat_model=os.getenv("META_CHAT_MODEL", "muse-spark-1.3"),
        meta_open_weights_model=os.getenv(
            "META_OPEN_WEIGHTS_MODEL", "meta-models/muse-spark-open-1026"
        ),
        meta_transcribe_model=os.getenv(
            "META_TRANSCRIBE_MODEL", "muse-voice-transcribe-1.0"
        ),
        meta_cascade_stt_model=os.getenv(
            "META_CASCADE_STT_MODEL", "deepgram/nova-3"
        ),
        meta_cascade_tts_model=os.getenv(
            "META_CASCADE_TTS_MODEL", "fishaudio/s2.1-pro"
        ),
        # Fish Audio "Hannah" (a conversational specialist, feminine) — the
        # founder's selected default voice. Fish Audio voices are addressed by
        # id, not name, so this is Hannah's documented id from
        # ``voice_catalog._TTS_FALLBACK_VOICES["fishaudio"]``.
        meta_cascade_tts_voice=os.getenv(
            "META_CASCADE_TTS_VOICE", "9a9cf47702da476aa4629e2506d4a857"
        ),
        meta_cascade_tts_voice_female=os.getenv(
            "META_CASCADE_TTS_VOICE_FEMALE", "9a9cf47702da476aa4629e2506d4a857"
        ),
        meta_cascade_tts_voice_male=os.getenv(
            "META_CASCADE_TTS_VOICE_MALE", "bf322df2096a46f18c579d0baa36f41d"
        ),
        meta_cascade_vad_model=os.getenv("META_CASCADE_VAD_MODEL", "silero"),
        voice_isolation=_choice(
            "VOICE_ISOLATION", "krisp", _VOICE_ISOLATION_PROVIDERS
        ),
        async_voice_tts_model=os.getenv(
            "ASYNC_VOICE_TTS_MODEL", "fishaudio/s2.1-pro"
        ),
        # Fish Audio "Hannah" (a conversational specialist, feminine) — the
        # founder's selected default voice, same default as the Meta cascade
        # (``meta_cascade_tts_voice``); documented id from
        # ``voice_catalog._TTS_FALLBACK_VOICES["fishaudio"]``.
        async_voice_tts_voice=os.getenv(
            "ASYNC_VOICE_TTS_VOICE", "9a9cf47702da476aa4629e2506d4a857"
        ),
        async_voice_max_clip_bytes=int(
            os.getenv("ASYNC_VOICE_MAX_CLIP_BYTES", "8388608")
        ),
        meta_reasoning_effort=os.getenv("META_REASONING_EFFORT", "minimal"),
        open_weights_api_base_url=os.getenv(
            "OPEN_WEIGHTS_BASE_URL", ""
        ).rstrip("/"),
        open_weights_model=os.getenv("OPEN_WEIGHTS_MODEL", ""),
        open_weights_cold_start_timeout_s=float(
            os.getenv("OPEN_WEIGHTS_COLD_START_TIMEOUT_S", "120")
        ),
        open_weights_max_context_tokens=int(
            os.getenv("OPEN_WEIGHTS_MAX_CONTEXT_TOKENS", "16384")
        ),
        open_weights_response_token_margin=int(
            os.getenv("OPEN_WEIGHTS_RESPONSE_TOKEN_MARGIN", "1200")
        ),
        llm_provider_chat=os.getenv(
            "LLM_PROVIDER_CHAT", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_matching=os.getenv(
            "LLM_PROVIDER_MATCHING", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_reports=os.getenv(
            "LLM_PROVIDER_REPORTS", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_practice=os.getenv(
            "LLM_PROVIDER_PRACTICE", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        # Explicit-only (no LLM_PROVIDER inheritance): the main voice is the
        # LOCKED Gemini Live model, so a global flip must never sweep it.
        # QLOO-PHASE default = ``gemini`` (founder directive — judged BEFORE
        # Meta, best-experience stack). Flips back to ``meta`` post-Qloo.
        llm_provider_voice_main=os.getenv("LLM_PROVIDER_VOICE_MAIN", "gemini"),
        llm_provider_voice=os.getenv(
            "LLM_PROVIDER_VOICE", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        # Defaults to ``gemini`` (the funded, LiveKit-routed brain) like every
        # other surface — H1 routing-audit fix (2026-11-02): no longer pinned to
        # Meta-direct, so an unset env can never send the DM assistant off
        # LiveKit. Still per-surface overridable + Gemini-fallback-guarded.
        llm_provider_dm_coach=os.getenv(
            "LLM_PROVIDER_DM_COACH", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        # Cross-language DM translation defaults to ``gemini`` too — H2
        # routing-audit fix (2026-11-02): was Meta-direct by default (and live on
        # staging), now the LiveKit-routed brain. Per-surface overridable +
        # Gemini-fallback-guarded.
        llm_provider_translate=os.getenv(
            "LLM_PROVIDER_TRANSLATE", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_meta_fallback=os.getenv("LLM_META_FALLBACK", "true").strip().lower()
        == "true",
        # Unified Brain default (§13.10): the brain used for the text surfaces
        # when a user hasn't picked one, and shown pre-selected in the UI.
        # QLOO-PHASE default = Gemini (founder directive — Qloo is judged BEFORE
        # Meta, so new/unset users get the best-experience stack). Flips back to
        # Muse (``meta``) post-Qloo. Capability gaps still route to Gemini
        # (web/vision) via the llm_provider capability map.
        brain_default=os.getenv("AYMA_BRAIN_DEFAULT", "gemini").strip().lower(),
        # Voice ENGINE picker (§13.9).
        openai_realtime_model=os.getenv("OPENAI_REALTIME_MODEL", "gpt-realtime"),
        voice_openai_realtime_enabled=os.getenv(
            "VOICE_OPENAI_REALTIME", "false"
        ).strip().lower() == "true",
        # Cartesia STT after the credited two: ink-2 is the decided model, kept
        # alongside ink-whisper as the wide-language fallback (both ride the
        # grant-funded plugin when the agent has CARTESIA_API_KEY). Withheld
        # from served lists until that key is wired (voice_catalog gate);
        # staging credits the provider via env so the key lights it up.
        voice_cascade_stt_models=_csv(
            "VOICE_CASCADE_STT_MODELS",
            "deepgram/nova-3,assemblyai/universal-streaming,"
            "cartesia/ink-2,cartesia/ink-whisper",
        ),
        # Credited providers first (shown enabled on the fallback path), then
        # cartesia/sonic-3 — withheld from served lists until CARTESIA_API_KEY
        # is wired (voice_catalog gate; an inactive Cartesia never appears in
        # a selection list). IDs from LiveKit docs
        # (docs.livekit.io/agents/models/tts, verified 2026-10-27). Staging
        # credits cartesia via VOICE_CREDITED_PROVIDERS so the grant key
        # (Route A) lights it up with no other change; the catalog id stays
        # cartesia/sonic-3 while the plugin builds the pinned flagship
        # (cartesia_tts_model, below).
        voice_cascade_tts_models=_csv(
            "VOICE_CASCADE_TTS_MODELS",
            "inworld/inworld-tts-1,fishaudio/s2.1-pro,rime/coda,"
            "gradium/default,cartesia/sonic-3",
        ),
        # Cartesia TTS plugin model (addendum pin): the Sonic flagship,
        # passed to cartesia.TTS — NOT the catalog id (cartesia/sonic-3).
        cartesia_tts_model=os.getenv("CARTESIA_TTS_MODEL", "sonic-3.6"),
        voice_cascade_llm_models=_csv(
            "VOICE_CASCADE_LLM_MODELS",
            "google/gemini-3.8-flash,google/gemini-3.7-flash,"
            "google/gemini-3.5-flash-lite",
        ),
        voice_cascade_extra_brains=_csv("VOICE_CASCADE_EXTRA_BRAINS", ""),
        voice_credited_providers=_csv(
            "VOICE_CREDITED_PROVIDERS",
            "inworld,deepgram,fishaudio,assemblyai,rime,gradium,google,elevenlabs,openai,cartesia",
            lower=True,
        ),
        voice_accent_capable_providers=_csv(
            "VOICE_ACCENT_CAPABLE_PROVIDERS",
            "gemini,openai",
            lower=True,
        ),
        dm_viewing_window_seconds=int(
            os.getenv("DM_VIEWING_WINDOW_SECONDS", "25")
        ),
        reengage_inactive_days=int(os.getenv("REENGAGE_INACTIVE_DAYS", "3")),
        reengage_backoff_start_days=int(
            os.getenv("REENGAGE_BACKOFF_START_DAYS", "7")
        ),
        reengage_min_match_score=float(
            os.getenv("REENGAGE_MIN_MATCH_SCORE", "0.7")
        ),
        reengage_user_limit=int(os.getenv("REENGAGE_USER_LIMIT", "200")),
        rate_cron_reengage=os.getenv("RATE_CRON_REENGAGE", "2/minute"),
        rate_cron_ingest_backfill=os.getenv(
            "RATE_CRON_INGEST_BACKFILL", "2/minute"
        ),
        tokens_per_credit=int(os.getenv("TOKENS_PER_CREDIT", "1000")),
        credits_per_usd=int(os.getenv("CREDITS_PER_USD", "100")),
        free_start_grant_usd=float(os.getenv("FREE_START_GRANT_USD", "5.00")),
        free_daily_allowance_usd=float(
            os.getenv("FREE_DAILY_ALLOWANCE_USD", "1.00")
        ),
        billing_expiry_grace_seconds=int(
            os.getenv("BILLING_EXPIRY_GRACE_SECONDS", "3600")
        ),
        pro_trial_credits=int(
            os.getenv(
                "PRO_TRIAL_CREDITS",
                str(
                    round(
                        PLAN_TIERS["pro"].pool_usd
                        * int(os.getenv("CREDITS_PER_USD", "100"))
                    )
                ),
            )
        ),
        revenuecat_webhook_secret=os.getenv("REVENUECAT_WEBHOOK_SECRET", ""),
        revenuecat_secret_api_key=os.getenv("REVENUECAT_SECRET_API_KEY", ""),
        rate_webhooks=os.getenv("RATE_WEBHOOKS", "600/minute"),
        credit_free_topup_enabled=os.getenv(
            "CREDITS_FREE_TOPUP_ENABLED", "false"
        ).lower() == "true",
        credit_topup_amount=int(os.getenv("CREDIT_TOPUP_AMOUNT", "100")),
        rate_credits_topup=os.getenv("RATE_CREDITS_TOPUP", "6/minute"),
        rate_feedback=os.getenv("RATE_FEEDBACK", "20/minute"),
        instagram_app_id=os.getenv("INSTAGRAM_APP_ID", ""),
        instagram_redirect_uri=os.getenv("INSTAGRAM_REDIRECT_URI", ""),
        instagram_media_limit=int(os.getenv("INSTAGRAM_MEDIA_LIMIT", "20")),
        rate_instagram=os.getenv("RATE_INSTAGRAM", "6/minute"),
        google_import_client_id=os.getenv("GOOGLE_IMPORT_CLIENT_ID", ""),
        google_import_redirect_uri=os.getenv("GOOGLE_IMPORT_REDIRECT_URI", ""),
        google_sync_window_days=int(os.getenv("GOOGLE_SYNC_WINDOW_DAYS", "30")),
        google_gmail_limit=int(os.getenv("GOOGLE_GMAIL_LIMIT", "100")),
        google_gmail_body_limit=int(os.getenv("GOOGLE_GMAIL_BODY_LIMIT", "8")),
        google_calendar_limit=int(os.getenv("GOOGLE_CALENDAR_LIMIT", "100")),
        google_sync_min_interval_hours=int(
            os.getenv("GOOGLE_SYNC_MIN_INTERVAL_HOURS", "20")
        ),
        rate_google=os.getenv("RATE_GOOGLE", "6/minute"),
        rate_cron_google_sync=os.getenv("RATE_CRON_GOOGLE_SYNC", "2/minute"),
        rate_explore=os.getenv("RATE_EXPLORE", "60/minute"),
        rate_block=os.getenv("RATE_BLOCK", "20/minute"),
        rate_profile_share=os.getenv("RATE_PROFILE_SHARE", "20/minute"),
        rate_dm_send=os.getenv("RATE_DM_SEND", "60/minute"),
        share_base_url=os.getenv("SHARE_BASE_URL", "https://justabot.info").rstrip("/"),
        share_android_store_url=os.getenv(
            "SHARE_ANDROID_STORE_URL",
            "https://play.google.com/store/apps/details?id=com.ayma.ayma_flutter",
        ),
        share_ios_store_url=os.getenv("SHARE_IOS_STORE_URL", ""),
        share_android_package=os.getenv(
            "SHARE_ANDROID_PACKAGE", "com.ayma.ayma_flutter"
        ),
        share_assetlinks_sha256=tuple(
            f.strip()
            for f in os.getenv("SHARE_ASSETLINKS_SHA256", "").split(",")
            if f.strip()
        ),
        rate_share=os.getenv("RATE_SHARE", "20/minute"),
        rate_share_public=os.getenv("RATE_SHARE_PUBLIC", "60/minute"),
        rate_cron_match=os.getenv("RATE_CRON_MATCH", "2/minute"),
        rate_wiki_reset=os.getenv("RATE_WIKI_RESET", "3/minute"),
        rate_voice=os.getenv("RATE_VOICE", "30/minute"),
        rate_voice_preview=os.getenv("RATE_VOICE_PREVIEW", "40/minute"),
        rate_default=os.getenv("RATE_DEFAULT", "60/minute"),
        sentry_traces_sample_rate=float(
            os.getenv("SENTRY_TRACES_SAMPLE_RATE", "0.05")
        ),
        sentry_error_sample_rate=float(
            os.getenv("SENTRY_ERROR_SAMPLE_RATE", "1.0")
        ),
        sentry_enabled=os.getenv("SENTRY_ENABLED", "true").strip().lower()
        not in ("false", "0", "no", "off"),
        sentry_environment=os.getenv("SENTRY_ENVIRONMENT", "production"),
        meta_integrations=os.getenv(
            "META_INTEGRATIONS", "false"
        ).strip().lower() in ("1", "true", "yes", "on"),
        deepdive_public_profiles=os.getenv(
            "DEEPDIVE_PUBLIC_PROFILES", "true"
        ).strip().lower() in ("1", "true", "yes", "on"),
        deepdive_blocked_regions=_csv(
            "DEEPDIVE_PUBLIC_PROFILES_BLOCKED_REGIONS",
            "illinois,texas,eu",
            lower=True,
        ),
        vertex_ai_search=os.getenv("VERTEX_AI_SEARCH", "true").strip().lower()
        in ("1", "true", "yes", "on"),
        vertex_ai_search_daily_cap=int(
            os.getenv("VERTEX_AI_SEARCH_DAILY_CAP", "300")
        ),
        vertex_ai_search_engine=os.getenv(
            "VERTEX_AI_SEARCH_ENGINE", "ayma-public-web-engine"
        ),
        image_variants_enabled=os.getenv(
            "IMAGE_VARIANTS_ENABLED", "false"
        ).strip().lower() in ("1", "true", "yes", "on"),
        image_variants_push_sa=os.getenv("IMAGE_VARIANTS_PUSH_SA", "").strip(),
    )


CONFIG = _load()
