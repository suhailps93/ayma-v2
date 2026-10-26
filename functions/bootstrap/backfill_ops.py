"""Wiki-ingest backfill (§15).

Wiki ingest itself is exempt from the credit gate (``wiki_ingest`` module
docstring) — it now runs, and writes real wiki pages, even for a user
completely out of credits. This module's ``ingest_pending`` flag exists for a
*genuine* ingest failure instead — a Gemini API error, an unparseable
response, a transient Firestore blip — where ``wiki_ingest.ingest_or_defer``
stamps the ``raw_turns`` doc ``ingest_pending: true`` so it can be retried
once the underlying problem has passed; this module drains those docs — on a
top-up (harmless no-op trigger now, still wired for the credit-cap edge case
below), and nightly as a safety net. ``drain``'s own
``token_ledger.TokenCapExceeded`` handling is kept defensively (a caller could
still invoke :func:`wiki_ingest.ingest` directly with the gate enforced) but
is not expected to fire via the normal ingest path anymore.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

import token_ledger
import wiki_ingest
from transcript import Turn

logger = logging.getLogger("ayma.backfill")

_PENDING = "ingest_pending"
_PENDING_AT = "ingest_pending_at"

# Ceiling per drain so a long backlog can't burn a fresh balance in one shot —
# the rest waits for the next top-up / the nightly sweep.
_MAX_PER_DRAIN = 25


def _col(db, uid: str):
    return db.collection("users").document(uid).collection("raw_turns")


def mark_pending(db, uid: str, session_id: str) -> None:
    """Flag one ``raw_turns`` doc for re-ingest. Best-effort — never raises."""
    if not uid or not session_id:
        return
    try:
        from firebase_admin import firestore

        _col(db, uid).document(session_id).set(
            {_PENDING: True, _PENDING_AT: firestore.SERVER_TIMESTAMP},
            merge=True,
        )
    except Exception:  # noqa: BLE001
        logger.exception("mark_pending failed for %s/%s", uid, session_id)


def clear_pending(db, uid: str, session_id: str) -> None:
    """Drop one ``raw_turns`` doc's re-ingest flag after a successful ingest.
    Best-effort — never raises (a leftover flag only costs one re-ingest)."""
    if not uid or not session_id:
        return
    try:
        from firebase_admin import firestore

        _col(db, uid).document(session_id).set(
            {_PENDING: firestore.DELETE_FIELD,
             _PENDING_AT: firestore.DELETE_FIELD},
            merge=True,
        )
    except Exception:  # noqa: BLE001
        logger.exception("clear_pending failed for %s/%s", uid, session_id)


def _turns(data: dict) -> list[Turn]:
    out: list[Turn] = []
    for t in (data.get("turns") or []):
        text = str(t.get("text", "")).strip()
        if text:
            out.append(Turn(str(t.get("role", "")), text))
    return out


async def drain(db, uid: str, *, limit: int = _MAX_PER_DRAIN) -> int:
    """Re-ingest up to ``limit`` of ``uid``'s pending ``raw_turns`` docs, oldest
    first. Clears the flag on each success; stops early if credits run out
    again (the rest stay pending). Returns the count re-ingested."""
    if not uid:
        return 0
    from firebase_admin import firestore

    try:
        # Equality-only query (no order_by) so it needs no composite index;
        # a single user's pending backlog is small, so sort oldest-first here.
        docs = list(
            _col(db, uid)
            .where(_PENDING, "==", True)
            .limit(max(int(limit) * 4, int(limit)))
            .stream()
        )
        docs.sort(
            key=lambda d: (d.to_dict() or {}).get(_PENDING_AT)
            or datetime.min.replace(tzinfo=timezone.utc)
        )
        docs = docs[: int(limit)]
    except Exception:  # noqa: BLE001
        logger.exception("backfill query failed for %s", uid)
        return 0

    done = 0
    for doc in docs:
        turns = _turns(doc.to_dict() or {})
        try:
            if turns:
                await wiki_ingest.ingest(db, uid, doc.id, turns)
        except token_ledger.TokenCapExceeded:
            break  # still out of credits — leave the remainder pending
        except Exception:  # noqa: BLE001
            logger.exception("backfill ingest failed for %s/%s", uid, doc.id)
            continue
        try:
            doc.reference.set(
                {_PENDING: firestore.DELETE_FIELD,
                 _PENDING_AT: firestore.DELETE_FIELD},
                merge=True,
            )
        except Exception:  # noqa: BLE001
            logger.exception("backfill flag-clear failed for %s/%s", uid, doc.id)
        if turns:
            done += 1
    return done


async def sweep(db, user_limit: int = 200) -> dict:
    """Nightly: drain pending ingests for every user that has any. Bounded by
    ``user_limit`` users scanned per run."""

    scanned = drained = 0
    try:
        pending = list(
            db.collection_group("raw_turns")
            .where(_PENDING, "==", True)
            .limit(user_limit * 4)
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("backfill sweep query failed")
        return {"users": 0, "reingested": 0}

    seen: set[str] = set()
    for doc in pending:
        # users/{uid}/raw_turns/{id} -> uid is the grandparent id
        uid = doc.reference.parent.parent.id if doc.reference.parent.parent else ""
        if not uid or uid in seen:
            continue
        seen.add(uid)
        if len(seen) > user_limit:
            break
        scanned += 1
        try:
            drained += await drain(db, uid)
        except Exception:  # noqa: BLE001
            logger.exception("backfill sweep drain failed for %s", uid)
    return {"users": scanned, "reingested": drained}
