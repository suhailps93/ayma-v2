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

    rate_bootstrap: str
    rate_chat_text: str
    """Per-endpoint rate limits (§10.4 — every endpoint has a ``RATE_*``).
    Format ``<n>/<window>`` (e.g. ``30/minute``). Enforcement middleware is
    Step 67; these values exist now so no endpoint ships without one."""

    rate_cron_lint: str
    """Rate limit for ``POST /cron/lint`` (§10.4)."""

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
        rate_bootstrap=os.getenv("RATE_BOOTSTRAP", "30/minute"),
        rate_chat_text=os.getenv("RATE_CHAT_TEXT", "20/minute"),
        rate_cron_lint=os.getenv("RATE_CRON_LINT", "2/minute"),
        cron_secret=os.getenv("CRON_SECRET", ""),
        gemini_model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash"),
        gemini_live_model=os.getenv(
            "GEMINI_LIVE_MODEL", "gemini-live-2.5-flash"
        ),
        gemini_live_voice=os.getenv("GEMINI_LIVE_VOICE", "Aoede"),
        use_vertex=os.getenv("USE_VERTEX", "true").lower() == "true",
        vertex_location=os.getenv("VERTEX_LOCATION", "us-central1"),
        livekit_url=os.getenv("LIVEKIT_URL", ""),
        livekit_room_prefix=os.getenv("LIVEKIT_ROOM_PREFIX", "ayma-"),
        livekit_token_ttl_seconds=int(
            os.getenv("LIVEKIT_TOKEN_TTL_SECONDS", "900")
        ),
    )


CONFIG = _load()
