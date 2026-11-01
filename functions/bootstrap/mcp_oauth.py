"""OAuth 2.1 Device Authorization Grant (RFC 8628) for the Ayma MCP server.

This is the "open a code" flow that lets an EXTERNAL MCP client (e.g. Claude)
act on behalf of a specific Ayma user without ever seeing the user's Firebase
credentials:

1. The client POSTs to ``/mcp/oauth/device_authorization`` and gets back a
   short, human-typeable ``user_code`` plus an opaque ``device_code``.
2. The already-signed-in user opens Ayma's "Connect an agent" screen, types the
   ``user_code``, and approves (the Flutter app calls ``/mcp/connect/approve``
   with the user's Firebase ID token — the approval is bound to THAT uid).
3. The client polls ``/mcp/oauth/token`` and, once approved, receives an opaque
   per-user access token scoped to that uid.

Design choices (see ``docs/MCP_SERVER.md`` for the full rationale):

* **Opaque tokens, not JWTs.** An access token is a random string; only its
  SHA-256 hash is stored (``mcp_tokens/{hash}``). Validation is a Firestore
  lookup, so **no signing key / secret is required** and a token can be revoked
  instantly by flipping ``revoked``. The raw token is never persisted.
* **Per-user, revocable, expiring.** Every token carries a uid, a scope set and
  an ``expires_at``; the user can list and revoke their connected agents.
* **The MCP client model is the brain; Ayma is the hands.** These endpoints
  grant access to data/skills tools only — nothing here spends an Ayma LLM.

This module is FastAPI-free (pure Firestore logic) so it is unit-testable
against the in-memory fake and importable without the web stack.
"""

from __future__ import annotations

import hashlib
import logging
import secrets
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from timefmt import utcnow
from firebase_admin import firestore

logger = logging.getLogger("ayma.mcp.oauth")

DEVICE_CODES_COLLECTION = "mcp_device_codes"
TOKENS_COLLECTION = "mcp_tokens"

# RFC 8628 grant type the token endpoint requires.
DEVICE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"

TOKEN_PREFIX = "aymcp_"  # so a leaked token is greppable / recognisable

# Lifetimes.
DEVICE_CODE_TTL_SECONDS = 600  # the user has 10 minutes to approve
POLL_INTERVAL_SECONDS = 5  # minimum client poll interval (RFC 8628 `interval`)

# user_code alphabet: no 0/O/1/I/L to stay unambiguous when read aloud/typed.
_USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
_USER_CODE_LEN = 8  # rendered as XXXX-XXXX

# Status values on a device-code doc.
STATUS_PENDING = "pending"
STATUS_APPROVED = "approved"
STATUS_DENIED = "denied"
STATUS_REDEEMED = "redeemed"

# ---- Scopes -------------------------------------------------------------- #
SCOPE_PROFILE_READ = "profile:read"
SCOPE_PROFILE_WRITE = "profile:write"
SCOPE_MATCHES_READ = "matches:read"
SCOPE_DM_READ = "dm:read"
SCOPE_DM_SEND = "dm:send"
SCOPE_PERSONA_READ = "persona:read"

ALL_SCOPES = (
    SCOPE_PROFILE_READ,
    SCOPE_PROFILE_WRITE,
    SCOPE_MATCHES_READ,
    SCOPE_DM_READ,
    SCOPE_DM_SEND,
    SCOPE_PERSONA_READ,
)

# Token validation cache: token_hash -> (Principal, cached_monotonic). Short TTL
# so a revoke / expiry takes effect within seconds while keeping the hot path to
# ~zero Firestore reads under a burst of tool calls.
_TOKEN_CACHE_TTL = 10.0
_token_cache: dict[str, tuple["Principal", float]] = {}
_TOKEN_CACHE_MAX = 5000


@dataclass(frozen=True)
class Principal:
    """The authenticated identity behind an MCP access token."""

    uid: str
    scopes: frozenset[str]
    token_id: str  # the SHA-256 hash (doc id), never the raw token
    client_id: str

    def has_scope(self, scope: str) -> bool:
        return scope in self.scopes


class OAuthError(Exception):
    """An RFC 6749 / 8628 error code carried to the token/authorize endpoints.

    ``status`` is the HTTP status to use; ``code`` is the OAuth error code."""

    def __init__(self, code: str, status: int = 400, description: str = ""):
        super().__init__(description or code)
        self.code = code
        self.status = status
        self.description = description


# ---- helpers ------------------------------------------------------------- #



def _as_aware(value) -> datetime | None:
    """A stored Firestore timestamp / datetime as a tz-aware UTC datetime."""
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return None


