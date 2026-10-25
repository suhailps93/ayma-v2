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

    bootstrap_stub_session_mode: str
    """Hardcoded `session_mode` returned by ``POST /bootstrap`` until real
    server-side derivation lands (Step 34 / §3.3). One of
    ``marketing`` / ``interview`` / ``active``."""

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

    admin_password: str
    """Password the ``/admin/*`` console checks against the ``X-Admin-Password``
    header (§14.3). From Secret Manager in deployment (§12.3); an unset value
    makes every ``/admin/*`` route refuse."""

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
    """Opt-in: run the voice agent on the **Gemini Developer API** (with a
    ``GOOGLE_API_KEY`` from Secret Manager, mounted on ``ayma-agent`` only)
    instead of Vertex, so it can use ``gemini_live_dev_model``. Default False —
    Vertex + ``gemini_live_model`` needs no key and is the launch default.
    Flip with ``GEMINI_LIVE_USE_DEV_API=true`` on the agent service."""

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
    tone/emotion and answers with matching prosody. **Off by default** — the
    Live model we run rejects session setup when it's set, which breaks voice
    outright. Set ``GEMINI_LIVE_AFFECTIVE_DIALOG=true`` only on a native-audio
    Live model."""

    gemini_live_proactivity: bool
    """Native-audio-only Live feature: Ayma can volunteer a thought or skip a
    reply that doesn't need one. **Off by default** for the same reason as
    ``gemini_live_affective_dialog``; ``GEMINI_LIVE_PROACTIVITY=true`` to opt
    in on a native-audio model."""

    gemini_web_search: bool
    """Let Ayma's **text** chat ground answers on live Google Search + read
    URLs the user pastes (``google_search`` + ``url_context`` built-in tools,
    alongside the session function tools). On by default;
    ``GEMINI_WEB_SEARCH=false`` to disable. Voice is unaffected — the Live
    model wires search separately."""

    gemini_maps_api_key: str
    """Maps Platform API key for **Google Maps grounding** in text chat (place
    lookups — "good third-date spots near me"). Empty = Maps grounding off.
    Provide via the ``GEMINI_MAPS_API_KEY`` secret once the Maps Grounding API
    is enabled on the project and a browser-key restriction is set."""

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
    """True → call Gemini via Vertex AI with the runtime service identity (no
    API key, §12.3). False → Gemini Developer API with ``GOOGLE_API_KEY``."""

    vertex_location: str

    livekit_url: str
    """Public LiveKit Cloud ``wss://`` endpoint the client connects to (§1.1).
    Non-secret — the API key/secret used to *sign* room tokens are read from the
    environment at the call site, never stored here."""

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

    notifications_limit: int
    """Most-recent ``users/{uid}/notifications`` the client lists (§7.3)."""

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
    (internal). $0.25 == 25 credits. Resets at 00:00 UTC, never accumulates.
    Applies to the free plan only."""

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
    """Rate limit for ``POST /feedback`` and ``POST /product-feedback``
    (§10.4, §15)."""

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

    rate_notifications: str
    """Rate limit for ``POST /notifications/*`` client routes (§10.4)."""
    voice_opener_grace_seconds: float
    """Voice calls: how long Ayma waits for the caller to speak first before
    opening the conversation herself. ``0`` (or negative) disables the opener."""


def _csv(name: str, default: str, *, lower: bool = False) -> tuple[str, ...]:
    raw = os.getenv(name, default)
    items = (x.strip() for x in raw.split(","))
    return tuple((x.lower() if lower else x) for x in items if x)


def _load() -> Config:
    return Config(
        project_id=(
            os.getenv("GOOGLE_CLOUD_PROJECT")
            or os.getenv("GCLOUD_PROJECT")
            or ""
        ),
        version=os.getenv("APP_VERSION", "0.1.0"),
        bootstrap_stub_session_mode=os.getenv(
            "BOOTSTRAP_STUB_SESSION_MODE", "marketing"
        ),
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
        admin_password=os.getenv("ADMIN_PASSWORD", ""),
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
        gemini_web_search=os.getenv("GEMINI_WEB_SEARCH", "true").lower()
        == "true",
        gemini_maps_api_key=os.getenv("GEMINI_MAPS_API_KEY", ""),
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
        gemini_image_edit_model=os.getenv(
            "GEMINI_IMAGE_EDIT_MODEL", "gemini-2.5-flash-image"
        ),
        storage_bucket=os.getenv(
            "STORAGE_BUCKET", "ayma-ai.firebasestorage.app"
        ),
        use_vertex=os.getenv("USE_VERTEX", "true").lower() == "true",
        vertex_location=os.getenv("VERTEX_LOCATION", "us-central1"),
        livekit_url=os.getenv("LIVEKIT_URL", ""),
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
        notifications_limit=int(os.getenv("NOTIFICATIONS_LIMIT", "50")),
        push_preview_len=int(os.getenv("PUSH_PREVIEW_LEN", "100")),
        push_cooldown_seconds=int(os.getenv("PUSH_COOLDOWN_SECONDS", "900")),
        max_fcm_tokens=int(os.getenv("MAX_FCM_TOKENS", "10")),
        rate_notifications=os.getenv("RATE_NOTIFICATIONS", "20/minute"),
        voice_opener_grace_seconds=float(
            os.getenv("VOICE_OPENER_GRACE_SECONDS", "1.5")
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
            os.getenv("FREE_DAILY_ALLOWANCE_USD", "0.25")
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
    )


CONFIG = _load()
