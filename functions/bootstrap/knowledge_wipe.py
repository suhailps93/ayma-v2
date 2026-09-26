""""Delete everything Ayma knows" (§14.2; founder request 2026-09-20) — wipe
Ayma's *derived/learned* understanding of a still-active user without
touching their account, login, or the app's ability to keep working.

Distinct from account deletion (``account_ops.py``): the account keeps
working normally, the user keeps their login, and this can be run more than
once, hence each run gets its own timestamped snapshot under
``archived_knowledge/{uid}/{archive_id}/...`` (``schema.ARCHIVED_KNOWLEDGE``)
rather than a single mutable archive doc.

**Line-drawing: what counts as "what Ayma knows" vs. account plumbing.**
``schema.KNOWLEDGE_SUBCOLLECTIONS`` / ``schema.KNOWLEDGE_FIELDS`` are the
single source of truth for the wiped set; the reasoning behind that list:

* **Wiped** (Ayma's derived/learned understanding): wiki pages (+ their
  version history), raw conversation turns, the AI-companion chat transcript,
  pending onboarding questions, the questionnaire, the completeness cache,
  photo notes, every appearance/physical/face/body report (current pointer +
  full history), deep-dive/web-search reports, the skill-run ledger, the
  ``trust_flags`` and ``face_verification`` fields.
* **Deliberately NOT wiped** (account/identity plumbing the app needs to
  keep functioning, or content that isn't "Ayma's knowledge" so much as the
  user's own material):
  - ``profile/main`` — kept live. It holds core matching-required fields
    (name, birthdate, gender, location, the photo list) the app cannot
    function without; nuking it would break matching/explore mid-session for
    a user who never asked to lose their account. If product later wants
    AI-inferred *fields within* the profile reset too, that needs a
    field-level allowlist, not a whole-document reset — flagged as a
    follow-up, not done here.
  - ``user_media`` (the photos themselves) — kept live, so "wipe what Ayma
    has learned" doesn't force a re-upload; only the *analysis* derived from
    the photos (appearance/physical/face/body reports) is wiped.
  - ``oauth_tokens``, ``notification_prefs``, ``fcm_tokens``/push state,
    credit/token-usage fields (``token_ledger``), ``turn_caps`` counters,
    ``reengagement`` state, ``instagram_access_token`` — account/billing/
    device plumbing, explicitly excluded per the founder's own framing
    ("credits ledger ... probably should NOT be wiped").
  - ``match_candidates`` / ``likes`` / ``explore_passed`` / ``notifications``
    — matching mechanics and notification history, not "what Ayma has
    learned about me" in the sense the settings-screen copy ("Wipe what Ayma
    has learned?") means; wiping these would disrupt the user's active
    social graph as a side effect of what's framed as a memory reset.
  - ``matches`` / ``dm_threads`` — shared with other users; a self-service
    memory wipe must never touch another user's data (same principle as
    account deletion's point-3 judgment call).
  - ``feedback`` (conversational feedback about Ayma's behavior, which
    drives the ``steering`` wiki page) IS wiped — it's raw material Ayma
    would otherwise re-derive knowledge from. ``product_feedback`` /
    ``bug_reports`` are support tickets, not per-user knowledge, and are
    left alone.

Backs ``POST /wiki/reset`` (same endpoint the Flutter settings screen already
calls for "Wipe what Ayma has learned?" — this replaces that route's old
inline, non-archiving, 3-collection-only wipe with a full archive-then-reset
across every category above).
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

from firebase_admin import firestore

import schema

logger = logging.getLogger("ayma.knowledge_wipe")

# Conversational feedback (schema has no constant for this — it's a plain
# top-level collection queried by a `uid` field, see feedback_ops.py).
_FEEDBACK_COLLECTION = "feedback"
_QUERY_LIMIT = 500


def _archive_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{uuid.uuid4().hex[:8]}"


def wipe_knowledge(db, uid: str) -> dict:
    """Archive + reset everything in ``schema.KNOWLEDGE_SUBCOLLECTIONS`` /
    ``schema.KNOWLEDGE_FIELDS`` (plus conversational ``feedback``) for
    ``uid``. The account, profile, photos, credits and login are untouched.

    Returns ``{"ok": True, "archive_id": str, "archived": {name: count}}``.
    """
    archive_id = _archive_id()
    user = schema.user_doc(db, uid)
    archive = (
        db.collection(schema.ARCHIVED_KNOWLEDGE)
        .document(uid)
        .collection("snapshots")
        .document(archive_id)
    )
    archive.set(
        {"archived_at": firestore.SERVER_TIMESTAMP, "original_uid": uid}
    )

    archived: dict[str, int] = {}
    for name in schema.KNOWLEDGE_SUBCOLLECTIONS:
        n = 0
        for child in user.collection(name).stream():
            archive.collection(name).document(child.id).set(
                child.to_dict() or {}
            )
            for nested in schema.NESTED_SUBCOLLECTIONS.get(name, ()):
                for grandchild in child.reference.collection(nested).stream():
                    archive.collection(name).document(child.id).collection(
                        nested
                    ).document(grandchild.id).set(grandchild.to_dict() or {})
                    grandchild.reference.delete()
            child.reference.delete()
            n += 1
        archived[name] = n

    feedback_n = 0
    for snap in (
        db.collection(_FEEDBACK_COLLECTION)
        .where("uid", "==", uid)
        .limit(_QUERY_LIMIT)
        .stream()
    ):
        archive.collection(_FEEDBACK_COLLECTION).document(snap.id).set(
            snap.to_dict() or {}
        )
        snap.reference.delete()
        feedback_n += 1
    archived[_FEEDBACK_COLLECTION] = feedback_n

    account_snap = user.get()
    account_data = account_snap.to_dict() or {}
    field_snapshot = {
        f: account_data[f] for f in schema.KNOWLEDGE_FIELDS if f in account_data
    }
    if field_snapshot:
        archive.set({"fields": field_snapshot}, merge=True)
    if account_snap.exists and field_snapshot:
        user.update({f: firestore.DELETE_FIELD for f in field_snapshot})

    return {"ok": True, "archive_id": archive_id, "archived": archived}
