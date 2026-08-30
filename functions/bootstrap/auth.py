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
