"""Photo / face embeddings (ARCHITECTURE.md §2.5, §2.8 step 7).

Embedding NEW images is DISABLED (founder rule 2026-11-04 — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md`` item 6): it needs the direct-Vertex
embedding model, which the LiveKit gateway does not serve
(``/embeddings`` 404). :func:`embed_image_bytes` raises instead of calling
Google; every caller already treats that as "unknown"/skip, so same-person
signals degrade gracefully, never crash. Stored vectors and
:func:`find_similar_media` (pure Firestore) are unaffected.
"""

from __future__ import annotations

import logging

from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
from google.cloud.firestore_v1.vector import Vector

import llm_routing
from config import CONFIG

logger = logging.getLogger("ayma.media")


def embed_image_bytes(
    image_bytes: bytes, mime_type: str = "image/jpeg"
) -> list[float]:
    """DISABLED: embedding needs the direct-Vertex embedding model, which the
    LiveKit gateway does not serve. Raises instead of calling Google."""
    raise llm_routing.DirectGoogleDisabledError(
        "photo embeddings are unavailable: the embedding model needs direct "
        "Vertex, which is disabled — all inference goes through LiveKit"
    )


def download_bytes(storage_path: str) -> tuple[bytes, str]:
    """Return ``(bytes, content_type)`` for an uploaded object."""
    from firebase_admin import storage

    blob = storage.bucket(CONFIG.storage_bucket).blob(storage_path)
    blob.reload()
    return blob.download_as_bytes(), blob.content_type or "image/jpeg"


def _download(storage_path: str) -> bytes:
    return download_bytes(storage_path)[0]


def process_media(db, uid: str, storage_path: str, context: str) -> str:
    """Download the uploaded image, embed it, and write a ``user_media`` doc.
    Returns the new doc id."""
    image_bytes = _download(storage_path)
    embedding = embed_image_bytes(image_bytes)

    doc = (
        db.collection("users")
        .document(uid)
        .collection("user_media")
        .document()
    )
    from firebase_admin import firestore

    doc.set(
        {
            "storage_path": storage_path,
            "context": context,
            "embedding": Vector(embedding),
            "dim": len(embedding),
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )
    return doc.id


def find_similar_media(
    db, uid: str, embedding: list[float], limit: int = 5
) -> list[str]:
    """Native COSINE ``find_nearest`` over the user's known-face embeddings
    (§2.5). Returns matching ``user_media`` doc ids, nearest first."""
    col = (
        db.collection("users")
        .document(uid)
        .collection("user_media")
    )
    query = col.find_nearest(
        vector_field="embedding",
        query_vector=Vector(embedding),
        distance_measure=DistanceMeasure.COSINE,
        limit=limit,
    )
    return [snap.id for snap in query.stream()]
