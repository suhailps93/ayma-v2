"""Media storage downloader (ARCHITECTURE.md §2.5, §2.8).

Face embeddings were replaced with on-demand LiveKit pairwise vision checks
(see face_match.py). This module provides storage object downloads.
"""

from __future__ import annotations

import logging
from config import CONFIG

logger = logging.getLogger("ayma.media")


def download_bytes(storage_path: str) -> tuple[bytes, str]:
    """Return ``(bytes, content_type)`` for an uploaded object."""
    from firebase_admin import storage

    blob = storage.bucket(CONFIG.storage_bucket).blob(storage_path)
    blob.reload()
    return blob.download_as_bytes(), blob.content_type or "image/jpeg"


def _download(storage_path: str) -> bytes:
    return download_bytes(storage_path)[0]
