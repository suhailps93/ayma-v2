"""Per-photo notes on "photos Ayma has" (Your Story's photo gallery).

Every photo the app surfaces — a profile-grid shot, one shared in chat, or one
Ayma found on the open web during a deep dive — is otherwise a bare URL, with
no way to say what it is, whether it's really the user, or to hide it from the
gallery without touching the record it actually came from. This module adds
one small, additive layer on top of all three sources:

``users/{uid}/photo_notes/{photo_id}`` — ``photo_id`` is a stable hash of the
photo's URL, so a note survives across reloads without needing the caller to
already have a durable id. Fields: ``context`` (free text — what the photo is,
added by the user or by Ayma after a chat correction), ``is_user`` (``""`` /
``"yes"`` / ``"no"``), ``hidden`` (soft-removed from the gallery).

Hiding never deletes the underlying record — same "Ayma keeps it" rule the
rest of Your Story follows (§ story.py ``remove_section``). Publishing a
chat/web photo to the profile grid runs it through the same moderation +
embedding pipeline every profile photo goes through (``photo_pipeline``) —
nothing reaches the public grid unmoderated just because it started life
somewhere else.
"""

from __future__ import annotations

import hashlib
import logging
import re
import urllib.parse

from config import CONFIG

logger = logging.getLogger("ayma.photo_notes")

_COL = "photo_notes"
_VALID_IS_USER = {"", "yes", "no"}

_STORAGE_URL_RE = re.compile(
    r"^https://firebasestorage\.googleapis\.com/v0/b/([^/]+)/o/([^?]+)"
)


def photo_id(url: str) -> str:
    """A stable, Firestore-doc-id-safe id for a photo URL."""
    return hashlib.sha1((url or "").strip().encode("utf-8")).hexdigest()[:24]


def _col(db, uid: str):
    return db.collection("users").document(uid).collection(_COL)


def resolve_storage_path(url: str) -> str | None:
    """The Storage object path a Firebase Storage download URL points at, if
    ``url`` is one of ours (``public_profile._photo_url``'s format) — else
    ``None``. A web-search photo's URL is some other site entirely and always
    returns ``None`` here."""
    m = _STORAGE_URL_RE.match((url or "").strip())
    if not m or m.group(1) != CONFIG.storage_bucket:
        return None
    return urllib.parse.unquote(m.group(2))


def all_notes(db, uid: str) -> dict[str, dict]:
    """``{photo_id: {context, is_user, hidden}}`` for every note this user has
    written — one query, so merging into a photo list never costs one read per
    photo. Best-effort; a read failure just means no notes are known yet."""
    try:
        snaps = list(_col(db, uid).stream())
    except Exception:  # noqa: BLE001
        logger.warning("photo_notes: list failed for %s", uid, exc_info=True)
        return {}
    out: dict[str, dict] = {}
    for s in snaps:
        d = s.to_dict() or {}
        out[s.id] = {
            "context": str(d.get("context", "")),
            "is_user": str(d.get("is_user", "")),
            "hidden": bool(d.get("hidden", False)),
        }
    return out


def get_note(db, uid: str, url: str) -> dict:
    pid = photo_id(url)
    try:
        d = _col(db, uid).document(pid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        d = {}
    return {
        "context": str(d.get("context", "")),
        "is_user": str(d.get("is_user", "")),
        "hidden": bool(d.get("hidden", False)),
    }


def set_context(
    db, uid: str, url: str, *, context: str | None = None, is_user: str | None = None
) -> dict:
    """Upsert the free-text context and/or the "is this the user" flag for a
    photo. Either field may be omitted to leave it unchanged."""
    url = (url or "").strip()
    if not url:
        raise ValueError("url is required")
    patch: dict[str, object] = {}
    if context is not None:
        patch["context"] = context.strip()[:2000]
    if is_user is not None:
        is_user = is_user.strip().lower()
        if is_user not in _VALID_IS_USER:
            raise ValueError("is_user must be '', 'yes' or 'no'")
        patch["is_user"] = is_user
    if not patch:
        return get_note(db, uid, url)
    _col(db, uid).document(photo_id(url)).set(patch, merge=True)
    return get_note(db, uid, url)


def hide_photo(db, uid: str, url: str, *, source: str = "") -> None:
    """Take a photo out of the gallery. For a profile-grid photo this also
    soft-removes it from the grid itself (``photo_ops.remove_photo`` —
    ``user_media`` stays, same as any other profile-photo delete); chat and
    web photos have no separate "grid" to remove from, so the note flag alone
    is what keeps them out of the gallery from here on."""
    url = (url or "").strip()
    if not url:
        raise ValueError("url is required")
    if source == "profile":
        path = resolve_storage_path(url)
        media_id = _media_id_for_path(db, uid, path) if path else None
        if media_id:
            try:
                import photo_ops

                photo_ops.remove_photo(db, uid, media_id)
            except Exception:  # noqa: BLE001
                logger.warning(
                    "photo_notes: grid removal failed for %s/%s", uid, media_id,
                    exc_info=True,
                )
    _col(db, uid).document(photo_id(url)).set({"hidden": True}, merge=True)


def _media_id_for_path(db, uid: str, storage_path: str) -> str | None:
    try:
        docs = list(
            db.collection("users")
            .document(uid)
            .collection("user_media")
            .where("storage_path", "==", storage_path)
            .limit(1)
            .stream()
        )
    except Exception:  # noqa: BLE001
        return None
    return docs[0].id if docs else None


def _download_external(url: str) -> tuple[bytes, str]:
    """Download a photo Ayma found on the open web so it can be re-hosted in
    the user's own Storage before it's ever treated as a profile photo."""
    import deep_dive_images

    return deep_dive_images._fetch_image(url)  # noqa: SLF001 - shared helper


async def publish_photo(db, uid: str, url: str, *, source: str) -> dict:
    """Promote a chat or web photo to the public profile grid — the "make
    public / add to profile" action. Runs it through the same moderation,
    face-embedding and captioning pipeline every profile upload goes through
    (``photo_pipeline.process``); a photo that doesn't clear moderation is
    never added to the grid. A profile photo is already public — a no-op.
    """
    url = (url or "").strip()
    if not url:
        raise ValueError("url is required")
    if source == "profile":
        return {"published": True, "already_public": True}

    import photo_ops
    import photo_pipeline

    from firebase_admin import storage

    storage_path = resolve_storage_path(url)
    if storage_path is None:
        # A web (open-internet) photo — re-host it in the user's own bucket
        # first; nothing external is ever linked into the profile grid.
        image, mime = _download_external(url)
        ext = "png" if "png" in mime else "jpg"
        storage_path = f"users/{uid}/web_imports/{photo_id(url)}.{ext}"
        blob = storage.bucket(CONFIG.storage_bucket).blob(storage_path)
        blob.upload_from_string(image, content_type=mime)

    result = await photo_pipeline.process(
        db, uid, storage_path, "profile",
        wiki_uids=[uid], wiki_visibility="public",
    )
    if not result.get("published"):
        return {
            "published": False,
            "reason": result.get("reason") or "didn't clear moderation",
        }
    photo_ops.add_photo(db, uid, result["media_id"])
    # The original chat/web URL is superseded by the new profile-grid entry —
    # hide it so the gallery doesn't show the same photo twice.
    _col(db, uid).document(photo_id(url)).set(
        {"hidden": True, "is_user": "yes"}, merge=True
    )
    return {"published": True, "media_id": result["media_id"]}
