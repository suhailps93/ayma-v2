"""Another user's public-facing profile — the Explore card tap-through (§6.x).

The Firestore security rules block every cross-user read from the client, so
this module assembles the view the backend is allowed to hand back: the
public wiki narrative, the visible photos as token download URLs, and the
caller-relative bits (the compatibility score if one has been computed, and
whether the caller has already liked them).
"""

from __future__ import annotations

import logging
import time
import uuid
from urllib.parse import quote

from firebase_admin import storage

import schema
from config import CONFIG
from dm_schema import DM_MESSAGES_COLLECTION, DM_THREADS_COLLECTION
from explore import _score_for
from matching import _age
from matching_schema import MATCHES_COLLECTION, block_id
from pair_key import sorted_pair_key
from practice_seed import is_practice_persona

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


def _variant_url(storage_path: str, spec: str, width: int) -> str | None:
    """A token URL for the ``spec`` variant of ``storage_path`` (e.g. the
    ``thumb_400`` of a profile photo), or ``None`` when image variants are off
    (prod — no GCS call made) or the variant object doesn't exist yet.

    The client can't derive another user's variant URL (per-object Firebase
    tokens + owner-only storage.rules), so the backend mints it here, reusing
    :func:`_photo_url`'s exists-check + token-mint against the variant object
    itself. Callers fall back to the original URL whenever this is ``None``."""
    if not CONFIG.image_variants_enabled:
        return None
    if not storage_path:
        return None
    import image_variants

    return _photo_url(image_variants.variant_object_name(storage_path, spec, width))


def _resolve_photo_paths(db, uid: str, prof: dict) -> list[str]:
    """Ordered list of storage paths for a profile's visible photos (shared by
    :func:`_photos` and :func:`_photos_with_variants`)."""
    entries = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    entries.sort(key=lambda p: p.get("order", 0))
    paths: list[str] = []
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
        if sp:
            paths.append(sp)
    return paths


def _photos(db, uid: str, prof: dict) -> list[str]:
    urls: list[str] = []
    for sp in _resolve_photo_paths(db, uid, prof):
        url = _photo_url(sp)
        if url:
            urls.append(url)
    return urls


