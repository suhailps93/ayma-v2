"""Sentry error monitoring, shared by the Main API and the voice agent worker.

Gated on ``SENTRY_DSN`` (a secret, mounted from Secret Manager in deployment):
with no DSN — local dev, tests — ``init_sentry`` does nothing and
``capture_exception`` is a no-op. Events never carry user content: request
bodies, cookies, headers and any message / transcript / profile text are
stripped in ``scrub_event`` before anything leaves the process.
"""

from __future__ import annotations

import logging
import os

from config import CONFIG

logger = logging.getLogger(__name__)

_SCRUBBED_REQUEST_KEYS = ("data", "cookies", "headers", "query_string")


def scrub_event(event: dict, hint: object = None) -> dict:
    """Sentry ``before_send``: drop request bodies and other user content."""
    request = event.get("request")
    if isinstance(request, dict):
        for key in _SCRUBBED_REQUEST_KEYS:
            request.pop(key, None)
    event.pop("user", None)
    for crumb in (event.get("breadcrumbs") or {}).get("values", []):
        crumb.pop("data", None)
    return event


def init_sentry(service: str) -> bool:
    """Initialise Sentry for ``service``; returns False (no-op) without a DSN."""
    dsn = os.getenv("SENTRY_DSN", "").strip()
    if not dsn:
        return False
    import sentry_sdk

    sentry_sdk.init(
        dsn=dsn,
        environment=CONFIG.sentry_environment,
        release=CONFIG.version,
        traces_sample_rate=CONFIG.sentry_traces_sample_rate,
        send_default_pii=False,
        max_request_body_size="never",
        before_send=scrub_event,
    )
    sentry_sdk.set_tag("service", service)
    logger.info("sentry enabled for %s", service)
    return True


def capture_exception(exc: BaseException | None = None) -> None:
    """Report ``exc`` (or the exception being handled); no-op when disabled."""
    import sentry_sdk

    if sentry_sdk.is_initialized():
        sentry_sdk.capture_exception(exc)
