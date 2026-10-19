"""Shareable report snapshots: the data layer behind ``POST /share`` and the
public ``/s/{token}`` page.

A share is a frozen copy of a block report (``report_hub.get_report``'s
``{title, sections}``) stored in ``report_shares/{token}`` with the owner's
uid, so the public page needs no auth and never touches the live report. The
token is a 256-bit URL-safe random string — unguessable, and the only thing
that grants read access. Clients can't read the collection (Firestore rules
deny everything not listed); every read goes through this module.

Creating a share is idempotent per ``(owner, report_type, report_id)``: the
existing live share keeps its token (so an already-posted link keeps working)
and its snapshot is refreshed to the report's current content. A revoked
share is never revived — sharing again mints a new token.
"""

from __future__ import annotations

import logging
import secrets

from firebase_admin import firestore

import report_hub
import schema
from config import CONFIG

logger = logging.getLogger("ayma.share")

SHARES_COLLECTION = "report_shares"

# Report types a user may share: web research, Appearance, Match.
SHAREABLE_TYPES = ("deep_dive", "appearance", "match")

_SUMMARY_MAX = 200


def share_url(token: str) -> str:
    return f"{CONFIG.share_base_url}/s/{token}"


def _text_of(block: dict) -> str:
    return str(block.get("text") or "").strip()


def summarize(report: dict) -> str:
    """One short description line: the headline stat (if any) plus the first
    prose sentence — used for the link preview and the DM / Ayma draft."""
    stat = ""
    prose = ""
    for section in report.get("sections") or []:
        for b in section.get("blocks") or []:
            kind = b.get("type")
            if not stat and kind == "stat":
                value = b.get("value")
                label = str(b.get("label") or "").strip()
                if value not in (None, ""):
                    stat = f"{label}: {value}" if label else str(value)
            elif not prose and kind in ("text", "fact") and _text_of(b):
                prose = _text_of(b)
        if stat and prose:
            break
    line = " — ".join(p for p in (stat, prose) if p)
    if len(line) > _SUMMARY_MAX:
        line = line[: _SUMMARY_MAX - 1].rstrip() + "…"
    return line


def _payload(token: str, doc: dict) -> dict:
    return {
        "token": token,
        "url": share_url(token),
        "card_url": f"{share_url(token)}/card.png",
        "title": doc.get("title", ""),
        "summary": doc.get("summary", ""),
    }


def create(db, uid: str, report_type: str, report_id: str) -> dict:
    """Snapshot the caller's report and return ``{token, url, card_url,
    title, summary}``. ``ValueError`` for a type that can't be shared,
    ``KeyError`` when there's no such report, ``PermissionError`` when the
    caller isn't allowed to read it or it isn't theirs."""
    if report_type not in SHAREABLE_TYPES:
        raise ValueError(f"report type {report_type!r} can't be shared")
    report = report_hub.get_report(db, report_type, report_id, uid)
    if report["meta"].get("owner_uid") != uid:
        raise PermissionError("you can only share your own reports")

    fields = {
        "title": report["title"],
        "summary": summarize(report),
        "sections": report["sections"],
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    existing = (
        db.collection(SHARES_COLLECTION)
        .where("owner_uid", "==", uid)
        .where("report_type", "==", report_type)
        .where("report_id", "==", report_id)
        .where("revoked", "==", False)
        .limit(1)
        .stream()
    )
    for snap in existing:
        snap.reference.update(fields)
        return _payload(snap.id, fields)

    token = secrets.token_urlsafe(32)
    db.collection(SHARES_COLLECTION).document(token).set(
        {
            **fields,
            "owner_uid": uid,
            "report_type": report_type,
            "report_id": report_id,
            "revoked": False,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )
    return _payload(token, fields)


def revoke(db, uid: str, token: str) -> None:
    """Disable a share link. ``KeyError`` if unknown, ``PermissionError`` if
    it isn't the caller's. Revoking twice is a no-op."""
    ref = db.collection(SHARES_COLLECTION).document(token)
    snap = ref.get()
    doc = snap.to_dict() if snap.exists else None
    if not doc:
        raise KeyError(token)
    if doc.get("owner_uid") != uid:
        raise PermissionError("not your share")
    if not doc.get("revoked"):
        ref.update({"revoked": True, "revoked_at": firestore.SERVER_TIMESTAMP})


def fetch_public(db, token: str) -> dict | None:
    """The live snapshot for ``token`` or ``None`` (unknown, revoked, or its
    owner's account is deleted). Same answer for all three so a probe learns
    nothing."""
    if not token or len(token) > 128:
        return None
    snap = db.collection(SHARES_COLLECTION).document(token).get()
    doc = snap.to_dict() if snap.exists else None
    if not doc or doc.get("revoked"):
        return None
    owner = doc.get("owner_uid", "")
    if (
        owner
        and db.collection(schema.DELETED_ACCOUNTS).document(owner).get().exists
    ):
        return None
    return {
        "title": doc.get("title", ""),
        "summary": doc.get("summary", ""),
        "report_type": doc.get("report_type", ""),
        "sections": doc.get("sections") or [],
    }
