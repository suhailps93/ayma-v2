"""Per-user steering — standing "how to talk to *me*" rules Ayma has been told
(ARCHITECTURE.md §15, user-specific feedback).

Stored as one ``ai_only`` wiki page per user (``page_id: "steering"``) — the
user's own standing instructions, kept in Ayma's private notes, never shown
in Story/Public view (per the founder's explicit call: steering rules are as
sensitive as `interactions` and should default the same way). The AI read
path (``wiki_query.read_wiki_context``) includes every page's ``ai_body``
unfiltered, so anything appended here flows into that user's system prompt on
every future turn regardless of visibility tier.

Example rules: "don't ask about my dog", "keep questions short", "stop
circling back to my ex".
"""

from __future__ import annotations

import logging

logger = logging.getLogger("ayma.steering")

_PAGE_ID = "steering"
_MAX_RULE = 240
_MAX_RULES = 40


def _page(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(_PAGE_ID)
    )


def _rules(body: str) -> list[str]:
    return [
        ln[1:].strip() if ln.strip().startswith("-") else ln.strip()
        for ln in (body or "").splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]


def add_rule(db, uid: str, rule: str) -> str | None:
    """Append a steering rule to the user's ``ai_only`` steering page. A rule
    already present (case-insensitive) is a no-op. Returns the stored rule, or
    ``None`` if nothing was written."""
    rule = " ".join((rule or "").split())[:_MAX_RULE]
    if not uid or not rule:
        return None
    try:
        from firebase_admin import firestore

        snap = _page(db, uid).get()
        existing = _rules((snap.to_dict() or {}).get("ai_body", "")) if snap.exists else []
        if any(r.lower() == rule.lower() for r in existing):
            return rule
        existing.append(rule)
        existing = existing[-_MAX_RULES:]

        body = (
            "Standing instructions this user has given about how to talk to "
            "them — follow every one:\n" + "\n".join(f"- {r}" for r in existing)
        )
        payload = {
            "ai_body": body,
            "visibility": "ai_only",
            "page_type": _PAGE_ID,
            "updated_at": firestore.SERVER_TIMESTAMP,
        }
        if not snap.exists:
            payload["created_at"] = firestore.SERVER_TIMESTAMP
        _page(db, uid).set(payload, merge=True)
        return rule
    except Exception:  # noqa: BLE001 - never break a chat turn
        logger.exception("steering add_rule failed for %s", uid)
        return None
