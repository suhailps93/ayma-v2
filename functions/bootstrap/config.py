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

    gemini_model: str
    """The Gemini model id for text chat. Per ``AGENTS.md`` every Gemini model
    string flows from this module — nowhere else may hardcode one."""

    gemini_live_model: str
    """The Gemini Live model id for the voice agent worker (§1.1). Same
    ``AGENTS.md`` rule — the agent worker reads it from here, never hardcodes."""

    gemini_live_voice: str
    """Default Gemini Live built-in HD voice preset the agent speaks with
    (§13.3). Overridden per-user by ``ayma_voice_name`` in a later step."""

    image_embedding_model: str
    """Vertex multimodal-embedding model id for face/photo embeddings (§2.5).
    Same ``AGENTS.md`` rule — model strings live only here."""

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
        gemini_model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash"),
        gemini_live_model=os.getenv(
            "GEMINI_LIVE_MODEL", "gemini-live-2.5-flash"
        ),
        gemini_live_voice=os.getenv("GEMINI_LIVE_VOICE", "Aoede"),
        image_embedding_model=os.getenv(
            "IMAGE_EMBEDDING_MODEL", "multimodalembedding@001"
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
    )


CONFIG = _load()
