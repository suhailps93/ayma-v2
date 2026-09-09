"""Another user's public-facing profile — the Explore card tap-through (§6.x).

The Firestore security rules block every cross-user read from the client, so
this module assembles the view the backend is allowed to hand back: the
public wiki narrative, the visible photos as token download URLs, and the
caller-relative bits (the compatibility score if one has been computed, and
whether the caller has already liked them).
"""

from __future__ import annotations

import logging
import uuid
from urllib.parse import quote

from firebase_admin import storage

from config import CONFIG
from explore import _score_for
from matching import _age
from matching_schema import block_id
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.public_profile")


def _photo_url(storage_path: str) -> str | None:
    """A stable, token-based Firebase Storage download URL for ``storage_path``
    (streams from a plain GET — the client's Image.network needs no auth)."""
    if not storage_path:
        return None
    try:
        blob = storage.bucket(CONFIG.storage_bucket).blob(storage_path)
        if not blob.exists():
            return None
        blob.reload()
        meta = blob.metadata or {}
        token = meta.get("firebaseStorageDownloadTokens")
        if not token:
            token = str(uuid.uuid4())
            blob.metadata = {**meta, "firebaseStorageDownloadTokens": token}
            blob.patch()
        return (
            "https://firebasestorage.googleapis.com/v0/b/"
            f"{blob.bucket.name}/o/{quote(blob.name, safe='')}"
            f"?alt=media&token={token.split(',')[0]}"
        )
    except Exception:  # noqa: BLE001 - a missing/broken photo just drops out
        logger.warning("photo url failed for %s", storage_path, exc_info=True)
        return None


def _photos(db, uid: str, prof: dict) -> list[str]:
    entries = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    entries.sort(key=lambda p: p.get("order", 0))
    urls: list[str] = []
    for e in entries:
        sp = e.get("storage_path")  # legacy inline shape
        if not sp:
            mid = str(e.get("media_id") or "").strip()
            if mid:
                m = (
                    db.collection("users")
                    .document(uid)
                    .collection("user_media")
                    .document(mid)
                    .get()
                    .to_dict()
                ) or {}
                sp = m.get("storage_path")
        url = _photo_url(sp) if sp else None
        if url:
            urls.append(url)
    return urls


def _public_pages(db, uid: str) -> list[dict]:
    """Public wiki pages: the section's effective body (``user_edits`` or
    ``ai_body``) with every ``{{private}}…{{/private}}`` span stripped — the
    same one-document / filtered-view model the owner edits in Your Story.
    Empty and hidden pages are dropped."""
    import story

    try:
        docs = list(
            db.collection("users")
            .document(uid)
            .collection("wiki_pages")
            .where("visibility", "==", "public")
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.warning("public wiki read failed for %s", uid, exc_info=True)
        return []
    out: list[dict] = []
    for d in docs:
        data = d.to_dict() or {}
        if data.get("user_hidden") is True:
            continue
        raw = (data.get("user_edits") or data.get("ai_body") or "").strip()
        body = story.strip_private_spans(raw)
        if not body:
            continue
        out.append(
            {
                "page_type": str(data.get("page_type") or "misc"),
                "title": str(data.get("title") or ""),
                "body": body,
            }
        )
    out.sort(key=lambda p: (p["page_type"], p["title"]))
    return out


def build(db, caller_uid: str, other_uid: str) -> dict | None:
    """The public profile view of ``other_uid`` for ``caller_uid``. ``None``
    when there's no such profile or it has no name (not a real, set-up person).
    """
    other_uid = (other_uid or "").strip()
    if not other_uid:
        return None
    prof = (
        db.collection("users")
        .document(other_uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    ) or {}
    name = str(prof.get("name") or "").strip()
    if not name:
        return None

    is_self = other_uid == caller_uid
    blocked = liked = False
    if not is_self:
        blocks = db.collection("blocks")
        blocked = (
            blocks.document(block_id(caller_uid, other_uid)).get().exists
            or blocks.document(block_id(other_uid, caller_uid)).get().exists
        )
        liked = (
            db.collection("users")
            .document(caller_uid)
            .collection("likes")
            .document(other_uid)
            .get()
            .exists
        )

    # A stored web dive on this person the caller can re-open ("View research"
    # instead of "Deep dive"). Cheap doc-exists check.
    dive_id = ""
    if not is_self:
        try:
            import deep_dive

            if deep_dive.has_dive(db, caller_uid, target_uid=other_uid):
                dive_id = deep_dive.dive_report_id(target_uid=other_uid)
        except Exception:  # noqa: BLE001
            dive_id = ""

    return {
        "uid": other_uid,
        "self": is_self,
        "blocked": blocked,
        "name": name,
        "age": _age(prof.get("birthdate")),
        "location": str(prof.get("location") or ""),
        "photos": _photos(db, other_uid, prof),
        "pages": _public_pages(db, other_uid),
        "score": None if is_self else _score_for(db, caller_uid, other_uid),
        "liked": liked,
        "deep_dive_id": dive_id,
        # matches + dm_threads share this sorted-pair id; the thread is created
        # lazily on the first message.
        "thread_id": None if is_self else sorted_pair_key(caller_uid, other_uid),
    }