def _photos_with_variants(
    db, uid: str, prof: dict
) -> tuple[list[str], list[str], list[str]]:
    """``(originals, thumbs, mediums)`` aligned 1:1. Each thumb/medium entry is
    that photo's variant URL, or its original URL as fallback when the variant
    is absent or image variants are off. Only photos with a resolvable original
    URL are included, so the three lists stay aligned."""
    originals: list[str] = []
    thumbs: list[str] = []
    mediums: list[str] = []
    for sp in _resolve_photo_paths(db, uid, prof):
        original = _photo_url(sp)
        if not original:
            continue
        originals.append(original)
        thumbs.append(_variant_url(sp, "thumb", 400) or original)
        mediums.append(_variant_url(sp, "medium", 1080) or original)
    return originals, thumbs, mediums


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

    Full account deletion (§3.6; founder request 2026-09-20, point 3) leaves
    any shared record another user has with ``other_uid`` — a match, a DM
    thread and its messages — completely untouched, so it's never silently
    destroyed as a side effect of someone else deleting their account. What
    changes is this lookup: ``account_ops.soft_delete`` writes a
    ``deleted_users/{uid}`` tombstone, checked here first, so callers who
    still have a match/thread with a deleted person see a clearly-labeled
    placeholder (``"deleted": True``) instead of that person's old profile —
    or, without this check, instead of a bare ``None`` a caller's UI can't
    tell apart from "this uid never existed"."""
    other_uid = (other_uid or "").strip()
    if not other_uid:
        return None
    if db.collection("deleted_users").document(other_uid).get().exists:
        return {
            "uid": other_uid,
            "deleted": True,
            "self": False,
            "blocked": False,
            # A tombstone is never an AI-generated persona (no label on a
            # deleted-user placeholder).
            "ai_generated": False,
            "name": "Deleted user",
            "age": None,
            "location": "",
            "online": False,
            "photos": [],
            "photos_thumb": [],
            "photos_medium": [],
            "pages": [],
            "score": None,
            "liked": False,
            "deep_dive_id": "",
            "physical_attributes": None,
            # thread_id/has_chatted are still computed for real: B's existing
            # match/thread/messages are untouched by A's deletion (see the
            # docstring above) — only A's profile info is replaced.
            "thread_id": None if other_uid == caller_uid else sorted_pair_key(
                caller_uid, other_uid
            ),
            "has_chatted": (
                False
                if other_uid == caller_uid
                else _has_chatted(db, caller_uid, other_uid)
            ),
        }
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

    photos, photos_thumb, photos_medium = _photos_with_variants(db, other_uid, prof)

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
    # instead of "Web search", and no fresh search/credit spend on tap) —
    # either their own self-dive (with any corrections they've made) or an
    # earlier cross-user search someone else already ran on them. Both live
    # under THEIR OWN collection now (§ persistent web-search report), so
    # this reflects reality regardless of who's asking. Cheap doc-exists
    # checks.
    dive_id = ""
    if not is_self:
        try:
            import deep_dive

            if deep_dive.has_dive(
                db, other_uid, name=name
            ) or deep_dive.has_dive(db, other_uid, target_uid=other_uid):
                dive_id = deep_dive.dive_report_id(target_uid=other_uid)
        except Exception:  # noqa: BLE001
            dive_id = ""

    return {
        "uid": other_uid,
        "self": is_self,
        "blocked": blocked,
        # True ONLY for AI-generated personas (sim / demo / seed): the explicit
        # ``ai_generated`` marker set at creation (practice_seed), backstopped by
        # the reserved ``demo_practice_`` uid prefix. A real user has neither, so
        # the "AI-generated profile" label never appears on a real person; an
        # absent/unknown marker resolves to False (no label).
        "ai_generated": bool(prof.get("ai_generated"))
        or is_practice_persona(other_uid),
        "name": name,
        "age": _age(prof.get("birthdate")),
        "gender": str(prof.get("gender") or ""),
        "location": str(prof.get("location") or ""),
        # Real presence only — see `_is_online`'s docstring.
        "online": _is_online(db, other_uid),
        "photos": photos,
        "photos_thumb": photos_thumb,
        "photos_medium": photos_medium,
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


def _is_online(db, other_uid: str) -> bool:
    """True when ``other_uid`` touched the API within the last 5 minutes.

    ``last_active_at`` is stamped on every authed request (see
    ``main.py``'s ``_stamp_last_active``) on the user's root doc — the same
    signal and window ``POST /profiles/mini`` already uses for its own
    ``online`` flag. Never a placeholder/hardcoded value: absent or stale
    data reads as offline."""
    try:
        udoc = db.collection("users").document(other_uid).get().to_dict() or {}
        la = udoc.get(schema.FIELD_LAST_ACTIVE_AT)
        if hasattr(la, "timestamp"):
            return (time.time() - la.timestamp()) < 300
    except Exception:  # noqa: BLE001
        pass
    return False


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
    match was run — that pair's computed score and private ``ai_explanation``.

    The briefing ends with an explicit, honest statement of *what data exists*
    — how complete their profile is, whether any public wiki is available, and
    whether a compatibility score has actually been computed for this pair
    (``has_match_score``). With little or nothing to go on it says so in so
    many words (founder bug 2026-10-25: Ayma called a near-empty stranger "a
    great match on paper" with no score and no facts). The persona rule
    ("Talking about a match or another member" in ``persona.md``) stands on
    these flags; the honest data here is what stops the model inventing a match
    it never ran.

    Shared by text chat (``main.py``'s ``/chat``, via ``viewing_profile_uid``)
    and voice (``skills/app_control.py``'s ``current_screen`` /
    ``open_profile`` tools, via the live voice-context mirror's
    ``subject_uid``) — both need the same real briefing, not two copies of
    this logic."""
    if not other or other == uid:
        return ""
    parts: list[str] = []
    completeness_pct: int | None = None
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
        raw_pct = (prof.get("completeness") or {}).get("score")
        if isinstance(raw_pct, (int, float)):
            completeness_pct = round(float(raw_pct))
    except Exception:  # noqa: BLE001
        parts.append("The user is looking at another person's profile.")
    wiki_count = 0
    try:
        pages = _public_pages(db, other)
        for p in pages[:8]:
            title = p.get("title") or p.get("page_type") or "Note"
            body = " ".join(str(p.get("body") or "").split())[:600]
            if body:
                parts.append(f"[{title}] {body}")
                wiki_count += 1
    except Exception:  # noqa: BLE001
        pass
    has_match_score = False
    has_match_read = False
    try:
        snap = db.collection(MATCHES_COLLECTION).document(
            sorted_pair_key(uid, other)
        ).get()
        mdoc = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
        score = mdoc.get("score")
        if isinstance(score, (int, float)):
            has_match_score = True
            pct = round(float(score) * 100)
            parts.append(
                f"A compatibility score has been computed for you two: "
                f"{pct}/100 compatibility (this is a real, "
                "computed score — you may cite it; it is on a 0–100 scale where "
                "100 is the best possible match — never describe a high number as low). "
                "This is a compatibility preview, not a mutual match — only "
                "call it a 'match' if they have mutually liked each other."
            )
        expl = mdoc.get("ai_explanation", "")
        if expl:
            has_match_read = True
            parts.append(f"Your private read on this pairing: {expl}")
    except Exception:  # noqa: BLE001
        pass
    # Honest data flags: tell the model plainly what it does and doesn't have
    # so it can't mistake a thin profile for grounds to assert compatibility.
    flags: list[str] = []
    if completeness_pct is not None:
        flags.append(f"their profile is {completeness_pct}% complete")
    flags.append(
        "a compatibility score HAS been computed for this pair"
        if has_match_score
        else "NO compatibility/match score has been computed for this pair"
    )
    if wiki_count == 0:
        flags.append("you have no profile notes/wiki facts about them")
    parts.append("DATA YOU HAVE: " + "; ".join(flags) + ".")
    if not has_match_score and not has_match_read and wiki_count == 0:
        parts.append(
            "You do NOT have enough to judge compatibility. Do not state or "
            "imply any match score, that they are a good/bad match, or that "
            "their background or interests align — you have no basis for it. "
            "Say honestly you don't have much on them yet and offer to run a "
            "match or research them."
        )
    return "\n".join(parts)