def _hash(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _gen_user_code() -> str:
    body = "".join(secrets.choice(_USER_CODE_ALPHABET) for _ in range(_USER_CODE_LEN))
    return f"{body[:4]}-{body[4:]}"


def normalize_user_code(value: str) -> str:
    """Uppercase, strip spaces, and re-insert the dash so ``abcd1234`` /
    ``ABCD 1234`` / ``abcd-1234`` all match the stored ``ABCD-1234``."""
    cleaned = "".join(
        c for c in (value or "").upper() if c in _USER_CODE_ALPHABET
    )
    if len(cleaned) == _USER_CODE_LEN:
        return f"{cleaned[:4]}-{cleaned[4:]}"
    return (value or "").strip().upper()


def sanitize_scopes(scope_text: str | None, requested: list[str] | None = None) -> list[str]:
    """The valid, de-duplicated subset of a requested scope string/list,
    preserving :data:`ALL_SCOPES` order. Empty request -> the full set."""
    raw: list[str] = []
    if scope_text:
        raw.extend(scope_text.replace(",", " ").split())
    if requested:
        raw.extend(requested)
    picked = {s.strip() for s in raw if s.strip()}
    chosen = [s for s in ALL_SCOPES if s in picked]
    return chosen or list(ALL_SCOPES)


# ---- device authorization ------------------------------------------------ #


def create_device_code(db, client_id: str, scope_text: str | None) -> dict:
    """Start a device-authorization request; returns the RFC 8628 response
    fields (minus the ``verification_uri`` the HTTP layer adds)."""
    client_id = (client_id or "unknown-client").strip()[:200]
    scopes = sanitize_scopes(scope_text)
    device_code = TOKEN_PREFIX + secrets.token_urlsafe(32)

    # Generate a user_code not currently live (collisions are astronomically
    # unlikely, but a live duplicate would make approval ambiguous).
    user_code = _gen_user_code()
    for _ in range(5):
        existing = list(
            db.collection(DEVICE_CODES_COLLECTION)
            .where("user_code", "==", user_code)
            .where("status", "==", STATUS_PENDING)
            .limit(1)
            .stream()
        )
        if not existing:
            break
        user_code = _gen_user_code()

    now = utcnow()
    db.collection(DEVICE_CODES_COLLECTION).document(device_code).set(
        {
            "user_code": user_code,
            "client_id": client_id,
            "scope": scopes,
            "uid": None,
            "status": STATUS_PENDING,
            "created_at": now,
            "expires_at": now + timedelta(seconds=DEVICE_CODE_TTL_SECONDS),
            "last_polled_at": None,
        }
    )
    logger.info("mcp device_authorization client=%s user_code=%s", client_id, user_code)
    return {
        "device_code": device_code,
        "user_code": user_code,
        "scope": " ".join(scopes),
        "expires_in": DEVICE_CODE_TTL_SECONDS,
        "interval": POLL_INTERVAL_SECONDS,
    }


def lookup_by_user_code(db, user_code: str) -> tuple[str, dict] | None:
    """The pending device-code ``(device_code, doc)`` for a ``user_code``, or
    ``None`` when there is no live pending request for it."""
    code = normalize_user_code(user_code)
    if not code:
        return None
    snaps = list(
        db.collection(DEVICE_CODES_COLLECTION)
        .where("user_code", "==", code)
        .where("status", "==", STATUS_PENDING)
        .limit(1)
        .stream()
    )
    if not snaps:
        return None
    doc = snaps[0].to_dict() or {}
    exp = _as_aware(doc.get("expires_at"))
    if exp is not None and exp < utcnow():
        return None
    return snaps[0].id, doc


def approve(db, uid: str, user_code: str, scopes: list[str] | None = None) -> dict:
    """Bind a pending device code to ``uid`` and approve it (called from the
    in-app "Connect an agent" screen, authenticated as the user). ``scopes``, if
    given, narrows the originally-requested set — never widens it.

    Raises :class:`OAuthError` (``invalid_request`` / ``expired_token``) when
    the code is unknown or already expired."""
    found = lookup_by_user_code(db, user_code)
    if not found:
        raise OAuthError("invalid_request", 404, "Unknown or expired code.")
    device_code, doc = found
    requested = list(doc.get("scope") or ALL_SCOPES)
    granted = requested
    if scopes:
        narrowed = [s for s in requested if s in set(scopes)]
        granted = narrowed or requested
    db.collection(DEVICE_CODES_COLLECTION).document(device_code).set(
        {
            "uid": uid,
            "scope": granted,
            "status": STATUS_APPROVED,
            "approved_at": utcnow(),
        },
        merge=True,
    )
    logger.info("mcp approve uid=%s client=%s scopes=%s", uid, doc.get("client_id"), granted)
    return {"client_id": doc.get("client_id"), "scope": granted}


def deny(db, uid: str, user_code: str) -> dict:
    """Mark a pending device code denied (the user declined in-app)."""
    found = lookup_by_user_code(db, user_code)
    if not found:
        raise OAuthError("invalid_request", 404, "Unknown or expired code.")
    device_code, doc = found
    db.collection(DEVICE_CODES_COLLECTION).document(device_code).set(
        {"uid": uid, "status": STATUS_DENIED, "denied_at": utcnow()}, merge=True
    )
    return {"client_id": doc.get("client_id")}


def pending_details(db, user_code: str) -> dict | None:
    """What the in-app approval screen shows before the user approves:
    ``{client_id, scope, expires_at}`` or ``None`` if there's no live code."""
    found = lookup_by_user_code(db, user_code)
    if not found:
        return None
    _, doc = found
    exp = _as_aware(doc.get("expires_at"))
    return {
        "client_id": doc.get("client_id"),
        "scope": list(doc.get("scope") or []),
        "expires_at": exp.isoformat() if exp else None,
    }


# ---- token endpoint (polling) -------------------------------------------- #


def redeem(db, device_code: str, client_id: str, token_ttl_days: int) -> dict:
    """The RFC 8628 token-endpoint poll. Returns the token response once
    approved; raises :class:`OAuthError` with ``authorization_pending`` /
    ``slow_down`` / ``access_denied`` / ``expired_token`` otherwise."""
    ref = db.collection(DEVICE_CODES_COLLECTION).document(device_code or "")
    snap = ref.get()
    doc = snap.to_dict() if getattr(snap, "exists", False) else None
    if not doc:
        raise OAuthError("invalid_grant", 400, "Unknown device_code.")
    if (doc.get("client_id") or "") != (client_id or "").strip():
        raise OAuthError("invalid_client", 401, "client_id mismatch.")

    exp = _as_aware(doc.get("expires_at"))
    if exp is not None and exp < utcnow():
        raise OAuthError("expired_token", 400, "The device code has expired.")

    status = doc.get("status")
    if status == STATUS_DENIED:
        raise OAuthError("access_denied", 400, "The user denied the request.")
    if status == STATUS_REDEEMED:
        # A device code is single-use; a second redemption is an error.
        raise OAuthError("invalid_grant", 400, "This code was already used.")
    if status == STATUS_PENDING:
        # Enforce the minimum poll interval (RFC 8628 slow_down).
        last = _as_aware(doc.get("last_polled_at"))
        now = utcnow()
        ref.set({"last_polled_at": now}, merge=True)
        if last is not None and (now - last).total_seconds() < POLL_INTERVAL_SECONDS - 1:
            raise OAuthError("slow_down", 400, "Polling too fast.")
        raise OAuthError("authorization_pending", 400, "Waiting for approval.")

    # Approved -> mint an opaque access token, mark the code redeemed.
    uid = doc.get("uid")
    scopes = list(doc.get("scope") or ALL_SCOPES)
    if not uid:
        raise OAuthError("authorization_pending", 400, "Waiting for approval.")
    raw, _ = issue_token(
        db, uid=uid, client_id=doc.get("client_id") or client_id,
        scopes=scopes, token_ttl_days=token_ttl_days,
        source_device_code=snap.id,
    )
    ref.set({"status": STATUS_REDEEMED, "redeemed_at": utcnow()}, merge=True)
    return {
        "access_token": raw,
        "token_type": "Bearer",
        "expires_in": token_ttl_days * 86400,
        "scope": " ".join(scopes),
    }


# ---- access tokens ------------------------------------------------------- #


def issue_token(
    db, *, uid: str, client_id: str, scopes: list[str], token_ttl_days: int,
    source_device_code: str | None = None,
) -> tuple[str, str]:
    """Mint and store a new opaque access token for ``uid``. Returns
    ``(raw_token, token_id)``; only the hash (``token_id``) is persisted."""
    raw = TOKEN_PREFIX + secrets.token_urlsafe(32)
    token_id = _hash(raw)
    now = utcnow()
    db.collection(TOKENS_COLLECTION).document(token_id).set(
        {
            "uid": uid,
            "client_id": (client_id or "unknown-client")[:200],
            "scope": list(scopes),
            "created_at": now,
            "expires_at": now + timedelta(days=max(1, token_ttl_days)),
            "revoked": False,
            "last_used_at": None,
            "source_device_code": source_device_code,
        }
    )
    logger.info("mcp token issued uid=%s client=%s scopes=%s", uid, client_id, scopes)
    return raw, token_id


def resolve_token(db, raw_token: str) -> Principal | None:
    """Validate a raw Bearer token -> :class:`Principal`, or ``None`` when it is
    unknown, revoked or expired. Cached briefly (:data:`_TOKEN_CACHE_TTL`)."""
    if not raw_token or not raw_token.startswith(TOKEN_PREFIX):
        return None
    token_id = _hash(raw_token)
    hit = _token_cache.get(token_id)
    if hit and (time.monotonic() - hit[1]) < _TOKEN_CACHE_TTL:
        return hit[0]
    try:
        snap = db.collection(TOKENS_COLLECTION).document(token_id).get()
    except Exception:  # noqa: BLE001 - a lookup failure fails closed
        logger.exception("mcp token lookup failed")
        return None
    if not getattr(snap, "exists", False):
        return None
    doc = snap.to_dict() or {}
    if doc.get("revoked"):
        return None
    exp = _as_aware(doc.get("expires_at"))
    if exp is not None and exp < utcnow():
        return None
    uid = doc.get("uid")
    if not uid:
        return None
    principal = Principal(
        uid=uid,
        scopes=frozenset(doc.get("scope") or ()),
        token_id=token_id,
        client_id=doc.get("client_id") or "",
    )
    if len(_token_cache) >= _TOKEN_CACHE_MAX:
        _token_cache.clear()
    _token_cache[token_id] = (principal, time.monotonic())
    return principal


def touch_token(db, token_id: str) -> None:
    """Best-effort ``last_used_at`` stamp (for the user's connected-agents
    list). Throttled implicitly by the resolve cache around it."""
    try:
        db.collection(TOKENS_COLLECTION).document(token_id).set(
            {"last_used_at": firestore.SERVER_TIMESTAMP}, merge=True
        )
    except Exception:  # noqa: BLE001
        pass


def list_tokens(db, uid: str) -> list[dict]:
    """The user's active (non-revoked, non-expired) access tokens for the
    "connected agents" management screen. Never returns a raw token."""
    out: list[dict] = []
    now = utcnow()
    try:
        snaps = list(
            db.collection(TOKENS_COLLECTION).where("uid", "==", uid).stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("mcp list_tokens failed uid=%s", uid)
        return []
    for snap in snaps:
        d = snap.to_dict() or {}
        if d.get("revoked"):
            continue
        exp = _as_aware(d.get("expires_at"))
        if exp is not None and exp < now:
            continue
        created = _as_aware(d.get("created_at"))
        used = _as_aware(d.get("last_used_at"))
        out.append(
            {
                "token_id": snap.id,
                "client_id": d.get("client_id") or "",
                "scope": list(d.get("scope") or []),
                "created_at": created.isoformat() if created else None,
                "last_used_at": used.isoformat() if used else None,
                "expires_at": exp.isoformat() if exp else None,
            }
        )
    out.sort(key=lambda r: r.get("created_at") or "", reverse=True)
    return out


def revoke_token(db, uid: str, token_id: str) -> bool:
    """Revoke one of ``uid``'s tokens by id (the connected-agents screen).
    Returns whether a matching, owned token was found."""
    snap = db.collection(TOKENS_COLLECTION).document(token_id).get()
    if not getattr(snap, "exists", False):
        return False
    d = snap.to_dict() or {}
    if d.get("uid") != uid:
        return False
    db.collection(TOKENS_COLLECTION).document(token_id).set(
        {"revoked": True, "revoked_at": utcnow()}, merge=True
    )
    _token_cache.pop(token_id, None)
    logger.info("mcp token revoked uid=%s token_id=%s", uid, token_id[:12])
    return True


def revoke_raw_token(db, raw_token: str) -> bool:
    """RFC 7009 token revocation by the token itself (client-initiated)."""
    if not raw_token or not raw_token.startswith(TOKEN_PREFIX):
        return False
    token_id = _hash(raw_token)
    snap = db.collection(TOKENS_COLLECTION).document(token_id).get()
    if not getattr(snap, "exists", False):
        return False
    db.collection(TOKENS_COLLECTION).document(token_id).set(
        {"revoked": True, "revoked_at": utcnow()}, merge=True
    )
    _token_cache.pop(token_id, None)
    return True


def clear_cache() -> None:
    _token_cache.clear()
