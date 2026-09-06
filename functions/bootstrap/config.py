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
    on. LOCKED to ``gemini-3.1-flash-live-preview`` — the newest Live model,
    Developer-API-only (not on Vertex / Agent Platform)."""

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

    token_cap_per_user: int
    """Lifetime Gemini-token budget per user across chat / voice / icebreakers
    / matching / wiki. At the cap, metered calls are refused with a friendly
    message. Default 100_000."""

    tokens_per_credit: int
    """Display ratio: how many Gemini tokens one user-facing *credit* is worth.
    Credits are a pure display layer over ``token_usage.total`` — nothing is
    stored per credit. Default 1_000 (so the 100k token cap == 100 credits)."""

    credits_free_grant: int
    """Credits every account starts with (the free plan). A per-user override
    lives in ``users/{uid}.credit_grant`` for future paid tiers. Default 100."""

    credit_cost_match_score: int
    """Shown-cost of one on-demand pairwise compatibility check
    (``POST /check-compatibility`` — one Gemini call over both wikis).
    Default 12. Only actions that spend Gemini tokens carry a credit cost;
    Pass-1 pool matching (``/run-matching``) is heuristic-only and free."""

    credit_topup_amount: int
    """Credits added per ``POST /credits/topup`` — a free reload for now
    (no payment). Default 100."""

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

    rate_explore: str
    rate_block: str
    rate_profile_share: str
    rate_dm_send: str
    rate_cron_match: str
    rate_wiki_reset: str
    rate_voice: str
    rate_voice_preview: str
    """Rate limit for ``GET /voice/preview/{voice_name}`` (§10.4). Tighter than
    ``rate_voice`` — a cache miss runs a Gemini TTS call."""
    rate_default: str
    """Per-endpoint limits for the remaining §10.2 routes (§10.4, §10.6 step 2).
    ``rate_default`` is the fallback the middleware applies to any route not in
    its explicit table — so no endpoint ships without a limit."""

    rate_notifications: str
    """Rate limit for ``POST /notifications/*`` client routes (§10.4)."""


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
            "GEMINI_LIVE_DEV_MODEL", "gemini-3.1-flash-live-preview"
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
        gemini_tts_model=os.getenv(
            "GEMINI_TTS_MODEL", "gemini-2.5-flash-preview-tts"
        ),
        image_embedding_model=os.getenv(
            "IMAGE_EMBEDDING_MODEL", "gemini-embedding-2"
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
        notifications_limit=int(os.getenv("NOTIFICATIONS_LIMIT", "50")),
        push_preview_len=int(os.getenv("PUSH_PREVIEW_LEN", "100")),
        push_cooldown_seconds=int(os.getenv("PUSH_COOLDOWN_SECONDS", "900")),
        max_fcm_tokens=int(os.getenv("MAX_FCM_TOKENS", "10")),
        rate_notifications=os.getenv("RATE_NOTIFICATIONS", "20/minute"),
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
        token_cap_per_user=int(os.getenv("TOKEN_CAP_PER_USER", "100000")),
        tokens_per_credit=int(os.getenv("TOKENS_PER_CREDIT", "1000")),
        credits_free_grant=int(os.getenv("CREDITS_FREE_GRANT", "100")),
        credit_cost_match_score=int(os.getenv("CREDIT_COST_MATCH_SCORE", "12")),
        credit_topup_amount=int(os.getenv("CREDIT_TOPUP_AMOUNT", "100")),
        rate_credits_topup=os.getenv("RATE_CREDITS_TOPUP", "6/minute"),
        rate_feedback=os.getenv("RATE_FEEDBACK", "20/minute"),
        instagram_app_id=os.getenv("INSTAGRAM_APP_ID", ""),
        instagram_redirect_uri=os.getenv("INSTAGRAM_REDIRECT_URI", ""),
        instagram_media_limit=int(os.getenv("INSTAGRAM_MEDIA_LIMIT", "20")),
        rate_instagram=os.getenv("RATE_INSTAGRAM", "6/minute"),
        rate_explore=os.getenv("RATE_EXPLORE", "60/minute"),
        rate_block=os.getenv("RATE_BLOCK", "20/minute"),
        rate_profile_share=os.getenv("RATE_PROFILE_SHARE", "20/minute"),
        rate_dm_send=os.getenv("RATE_DM_SEND", "60/minute"),
        rate_cron_match=os.getenv("RATE_CRON_MATCH", "2/minute"),
        rate_wiki_reset=os.getenv("RATE_WIKI_RESET", "3/minute"),
        rate_voice=os.getenv("RATE_VOICE", "30/minute"),
        rate_voice_preview=os.getenv("RATE_VOICE_PREVIEW", "10/minute"),
        rate_default=os.getenv("RATE_DEFAULT", "60/minute"),
    )


CONFIG = _load()
