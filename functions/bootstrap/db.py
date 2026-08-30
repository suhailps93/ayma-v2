"""Lazily-created Firestore client (the only data layer, AGENTS.md).

Credentials resolve automatically: the Cloud Run runtime identity when
deployed, ``GOOGLE_APPLICATION_CREDENTIALS`` from ``.env.local`` locally.
"""

from __future__ import annotations

from functools import lru_cache

import firebase_admin
from firebase_admin import firestore

if not firebase_admin._apps:
    firebase_admin.initialize_app()


@lru_cache(maxsize=1)
def get_db() -> firestore.firestore.Client:
    return firestore.client()
