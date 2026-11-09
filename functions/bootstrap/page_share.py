"""Reusable page-share links: the data layer behind ``POST /share-link``
and the public ``/p/{token}`` page.

One registry maps a share-target *kind* to the builder that freezes a
PUBLIC snapshot of the target. A kind is either public (registered here —
an external link may exist for it) or Ayma-only (never registered — story
is the standing example: it can be sent to Ayma inside the app, but no
snapshot, link or public route can ever be created for it, because there
is simply no builder and ``create`` refuses any kind not in the registry).

A share is a frozen copy of the target's public face, stored in
``page_shares/{token}`` with the owner's uid, so the public page needs no
auth and never touches live private data. The token is a 256-bit URL-safe
random string — unguessable, and the only thing that grants read access.

Creating a share is idempotent per ``(owner, kind, target_id)``: the
existing live share keeps its token (so an already-posted link keeps
working) and its snapshot is refreshed. A revoked share is never revived —
sharing again mints a new token.
"""

from __future__ import annotations

import logging
import secrets

from firebase_admin import firestore

import public_profile
from config import CONFIG

logger = logging.getLogger("ayma.page_share")

SHARES_COLLECTION = "page_shares"

_SECTION_MAX = 8
_BODY_MAX = 800


def link_url(token: str) -> str:
    return f"{CONFIG.share_base_url}/p/{token}"


def _profile_snapshot(db, owner_uid: str, target_id: str) -> dict:
    """The public face of one profile, frozen for the landing page.

    Built from the same redacted view ``GET /explore/profile/{uid}``
    serves (``public_profile.build``) and then stripped to public fields
    only: name, age, location, the public photos and the public narrative
    pages. Caller-relative data (score, liked, blocked state, thread id,
    presence, dive ids, physical attributes) never enters the snapshot.
    """
    view = public_profile.build(db, owner_uid, target_id)
    if view is None or view.get("deleted"):
        raise KeyError("no such profile")
    if view.get("blocked"):
        raise PermissionError("this profile can't be shared with you")
    sections = []
    for page in (view.get("pages") or [])[:_SECTION_MAX]:
        body = str(page.get("body") or "").strip()
        if not body:
            continue
        if len(body) > _BODY_MAX:
            body = body[: _BODY_MAX - 1].rstrip() + "…"
        sections.append(
            {"title": str(page.get("title") or "").strip(), "body": body}
        )
    photos = [str(u) for u in (view.get("photos") or []) if str(u).startswith("https://")]
    return {
        "name": str(view.get("name") or "").strip(),
        "age": view.get("age"),
        "location": str(view.get("location") or "").strip(),
        "photo_url": photos[0] if photos else "",
        "photos": photos,
        "sections": sections,
    }


def _profile_title(snap: dict) -> str:
    name = snap.get("name") or "Someone"
    return f"{name} on Ayma"


def _profile_summary(snap: dict) -> str:
    parts = [str(snap.get("name") or "").strip()]
    if snap.get("age"):
        parts.append(str(snap["age"]))
    if snap.get("location"):
        parts.append(str(snap["location"]))
    return " · ".join(p for p in parts if p)


# The share-target registry. Registering a new public kind = one builder
# (+ title/summary) here; the routes, the landing page and the app-side
# kit pick it up without further plumbing. Ayma-only kinds (story) are
# deliberately ABSENT: no builder, no snapshot, no link, no route.
SNAPSHOT_BUILDERS = {
    "profile": _profile_snapshot,
}

_TITLES = {"profile": _profile_title}
_SUMMARIES = {"profile": _profile_summary}


def _payload(token: str, doc: dict) -> dict:
    return {
        "token": token,
        "url": link_url(token),
        "title": doc.get("title", ""),
        "summary": doc.get("summary", ""),
    }


def create(db, uid: str, kind: str, target_id: str) -> dict:
    """Snapshot the target and return ``{token, url, title, summary}``.

    ``ValueError`` for a kind that can't be shared externally (including
    every Ayma-only kind), ``KeyError`` when the target doesn't exist,
    ``PermissionError`` when the caller may not share it.
    """
    builder = SNAPSHOT_BUILDERS.get(kind)
    if builder is None:
        raise ValueError(f"share target kind {kind!r} can't be shared externally")
    target_id = (target_id or "").strip()
    if not target_id:
        raise ValueError("a share target id is required")
    snap = builder(db, uid, target_id)
    fields = {
        "title": _TITLES[kind](snap),
        "summary": _SUMMARIES[kind](snap),
        "snapshot": snap,
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    existing = (
        db.collection(SHARES_COLLECTION)
        .where("owner_uid", "==", uid)
        .where("kind", "==", kind)
        .where("target_id", "==", target_id)
        .where("revoked", "==", False)
        .limit(1)
        .stream()
    )
    for doc in existing:
        doc.reference.update(fields)
        return _payload(doc.id, fields)
    token = secrets.token_urlsafe(32)
    db.collection(SHARES_COLLECTION).document(token).set(
        {
            **fields,
            "owner_uid": uid,
            "kind": kind,
            "target_id": target_id,
            "revoked": False,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )
    return _payload(token, fields)


def fetch_public(db, token: str) -> dict | None:
    """The public face of one share: ``{kind, target_id, title, summary,
    snapshot}`` — or ``None`` when the token is unknown or revoked. Only
    the frozen public snapshot is ever returned; the owner uid stays
    server-side."""
    if not token:
        return None
    doc = db.collection(SHARES_COLLECTION).document(token).get()
    if not doc.exists:
        return None
    data = doc.to_dict() or {}
    if data.get("revoked"):
        return None
    return {
        "kind": data.get("kind", ""),
        "target_id": data.get("target_id", ""),
        "title": data.get("title", ""),
        "summary": data.get("summary", ""),
        "snapshot": data.get("snapshot") or {},
    }


def revoke(db, uid: str, token: str) -> None:
    """Owner-only revoke; a revoked link dies for everyone and is never
    revived (a fresh share mints a new token)."""
    doc = db.collection(SHARES_COLLECTION).document(token).get()
    if not doc.exists:
        raise KeyError("no such share")
    if (doc.to_dict() or {}).get("owner_uid") != uid:
        raise PermissionError("you can only revoke your own shares")
    doc.reference.update({"revoked": True})
