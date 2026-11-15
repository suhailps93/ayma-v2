"""Per-user supplemental questionnaire entries — volunteered / off-tree info.

Requirement 4 of the questionnaire-discipline fix (founder, 2026-11-14): users
also volunteer information Ayma never asked about — topics that aren't tree
questions at all, and answers to things that were never tree questions. Those
are captured here, in the **same shape as a tree node** (section, topic, answer,
state), in a per-user store that sits **alongside** the structured questionnaire
answers — never by editing the shared master :mod:`question_tree` config. They
are written by the one mandatory recording path (:mod:`questionnaire_ingest`),
not by the model remembering to call a tool (requirement 3), and read by the
check-before-asking gate (:mod:`completeness`, the per-turn questionnaire note)
so a volunteered topic counts as known and Ayma never asks about it again.

Stored at ``users/{uid}/questionnaire_supplemental/{slug}`` — one doc per topic,
keyed by a slug of the topic text, so re-volunteering the same thing updates it
in place rather than piling up duplicates.
"""

from __future__ import annotations

import logging
import re

from firebase_admin import firestore

import question_tree

logger = logging.getLogger("ayma.supplemental")

# Mirrors a tree node's ``state``: a complete answer vs. one Ayma could still
# follow up on. Anything else normalises to "answered".
VALID_STATUS = ("answered", "partial")

_MISC_SECTION = "misc"
_COLLECTION = "questionnaire_supplemental"

# A topic is a short label ("Their dog Max", "Marathon training"), never prose;
# the value carries the substance.
_MAX_TOPIC_CHARS = 120
_MAX_VALUE_CHARS = 2000
_MAX_SLUG_CHARS = 64


def _valid_sections() -> set[str]:
    """The tree's own section ids (``page_type``) plus ``misc`` for genuinely
    off-tree topics. Keeps supplemental sections in the same vocabulary as tree
    nodes so the state-check surface groups them the same way."""
    return set(question_tree.PAGE_TYPE_LABELS.keys()) | {_MISC_SECTION}


def _slug(topic: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (topic or "").strip().lower()).strip("-")
    return s[:_MAX_SLUG_CHARS]


def _norm_section(section: str) -> str:
    s = (section or "").strip().lower()
    return s if s in _valid_sections() else _MISC_SECTION


def record_supplemental(
    db,
    uid: str,
    section: str,
    topic: str,
    value: str,
    status: str = "answered",
    *,
    session_id: str = "",
) -> str | None:
    """Upsert one supplemental entry (keyed by a slug of ``topic``). Returns the
    doc id, or ``None`` when the inputs are too thin to record."""
    topic = " ".join((topic or "").split())[:_MAX_TOPIC_CHARS]
    value = " ".join((value or "").split())[:_MAX_VALUE_CHARS]
    if not uid or not topic or not value:
        return None
    slug = _slug(topic)
    if not slug:
        return None
    st = status if status in VALID_STATUS else "answered"
    doc = (
        db.collection("users")
        .document(uid)
        .collection(_COLLECTION)
        .document(slug)
    )
    payload = {
        "section": _norm_section(section),
        "topic": topic,
        "value": value,
        "status": st,
        "source": "volunteered",
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    if session_id:
        payload["session_id"] = session_id
    try:
        if not getattr(doc.get(), "exists", False):
            payload["created_at"] = firestore.SERVER_TIMESTAMP
    except Exception:  # noqa: BLE001 - a read blip just means no created_at stamp
        pass
    doc.set(payload, merge=True)
    return slug


def read_supplemental(db, uid: str) -> list[dict]:
    """Every supplemental entry for ``uid`` as ``[{id, section, topic, value,
    status}]``. Best-effort: a read failure yields an empty list."""
    if not uid:
        return []
    try:
        out: list[dict] = []
        for snap in (
            db.collection("users")
            .document(uid)
            .collection(_COLLECTION)
            .stream()
        ):
            d = snap.to_dict() or {}
            out.append(
                {
                    "id": snap.id,
                    "section": d.get("section", _MISC_SECTION),
                    "topic": d.get("topic", ""),
                    "value": d.get("value", ""),
                    "status": d.get("status", "answered"),
                }
            )
        return out
    except Exception:  # noqa: BLE001
        logger.exception("supplemental read failed for %s", uid)
        return []
