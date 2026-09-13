"""Feedback capture — two separate buckets (ARCHITECTURE.md §15, feedback loop).

* ``feedback/{id}`` — **conversational** feedback about how Ayma does her job
  (repeats questions, drifts off the questionnaire, rambles, ignores an answer,
  tone, pacing). Written by Ayma's ``record_feedback`` tool when she notices
  friction, and by the client's one-tap thumbs-down. Two things read this:
  immediately, :func:`record` also appends a short standing correction to
  *this one user's* ``steering`` wiki page (real-time, per-user — see
  ``steering_ops.add_rule``); separately, a daily job (``persona_evolution.py``)
  aggregates it across every user and proposes additions to the shared
  ``lessons.md`` persona corrections (automated eval gate; critical changes
  held for admin approval) — the base persona is never rewritten unchecked.

* ``product_feedback/{id}`` — **bugs and feature requests**. Ayma never touches
  this bucket. Submitted from the Profile screen with optional screenshots;
  the dev team triages it by hand.

Both are top-level collections written only via the Admin SDK (clients can't
write them — see ``firestore.rules``). Writes are best-effort and never raise.
"""

from __future__ import annotations

import logging

logger = logging.getLogger("ayma.feedback")

# Per-category phrasing for the real-time per-user steering rule a piece of
# conversational feedback triggers — short, imperative, same voice as other
# steering rules (ARCHITECTURE.md §15 Part A). Deliberately fixed strings
# rather than the raw note: `steering_ops.add_rule` dedupes by exact text, so
# repeated feedback in the same category collapses into one rule instead of
# piling up near-duplicates. "other" has no reliable canned phrasing, so it
# falls back to the note itself (see `_steering_rule`).
_STEERING_RULES: dict[str, str] = {
    "repeated_question": (
        "Don't ask the same question twice — check what's already been "
        "covered before asking."
    ),
    "off_script": "Stay with the topic at hand instead of drifting off it.",
    "rambling": "Keep replies tight and concrete — don't ramble or run long.",
    "ignored_answer": (
        "Actually engage with what I just said before moving on."
    ),
    "too_many_questions": (
        "Ask one question at a time — don't stack several into one turn."
    ),
    "tone": "Watch your tone with me — not too pushy, not too flat.",
    "pacing": "Watch your pacing with me — don't rush through or drag it out.",
    "thumbs_down": (
        "A recent reply of yours didn't land with me — read the room and "
        "adjust."
    ),
}


def _steering_rule(category: str, note: str) -> str:
    return _STEERING_RULES.get(category) or note


# Controlled vocab so the daily aggregation can bucket cleanly. Anything else
# is coerced to "other".
CATEGORIES = frozenset(
    {
        "repeated_question",
        "off_script",
        "rambling",
        "ignored_answer",
        "too_many_questions",
        "tone",
        "pacing",
        "thumbs_down",
        "other",
    }
)

_VALID_SOURCE = frozenset({"ayma", "user", "thumbs_down"})
_VALID_SEVERITY = frozenset({"low", "medium", "high"})
_VALID_KIND = frozenset({"bug", "idea"})

_MAX_TEXT = 4000


def _clip(s: str | None, n: int = _MAX_TEXT) -> str:
    return (s or "").strip()[:n]


def record(
    db,
    uid: str,
    category: str,
    note: str = "",
    *,
    quote: str = "",
    severity: str = "low",
    source: str = "ayma",
    session_id: str = "",
) -> str | None:
    """Append one conversational-feedback row. Returns the new doc id, or
    ``None`` when there's nothing to record."""
    if not uid:
        return None
    note, quote = _clip(note), _clip(quote)
    if not note and not quote:
        return None

    cat = category if category in CATEGORIES else "other"
    src = source if source in _VALID_SOURCE else "ayma"
    sev = severity if severity in _VALID_SEVERITY else "low"

    try:
        from firebase_admin import firestore

        doc = db.collection("feedback").document()
        doc.set(
            {
                "uid": uid,
                "session_id": _clip(session_id, 128),
                "category": cat,
                "note": note,
                "quote": quote,
                "severity": sev,
                "source": src,
                "status": "new",
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        fid = doc.id
    except Exception:  # noqa: BLE001 - capture must never break a request
        logger.exception("feedback record failed for %s", uid)
        return None

    # Real-time per-user loop (§15 Part A): the correction lands on this
    # user's own `steering` wiki page immediately, so it changes how Ayma
    # talks to *them* on the very next turn — no batching, no review needed,
    # because it only ever affects the one user who gave the feedback.
    try:
        import steering_ops

        rule = _steering_rule(cat, note or quote)
        if rule:
            steering_ops.add_rule(db, uid, rule)
    except Exception:  # noqa: BLE001 - never let this break feedback capture
        logger.exception("steering add_rule failed for %s", uid)

    return fid


def record_product(
    db,
    uid: str,
    kind: str,
    text: str,
    image_paths: list[str] | None = None,
    *,
    app_version: str = "",
) -> str | None:
    """Append one bug / feature-request row. Ayma does not read this bucket."""
    if not uid:
        return None
    text = _clip(text)
    if not text:
        return None

    k = kind if kind in _VALID_KIND else "bug"
    paths = [
        _clip(p, 256)
        for p in (image_paths or [])
        if isinstance(p, str) and p.strip()
    ][:6]

    try:
        from firebase_admin import firestore

        doc = db.collection("product_feedback").document()
        doc.set(
            {
                "uid": uid,
                "kind": k,
                "text": text,
                "image_paths": paths,
                "app_version": _clip(app_version, 64),
                "status": "new",
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id
    except Exception:  # noqa: BLE001
        logger.exception("product feedback record failed for %s", uid)
        return None
