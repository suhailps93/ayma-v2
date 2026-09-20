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
from dm_schema import DM_MESSAGES_COLLECTION, DM_THREADS_COLLECTION
from explore import _score_for
from matching import _age
from matching_schema import MATCHES_COLLECTION, block_id
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


def _physical_attributes(db, uid: str) -> dict | None:
    """The owner's structured physical-attributes record (§ physical
    attributes) — every field with its ``{value, source, confidence}`` label.
    Owner-only: it carries inferences we don't surface about other people, in
    line with ``photo_attrs`` never being exposed here either."""
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("physical_attributes")
            .document("current")
            .get()
        )
    except Exception:  # noqa: BLE001
        return None
    if not getattr(snap, "exists", False):
        return None
    data = snap.to_dict() or {}
    updated = data.get("updated_at")
    return {
        "fields": data.get("fields") or {},
        "photo_count": int(data.get("photo_count") or 0),
        "updated_at": updated.isoformat()
        if hasattr(updated, "isoformat")
        else None,
    }


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
        # Owner-only: the structured physical-attributes record with its source
        # labels. Never exposed for another person.
        "physical_attributes": _physical_attributes(db, other_uid)
        if is_self
        else None,
        # matches + dm_threads share this sorted-pair id; the thread is created
        # lazily on the first message. Present for any non-self pair whether
        # or not they've actually chatted — see `has_chatted` for that.
        "thread_id": None if is_self else sorted_pair_key(caller_uid, other_uid),
        # True only once a real message has been sent either way (§ bug fix:
        # `thread_id` above is not a "have we chatted" signal).
        "has_chatted": False if is_self else _has_chatted(db, caller_uid, other_uid),
    }


def _has_chatted(db, uid_a: str, uid_b: str) -> bool:
    """Whether this pair has exchanged at least one real DM message.

    ``thread_id`` (below) is a deterministic sorted-pair id shared with
    ``matches`` — it "exists" for any two uids whether or not a
    ``dm_threads`` doc, let alone a message, has ever been written. Callers
    that want an "already chatted" signal must use this instead: it's False
    until the pair's thread doc exists *and* carries a real message.
    """
    tid = sorted_pair_key(uid_a, uid_b)
    thread = db.collection(DM_THREADS_COLLECTION).document(tid).get()
    if not thread.exists:
        return False
    msgs = thread.reference.collection(DM_MESSAGES_COLLECTION).limit(1).stream()
    return next(iter(msgs), None) is not None


def _viewing_profile_context(db, uid: str, other: str) -> str:
    """A briefing on ``other`` so Ayma can talk about them when the user shares
    or opens their profile (§5.6): who they are, their public wiki, and — if a
    match was run — that pair's private ``ai_explanation``.

    Shared by text chat (``main.py``'s ``/chat``, via ``viewing_profile_uid``)
    and voice (``skills/app_control.py``'s ``current_screen`` tool, via the
    live voice-context mirror's ``subject_uid``) — both need the same real
    briefing, not two copies of this logic."""
    if not other or other == uid:
        return ""
    parts: list[str] = []
    try:
        prof = (
            db.collection("users")
            .document(other)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        ) or {}
        name = str(prof.get("name") or "").strip() or "this person"
        head = name
        loc = str(prof.get("location") or "").strip()
        age = _age(prof.get("birthdate"))
        bits = [b for b in (f"{age}" if age else "", loc) if b]
        if bits:
            head += f" ({', '.join(bits)})"
        parts.append(f"The user is looking at {head}'s profile.")
    except Exception:  # noqa: BLE001
        parts.append("The user is looking at another person's profile.")
    try:
        pages = _public_pages(db, other)
        for p in pages[:8]:
            title = p.get("title") or p.get("page_type") or "Note"
            body = " ".join(str(p.get("body") or "").split())[:600]
            if body:
                parts.append(f"[{title}] {body}")
    except Exception:  # noqa: BLE001
        pass
    try:
        snap = db.collection(MATCHES_COLLECTION).document(
            sorted_pair_key(uid, other)
        ).get()
        expl = (snap.to_dict() or {}).get("ai_explanation", "") if snap.exists else ""
        if expl:
            parts.append(f"Your private read on this match: {expl}")
    except Exception:  # noqa: BLE001
        pass
    return "\n".join(parts)
