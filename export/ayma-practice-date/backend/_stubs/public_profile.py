"""Test-only stand-in for Ayma's viewer-visible profile serializer.

This reproduces the ONE guarantee the Practice Date privacy design relies on:
the **query-level** exclusion of never-load data. The real
``public_profile.build`` (Ayma private core) assembles the backend-authorized
public view of another user — it reads wiki pages with
``.where("visibility", "==", "public")`` (so private / ai_only pages are never
streamed from Firestore), strips ``{{private}}`` / ``{{ai_only}}`` spans from the
bodies that remain, and exposes only a coarse city and a computed age (never the
birthdate, never coordinates, never contact fields). It also enforces cross-user
read authorization, photo URL minting, match-score lookup, etc. — none of which
is part of this public repo.

This stand-in implements only the filtering contract, against the in-memory
``FakeDb``, so the extraction test can prove the never-load needles are never
*fetched* into the persona context. In production, ``practice_core`` binds to the
real serializer; the privacy boundary is identical, this is just the slice the
offline test needs.

NOT the production serializer. Added to ``sys.path`` only by ``tests/conftest.py``.
"""

from __future__ import annotations

from datetime import date

import story


def _age(birthdate) -> int | None:
    """Years from an ISO ``YYYY-MM-DD`` birthdate (coarse age only, never the
    birthdate itself leaves this function)."""
    if not birthdate:
        return None
    try:
        y, m, d = (int(x) for x in str(birthdate).split("-")[:3])
        today = date.today()
        return today.year - y - ((today.month, today.day) < (m, d))
    except (ValueError, TypeError):
        return None


def _public_pages(db, uid: str) -> list[dict]:
    """Public wiki pages only: filtered at query level to
    ``visibility == "public"``, with ``{{private}}`` / ``{{ai_only}}`` spans
    stripped and empty/hidden pages dropped. Mirrors the private serializer's
    ``_public_pages``."""
    try:
        docs = list(
            db.collection("users")
            .document(uid)
            .collection("wiki_pages")
            .where("visibility", "==", "public")
            .stream()
        )
    except Exception:  # noqa: BLE001
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
    """The viewer-visible public profile of ``other_uid`` for ``caller_uid``.

    Returns ``None`` when there is no real, named profile. Flags
    ``self`` / ``deleted`` / ``blocked`` the way the real serializer does so the
    caller (``practice_core.build_persona_context``) can refuse those cases."""
    other_uid = (other_uid or "").strip()
    if not other_uid:
        return None

    if db.collection("deleted_users").document(other_uid).get().exists:
        return {
            "uid": other_uid,
            "deleted": True,
            "self": False,
            "blocked": False,
            "name": "Deleted user",
            "age": None,
            "location": "",
            "photos": [],
            "pages": [],
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

    return {
        "uid": other_uid,
        "self": other_uid == caller_uid,
        "blocked": False,
        "name": name,
        # Coarse age only — computed here; the birthdate never leaves `_age`.
        "age": _age(prof.get("birthdate")),
        # Coarse city string shown on the card — never coordinates.
        "location": str(prof.get("location") or ""),
        "photos": list(prof.get("photos") or []),
        "pages": _public_pages(db, other_uid),
    }
