"""Pending-questions queue (ARCHITECTURE.md §2.4, §2.8 step 5).

Task state — what Ayma should ask next — not compiled knowledge, so it is a
plain Firestore collection, not a wiki page, and has no visibility tier. The
agent's ``add_followup_question`` tool (voice and text) writes here when it
spots a topic worth pursuing but doesn't want to derail the current turn.
"""

from __future__ import annotations

from firebase_admin import firestore

from wiki_schema import page_types

_VALID_SOURCE = {"catalog", "followup"}


def add_followup_question(
    db,
    uid: str,
    question_text: str,
    category: str,
    target_page: str | None = None,
    source: str = "followup",
) -> str | None:
    """Append a pending question. Returns the new doc id, or ``None`` if the
    inputs are empty."""
    question = (question_text or "").strip()
    if not uid or not question:
        return None

    cat = (category or "").strip()
    if cat not in page_types():
        cat = "misc"
    if source not in _VALID_SOURCE:
        source = "followup"

    doc = (
        db.collection("users")
        .document(uid)
        .collection("pending_questions")
        .document()
    )
    payload = {
        "question_text": question,
        "category": cat,
        "source": source,
        "status": "pending",
        "created_at": firestore.SERVER_TIMESTAMP,
        "answered_at": None,
    }
    target = (target_page or "").strip()
    if target:
        payload["target_page"] = target
    doc.set(payload)
    return doc.id
