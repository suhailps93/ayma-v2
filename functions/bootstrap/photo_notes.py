"""Per-photo notes on "photos Ayma has" (Your Story's photo gallery).

Every photo the app surfaces — a profile-grid shot, one shared in chat, or one
Ayma found on the open web during a deep dive — is otherwise a bare URL, with
no way to say what it is, whether it's really the user, or to take it out of
the gallery without touching the record it actually came from. This module
adds one small, additive layer on top of all three sources:

``users/{uid}/photo_notes/{photo_id}`` — ``photo_id`` is a stable hash of the
photo's URL, so a note survives across reloads without needing the caller to
already have a durable id. Fields: ``context`` (free text — what the photo is,
written by Ayma after a chat correction; never a plain user text box, per the
founder: "less text boxes ... replace all that with chat with ayma"),
``is_user`` (``""`` / ``"yes"`` / ``"no"`` — Ayma's own face-match verdict, or
a chat correction; never a manual yes/no toggle either), ``status`` (``""`` /
``"deleted"`` / ``"superseded"``), ``embedding`` (cached face embedding, for
face-matching and exact-duplicate detection — never sent to a client).

Deleting never erases the underlying record — same "Ayma keeps it" rule the
rest of Your Story follows (§ story.py ``remove_section``): a deleted photo's
note is tagged ``status: "deleted"`` and the photo keeps showing up, just
under AI notes instead of Everything / What's public. ``"superseded"`` is the
internal bookkeeping state for the *original* chat/web copy of a photo once
"Make public" promotes it onto the profile grid — that one really should just
disappear, since the new profile entry is the same photo.

Publishing a chat/web photo to the profile grid runs it through the same
moderation + embedding pipeline every profile photo goes through
(``photo_pipeline``) — nothing reaches the public grid unmoderated just
because it started life somewhere else.
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
_VALID_STATUS = {"", "deleted", "superseded"}

_STORAGE_URL_RE = re.compile(
    r"^https://firebasestorage\.googleapis\.com/v0/b/([^/]+)/o/([^?]+)"
)

# Multimodal-embedding cosine over two copies of the exact same image is
# effectively 1.0 (floating-point noise aside) — comfortably separated from
# "different photo of the same face" (same-person similarity is high but
# essentially never lands this close). Used to silently collapse the same
# picture appearing under two different URLs (e.g. sent in chat, and also on
# the profile grid).
_DUPLICATE_THRESHOLD = 0.999

# A gallery load computes an is-this-you verdict + embedding for any chat
# photo that doesn't have one cached yet (see ``classify_and_dedupe``) — each
# one is a real download + a Vertex embed call, so a single request caps how
# many it will do. Anything past the cap just waits for a later load; once
# computed, a photo's result is cached forever.
_MAX_NEW_EMBEDS_PER_CALL = 12


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


def _status(d: dict) -> str:
    if "status" in d:
        s = str(d.get("status", "")).strip().lower()
        if s in _VALID_STATUS:
            return s
    return "deleted" if d.get("hidden") else ""  # pre-status-field documents


def _embedding(d: dict) -> list[float] | None:
    raw = d.get("embedding")
    if not raw:
        return None
    try:
        return [float(x) for x in raw]
    except (TypeError, ValueError):
        return None


def all_notes(db, uid: str) -> dict[str, dict]:
    """``{photo_id: {context, is_user, status, url, source, embedding}}`` for
    every note this user has — one query, so merging into a photo list never
    costs one read per photo. Best-effort; a read failure just means no notes
    are known yet. Server-internal (carries the face embedding) — never
    returned from an endpoint as-is; see :func:`get_note` for the
    client-facing subset."""
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
            "status": _status(d),
            "url": str(d.get("url", "")),
            "source": str(d.get("source", "")),
            "embedding": _embedding(d),
        }
    return out


def get_note(db, uid: str, url: str) -> dict:
    """The client-facing subset of a photo's note — never the cached
    embedding."""
    pid = photo_id(url)
    try:
        d = _col(db, uid).document(pid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        d = {}
    return {
        "context": str(d.get("context", "")),
        "is_user": str(d.get("is_user", "")),
        "hidden": _status(d) == "deleted",
    }


def set_context(
    db, uid: str, url: str, *, context: str | None = None, is_user: str | None = None
) -> dict:
    """Upsert the free-text context and/or the "is this the user" flag for a
    photo — how Ayma records what she learns in a "Chat about it" correction.
    Either field may be omitted to leave it unchanged."""
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
    """The gallery's "Delete": takes a photo out of Everything / What's
    public. Ayma keeps it — it reappears under AI notes, tagged "deleted by
    you" — and a profile-grid photo is also soft-removed from the grid itself
    (``photo_ops.remove_photo``; the underlying ``user_media`` doc stays,
    same as any other profile-photo delete)."""
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
    _col(db, uid).document(photo_id(url)).set(
        {"status": "deleted", "url": url, "source": source}, merge=True
    )


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


def _vec(raw) -> list[float] | None:
    """A plain ``list[float]`` from a Firestore ``Vector`` (or anything else
    iterable) field — mirrors ``deep_dive_images._reference_embeddings``'s
    handling of the same ``user_media.embedding`` shape."""
    if raw is None:
        return None
    try:
        return [float(x) for x in raw]
    except TypeError:
        v = getattr(raw, "value", None)
        return [float(x) for x in v] if v else None


def profile_photo_media(db, uid: str, prof: dict) -> list[dict]:
    """``[{url, media_id, embedding}]`` for each profile-grid photo, in the
    same order ``public_profile._photos()`` enumerates them — duplicated here
    (rather than imported) because the gallery additionally needs each
    entry's already-computed face embedding, which that module doesn't
    expose. ``embedding`` is ``None`` for a legacy inline-``storage_path``
    entry (no ``user_media`` doc to read one from)."""
    from public_profile import _photo_url

    entries = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    entries.sort(key=lambda p: p.get("order", 0))
    out: list[dict] = []
    for e in entries:
        sp = e.get("storage_path")  # legacy inline shape
        embedding = None
        if not sp:
            media_id = str(e.get("media_id") or "").strip()
            if not media_id:
                continue
            doc = (
                db.collection("users").document(uid)
                .collection("user_media").document(media_id).get().to_dict()
            ) or {}
            sp = doc.get("storage_path")
            embedding = _vec(doc.get("embedding"))
        url = _photo_url(sp) if sp else None
        if url:
            out.append({"url": url, "embedding": embedding})
    return out


def classify_and_dedupe(db, uid: str, candidates: list[dict]) -> list[dict]:
    """Two passes over the assembled "photos Ayma has" candidates, in place:

    1. Fill ``is_user`` for anything missing it — a profile or already-vetted
       web photo is definitionally the user; a chat photo gets Ayma's actual
       face-match verdict against the user's own reference photos (the same
       check a chat-shared photo already gets, §``_classify_shared_photo``),
       computed once and cached on its note from then on (bounded per call —
       see ``_MAX_NEW_EMBEDS_PER_CALL``).
    2. Drop exact-duplicate images (same photo surfaced under two different
       URLs — e.g. sent in chat AND also on the profile grid) by comparing
       embeddings; first occurrence wins, so the input order (profile, then
       chat, then web) decides which copy is kept.

    Expects each candidate to carry a ``_embedding`` hint (already-known
    embedding, or ``None``) — consumed and removed here.
    """
    import deep_dive_images

    refs: list[list[float]] | None = None  # lazy — only fetched if needed
    budget = _MAX_NEW_EMBEDS_PER_CALL

    kept: list[dict] = []
    kept_embeddings: list[list[float]] = []
    for p in candidates:
        emb = p.pop("_embedding", None)

        if p.get("source") == "chat" and emb is None and budget > 0:
            path = resolve_storage_path(p["url"])
            if path:
                try:
                    import media_embed

                    img, mime = media_embed.download_bytes(path)
                    emb = media_embed.embed_image_bytes(img, mime)
                except Exception:  # noqa: BLE001
                    logger.warning(
                        "photo_notes: auto face-match failed for %s", p["url"],
                        exc_info=True,
                    )
                    emb = None
                budget -= 1
                patch: dict[str, object] = {}
                if emb is not None:
                    patch["embedding"] = emb
                    if not p.get("is_user"):
                        if refs is None:
                            refs = deep_dive_images.reference_embeddings_for(db, uid)
                        verdict = _face_verdict(emb, refs)
                        if verdict:
                            patch["is_user"] = verdict
                            p["is_user"] = verdict
                if patch:
                    _col(db, uid).document(photo_id(p["url"])).set(
                        patch, merge=True
                    )

        if p.get("source") in ("profile", "web") and not p.get("is_user"):
            p["is_user"] = "yes"

        if emb is not None and any(
            deep_dive_images._cosine(emb, k) >= _DUPLICATE_THRESHOLD
            for k in kept_embeddings
        ):
            continue  # the same picture as one already kept — drop silently

        kept.append(p)
        kept_embeddings.append(emb if emb is not None else [])
    return kept


def _face_verdict(embedding: list[float], refs: list[list[float]]) -> str:
    """``'yes'`` / ``'no'`` / ``''`` (can't tell) — same thresholds as
    ``main._classify_shared_photo``."""
    import deep_dive_images

    if not refs:
        return ""
    sim = max(deep_dive_images._cosine(embedding, r) for r in refs)
    if sim >= deep_dive_images._VERIFY_THRESHOLD:
        return "yes"
    if sim < deep_dive_images._VERIFY_THRESHOLD - 0.08:
        return "no"
    return ""


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

    import asyncio

    import photo_ops
    import photo_pipeline

    from firebase_admin import storage

    storage_path = resolve_storage_path(url)
    if storage_path is None:
        # A web (open-internet) photo — re-host it in the user's own bucket
        # first; nothing external is ever linked into the profile grid.
        # (Both steps are blocking network calls — off the event loop.)
        image, mime = await asyncio.to_thread(_download_external, url)
        ext = "png" if "png" in mime else "jpg"
        storage_path = f"users/{uid}/web_imports/{photo_id(url)}.{ext}"

        def _upload() -> None:
            blob = storage.bucket(CONFIG.storage_bucket).blob(storage_path)
            blob.upload_from_string(image, content_type=mime)

        await asyncio.to_thread(_upload)

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
    # The original chat/web copy is the same photo as the new profile entry
    # now — bookkeeping only, not a user-visible "delete": it just drops out
    # (see classify_and_dedupe / _ai_view_photos), it doesn't get tagged and
    # kept around the way an actual Delete does.
    _col(db, uid).document(photo_id(url)).set(
        {"status": "superseded", "url": url, "source": source, "is_user": "yes"},
        merge=True,
    )
    return {"published": True, "media_id": result["media_id"]}
