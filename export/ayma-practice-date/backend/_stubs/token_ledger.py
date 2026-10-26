"""Test-only stand-in for Ayma's private lifetime-credit ledger.

Reproduces ONLY what the extracted code references: the feature constants, the
``TokenCapExceeded`` exception type, and no-op ``check`` / ``record`` / ``add``.
The real ledger meters tokens against a per-user lifetime credit cap in
Firestore; none of that is part of this public repo. Tests that assert metering
monkeypatch these functions.

NOT the production ledger. Added to ``sys.path`` only by ``tests/conftest.py``.
"""

from __future__ import annotations

FEATURE_PRACTICE = "practice"
FEATURE_VOICE = "voice"


class TokenCapExceeded(RuntimeError):
    """Raised by the real ledger once a user's lifetime credits hit zero."""


def check(uid):  # noqa: D401 - no-op in the public test harness
    """No-op cap check (the real one raises :class:`TokenCapExceeded` at zero)."""
    return None


def record(uid, feature, response, **kwargs):
    """No-op usage recorder (the real one writes to Firestore)."""
    return None


def add(uid, feature, tokens, **kwargs):
    """No-op token adder used by the voice-cascade meter."""
    return None
