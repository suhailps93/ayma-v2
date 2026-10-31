"""Feedback capture — one ``feedback`` collection, discriminated by ``source``
(ARCHITECTURE.md §15, feedback loop).

Every row lives in the top-level ``feedback/{id}`` collection, tagged with a
``source``:

* ``source="ayma"`` / ``"thumbs_down"`` — **conversational** feedback about how
  Ayma does her job (repeats questions, drifts off the questionnaire, rambles,
  ignores an answer, tone, pacing). Written by Ayma's ``record_feedback`` tool
  when she notices friction, and by the client's one-tap thumbs-down
  (:func:`record`). Two things read it: immediately, :func:`record` appends a
  short standing correction to *this one user's* ``steering`` wiki page
  (real-time, per-user — ``steering_ops.add_rule``); separately, a daily job
  (``persona_evolution.py``) aggregates it across every user and proposes
  additions to the shared ``lessons.md`` persona corrections (eval-gated;
  critical changes held for admin approval). These rows carry
  ``category``/``note``/``quote``/``severity``.

* ``source="chat_card"`` / ``"settings_form"`` — **product feedback**: bugs and
  feature requests (:func:`record_submission`). ``chat_card`` comes from the
  in-chat feedback catcher (the ``submit_feedback`` tool → an editable
  confirmation card the user sends); ``settings_form`` comes from the "Send
  feedback" form in Settings. Ayma never reads these rows. They carry
  ``kind`` (``feature``/``bug``), ``title``, ``body``, ``screenshot_paths``,
  ``screen``, ``app_version``, ``platform``. The dev team triages them via the
  in-app Developer → Feedback view (``GET /admin/feedback``). Any Ayma-facing
  read of the collection filters by ``source`` so product rows never leak into
  the persona loop (see :data:`_PRODUCT_SOURCES`).

The collection is written only via the Admin SDK (clients can't write it — see
``firestore.rules``). Writes are best-effort and never raise.

(The legacy ``product_feedback/{id}`` collection is retired: nothing writes it
any more — the Settings form now routes here as ``source="settings_form"``. Its
few historical rows are still handled by account archival/purge.)
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

# Product-feedback vocab (the ``submit_feedback`` catcher + the Settings form).
_VALID_SUBMISSION_KIND = frozenset({"feature", "bug"})
_PRODUCT_SOURCES = frozenset({"chat_card", "settings_form"})
_VALID_STATUS = frozenset({"new", "triaged", "done"})

_MAX_TEXT = 4000
_MAX_TITLE = 120
_MAX_PATH = 256
_MAX_SHOTS = 6


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


def record_submission(
    db,
    uid: str,
    kind: str,
    title: str,
    body: str,
    *,
    source: str,
    screenshot_paths: list[str] | None = None,
    screen: str = "",
    app_version: str = "",
    platform: str = "",
) -> str | None:
    """Append one product-feedback row (bug / feature request) to ``feedback``.

    Used by the in-chat feedback catcher (``source="chat_card"``) and the
    Settings "Send feedback" form (``source="settings_form"``). Ayma never
    reads these rows. ``screenshot_paths`` are Storage paths already validated
    by the caller to live under ``uploads/{uid}/`` — the admin view resolves
    them to short-lived signed URLs rather than storing a public URL.
    """
    if not uid:
        return None
    title, body = _clip(title, _MAX_TITLE), _clip(body)
    if not title and not body:
        return None

    k = kind if kind in _VALID_SUBMISSION_KIND else "feature"
    src = source if source in _PRODUCT_SOURCES else "chat_card"
    paths = [
        _clip(p, _MAX_PATH)
        for p in (screenshot_paths or [])
        if isinstance(p, str) and p.strip()
    ][:_MAX_SHOTS]

    try:
        from firebase_admin import firestore

        doc = db.collection("feedback").document()
        doc.set(
            {
                "uid": uid,
                "source": src,
                "kind": k,
                "title": title or (body[:_MAX_TITLE]),
                "body": body,
                # ``screenshot_url`` keeps the single-screenshot shape the chat
                # card uses; ``screenshot_paths`` keeps the Settings form's
                # several. Both hold Storage PATHS, not public URLs.
                "screenshot_url": paths[0] if paths else None,
                "screenshot_paths": paths,
                "screen": _clip(screen, 128),
                "app_version": _clip(app_version, 64),
                "platform": _clip(platform, 32),
                "status": "new",
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        return doc.id
    except Exception:  # noqa: BLE001
        logger.exception("product feedback record failed for %s", uid)
        return None


def list_submissions(db, *, limit: int = 100) -> list[dict]:
    """Product-feedback rows (``source`` in :data:`_PRODUCT_SOURCES`), newest
    first, for the admin triage view. Fetches by ``created_at`` desc and
    filters ``source`` in Python so no composite index is required — this is a
    low-volume dev tool, not a hot path."""
    try:
        from firebase_admin import firestore

        snaps = (
            db.collection("feedback")
            .order_by("created_at", direction=firestore.Query.DESCENDING)
            .limit(max(1, min(limit * 5, 1000)))
            .stream()
        )
        out: list[dict] = []
        for s in snaps:
            d = s.to_dict() or {}
            if d.get("source") not in _PRODUCT_SOURCES:
                continue
            created = d.get("created_at")
            out.append(
                {
                    "id": s.id,
                    "uid": d.get("uid", ""),
                    "source": d.get("source", ""),
                    "kind": d.get("kind", ""),
                    "title": d.get("title", ""),
                    "body": d.get("body", ""),
                    "screenshot_paths": d.get("screenshot_paths", []),
                    "screen": d.get("screen", ""),
                    "app_version": d.get("app_version", ""),
                    "platform": d.get("platform", ""),
                    "status": d.get("status", "new"),
                    "created_at": (
                        created.isoformat()
                        if hasattr(created, "isoformat")
                        else None
                    ),
                }
            )
            if len(out) >= limit:
                break
        return out
    except Exception:  # noqa: BLE001
        logger.exception("product feedback list failed")
        return []


def set_submission_status(db, fid: str, status: str) -> bool:
    """Set a product-feedback row's triage ``status`` (new/triaged/done).
    Returns ``True`` on success. Refuses an unknown status or a row that is
    not a product-feedback row (so this can't mutate a conduct row)."""
    if not fid or status not in _VALID_STATUS:
        return False
    try:
        ref = db.collection("feedback").document(fid)
        snap = ref.get()
        if not snap.exists:
            return False
        if (snap.to_dict() or {}).get("source") not in _PRODUCT_SOURCES:
            return False
        ref.set({"status": status}, merge=True)
        return True
    except Exception:  # noqa: BLE001
        logger.exception("product feedback status update failed for %s", fid)
        return False
