"""Firebase ID-token verification for the Main API.

Every non-``/cron`` endpoint verifies the caller's Firebase ID token with the
Admin SDK on every request (ARCHITECTURE §3.4). Step 6 introduces the minimum:
a FastAPI dependency that extracts the Bearer token and returns the uid. The
shared middleware wrapper over *every* route is Step 67 (§10.6 step 3).
"""

from __future__ import annotations

import hmac
from dataclasses import dataclass

import firebase_admin
from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth as firebase_auth

from config import CONFIG

# Admin SDK credentials resolve automatically:
#   * Cloud Run  -> the service's runtime identity (no key file)
#   * local dev  -> GOOGLE_APPLICATION_CREDENTIALS from .env.local
if not firebase_admin._apps:
    firebase_admin.initialize_app()

_bearer = HTTPBearer(auto_error=True)


@dataclass(frozen=True)
class Caller:
    uid: str
    is_anonymous: bool
    sign_in_provider: str


def _verify(token: str) -> dict:
    try:
        return firebase_auth.verify_id_token(token)
    except (firebase_auth.InvalidIdTokenError, firebase_auth.ExpiredIdTokenError,
            firebase_auth.RevokedIdTokenError, firebase_auth.CertificateFetchError,
            ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid ID token: {exc}",
        ) from exc


async def require_uid(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> str:
    """Verify the Bearer ID token; return the authenticated uid or raise 401."""
    return _verify(credentials.credentials)["uid"]


async def require_caller(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> Caller:
    """Like :func:`require_uid` but also exposes auth state — used where
    ``session_mode`` is derived (§3.3)."""
    decoded = _verify(credentials.credentials)
    provider = (decoded.get("firebase") or {}).get("sign_in_provider", "")
    return Caller(
        uid=decoded["uid"],
        is_anonymous=provider == "anonymous",
        sign_in_provider=provider,
    )


def is_dev_token(decoded: dict) -> bool:
    """Whether a verified ID token belongs to the founder/dev allowlist
    (``CONFIG.dev_view_uids`` / ``CONFIG.dev_view_emails``). An email only
    counts when Firebase reports it verified — an unverified account can claim
    any address."""
    if decoded.get("uid") in CONFIG.dev_view_uids:
        return True
    email = str(decoded.get("email") or "").strip().lower()
    return (
        bool(email)
        and decoded.get("email_verified") is True
        and email in CONFIG.dev_view_emails
    )


async def require_uid_and_dev_flag(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> tuple[str, bool]:
    """Like :func:`require_uid` but also reports whether the caller is on the
    dev-view allowlist — for routes that serve everyone but show the dev extra
    (dollar figures in ``GET /usage``, the free top-up)."""
    decoded = _verify(credentials.credentials)
    return decoded["uid"], is_dev_token(decoded)


async def require_dev(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> str:
    """Verify the ID token AND require the dev-view allowlist; 403 otherwise."""
    decoded = _verify(credentials.credentials)
    if not is_dev_token(decoded):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Dev view only."
        )
    return decoded["uid"]


async def require_admin(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> str:
    """Verify the ID token AND require the ``admin: true`` custom claim (§3.5).
    Gates endpoints that expose the ``ai_only`` wiki tier or
    ``deleted_accounts/*``. Returns the admin's uid."""
    decoded = _verify(credentials.credentials)
    if decoded.get("admin") is not True:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Admin only."
        )
    return decoded["uid"]


async def require_admin_password(
    x_admin_password: str | None = Header(default=None),
) -> None:
    """Gate the ``/admin/*`` console on the ``X-Admin-Password`` header
    (§14.3, §12.3). Fails closed when ``ADMIN_PASSWORD`` is unset."""
    expected = CONFIG.admin_password
    if not expected or not x_admin_password or not hmac.compare_digest(
        x_admin_password, expected
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Bad admin password."
        )


async def require_cron(
    x_cron_secret: str | None = Header(default=None),
) -> None:
    """Gate a ``/cron/*`` route on the shared ``X-Cron-Secret`` header (§10.5).

    Refuses everything when ``CRON_SECRET`` is unset, so a misconfigured deploy
    fails closed rather than exposing the job endpoints. The shared middleware
    over every ``/cron/*`` route is Step 67.
    """
    expected = CONFIG.cron_secret
    if not expected or not x_cron_secret or not hmac.compare_digest(
        x_cron_secret, expected
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Bad cron secret."
        )


async def require_revenuecat(
    authorization: str | None = Header(default=None),
) -> None:
    """Gate ``POST /webhooks/revenuecat`` on the shared secret RevenueCat sends
    in its ``Authorization`` header. Fails closed (403) when
    ``REVENUECAT_WEBHOOK_SECRET`` is unset or the header doesn't match."""
    import billing

    if not billing.authorized(authorization, CONFIG):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Bad webhook secret."
        )
