"""Photo / face embeddings (ARCHITECTURE.md §2.5, §2.8 step 7).

Every reference photo is embedded once, at upload time, with Vertex's
multimodal-embedding model, and the vector is stored on the corresponding
``users/{uid}/user_media/{mediaId}`` doc. Same-person checks use Firestore's
native ``find_nearest`` (COSINE) — no separate vector database.
"""

from __future__ import annotations

import base64
import json
import logging
import urllib.error
import urllib.request

import google.auth
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
from google.cloud.firestore_v1.vector import Vector

from config import CONFIG

logger = logging.getLogger("ayma.media")

_SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
_EMBED_DIM = 1408


def embed_image_bytes(image_bytes: bytes) -> list[float]:
    """Return the multimodal embedding for a raw image (§2.5)."""
    creds, _ = google.auth.default(scopes=_SCOPES)
    creds.refresh(GoogleAuthRequest())

    url = (
        f"https://{CONFIG.vertex_location}-aiplatform.googleapis.com/v1/"
        f"projects/{CONFIG.project_id}/locations/{CONFIG.vertex_location}/"
        f"publishers/google/models/{CONFIG.image_embedding_model}:predict"
    )
    body = json.dumps(
        {
            "instances": [
                {
                    "image": {
                        "bytesBase64Encoded": base64.b64encode(
                            image_bytes
                        ).decode()
                    }
                }
            ]
        }
    ).encode()
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {creds.token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:  # surface the Vertex error body
        detail = exc.read().decode("utf-8", "replace")[:500]
        raise RuntimeError(f"Vertex embed {exc.code}: {detail}") from exc
    return list(data["predictions"][0]["imageEmbedding"])


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
