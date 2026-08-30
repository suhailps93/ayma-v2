"""Firebase ID-token verification for the Main API.

Every non-``/cron`` endpoint verifies the caller's Firebase ID token with the
Admin SDK on every request (ARCHITECTURE §3.4). Step 6 introduces the minimum:
a FastAPI dependency that extracts the Bearer token and returns the uid. The
shared middleware wrapper over *every* route is Step 67 (§10.6 step 3).
"""

from __future__ import annotations

import firebase_admin
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth as firebase_auth

# Admin SDK credentials resolve automatically:
#   * Cloud Run  -> the service's runtime identity (no key file)
#   * local dev  -> GOOGLE_APPLICATION_CREDENTIALS from .env.local
if not firebase_admin._apps:
    firebase_admin.initialize_app()

_bearer = HTTPBearer(auto_error=True)


async def require_uid(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> str:
    """Verify the Bearer ID token; return the authenticated uid or raise 401."""
    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials)
    except (firebase_auth.InvalidIdTokenError, firebase_auth.ExpiredIdTokenError,
            firebase_auth.RevokedIdTokenError, firebase_auth.CertificateFetchError,
            ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid ID token: {exc}",
        ) from exc
    return decoded["uid"]
