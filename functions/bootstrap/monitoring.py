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
import re

from config import CONFIG

logger = logging.getLogger(__name__)

_SCRUBBED_REQUEST_KEYS = ("data", "cookies", "headers", "query_string")

_EMAIL_RE = re.compile(r"[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+")
_PHONE_RE = re.compile(r"\+?\d[\d\s().\-]{7,}\d")

# Set once ``sentry_sdk.init`` has run; lets ``capture_exception`` stay a true
# no-op (no sentry_sdk import) when Sentry is off or the SDK is not installed.
_initialised = False


def redact_text(text: str) -> str:
    """Replace emails and phone-number-like runs with placeholders."""
    return _PHONE_RE.sub("[phone]", _EMAIL_RE.sub("[email]", text))


def scrub_event(event: dict, hint: object = None) -> dict:
    """Sentry ``before_send``: drop request bodies and other user content."""
    request = event.get("request")
    if isinstance(request, dict):
        for key in _SCRUBBED_REQUEST_KEYS:
            request.pop(key, None)
    event.pop("user", None)
    event.pop("extra", None)
    message = event.get("message")
    if isinstance(message, str):
        event["message"] = redact_text(message)
    logentry = event.get("logentry")
    if isinstance(logentry, dict):
        logentry.pop("params", None)
        for key in ("message", "formatted"):
            if isinstance(logentry.get(key), str):
                logentry[key] = redact_text(logentry[key])
    for exc in (event.get("exception") or {}).get("values", []):
        if isinstance(exc.get("value"), str):
            exc["value"] = redact_text(exc["value"])
    for crumb in (event.get("breadcrumbs") or {}).get("values", []):
        crumb.pop("data", None)
        if isinstance(crumb.get("message"), str):
            crumb["message"] = redact_text(crumb["message"])
    return event


def init_sentry(service: str) -> bool:
    """Initialise Sentry for ``service``; returns False (no-op) without a DSN
    or when the ``SENTRY_ENABLED`` kill switch is off."""
    global _initialised
    dsn = os.getenv("SENTRY_DSN", "").strip()
    if not dsn or not CONFIG.sentry_enabled:
        return False
    import sentry_sdk

    sentry_sdk.init(
        dsn=dsn,
        environment=CONFIG.sentry_environment,
        release=CONFIG.version,
        sample_rate=CONFIG.sentry_error_sample_rate,
        traces_sample_rate=CONFIG.sentry_traces_sample_rate,
        send_default_pii=False,
        max_request_body_size="never",
        before_send=scrub_event,
    )
    sentry_sdk.set_tag("service", service)
    _initialised = True
    logger.info("sentry enabled for %s", service)
    return True


def capture_exception(exc: BaseException | None = None) -> None:
    """Report ``exc`` (or the exception being handled); no-op when disabled."""
    if not _initialised:
        return
    import sentry_sdk

    sentry_sdk.capture_exception(exc)
