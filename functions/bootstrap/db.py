"""Lazily-created Firestore client (the only data layer, AGENTS.md).

Credentials resolve automatically in every environment we deploy to EXCEPT one:

* Cloud Run / Cloud Functions — the runtime service identity (ADC), no key.
* Local dev — ``GOOGLE_APPLICATION_CREDENTIALS`` from ``.env.local``.
* LiveKit Cloud Agents — there is no GCP workload identity there, so the agent
  reads a least-privilege service-account key JSON from the ``LK_AGENT_FIRESTORE_SA``
  secret (mounted by LiveKit's secret store, never committed; see
  ``docs/LIVEKIT_AGENT_MIGRATION.md``) and initializes firebase-admin with it.
  The value is the key JSON itself; a filesystem path also works.
"""

from __future__ import annotations

import json
import os
from functools import lru_cache

import firebase_admin
from firebase_admin import credentials, firestore


def _init_app() -> None:
    """Initialize the firebase-admin app once, choosing the credential source
    by environment. A bad/missing ``LK_AGENT_FIRESTORE_SA`` must raise rather
    than silently fall back to the wrong identity (AGENTS.md: throw, never
    substitute a default credential)."""
    sa = os.getenv("LK_AGENT_FIRESTORE_SA", "").strip()
    if sa:
        # JSON content (LiveKit secret store) or a path to the key file.
        if sa.startswith("{"):
            cred = credentials.Certificate(json.loads(sa))
        else:
            cred = credentials.Certificate(sa)
        firebase_admin.initialize_app(cred)
    else:
        firebase_admin.initialize_app()


if not firebase_admin._apps:
    _init_app()


@lru_cache(maxsize=1)
def get_db() -> firestore.firestore.Client:
    return firestore.client()
