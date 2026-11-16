"""One-time migration: the three stores + Ayma's assessment → the overlay.

Per design §9 the person graph is seeded from what a user already has:

1. **Questionnaire answers** → overlay entries directly (node ids already match
   the seed — the easy half).
2. **Profile fields** → the 5 level-1 nodes (name, DOB, gender, interested-in,
   location), provenance ``imported``. These win over a questionnaire doc for
   the same node (completeness's precedence).
3. **Wiki / story prose** → each story bullet becomes an emergent node homed in
   its section, keeping its visibility, provenance ``imported``. Anything that
   can't be placed lands under Little Extras rather than being dropped.
4. **Ayma's private assessment** → Ayma-only emergent nodes, provenance
   ``inferred``.

Migration is **idempotent**: emergent node ids are derived deterministically
from their source (page + index / field), so re-running overwrites rather than
duplicating. It never deletes a source store — the old documents stay read-only
until the graph path is verified, then the cutover phase removes them.

This module builds the overlay; ``write=True`` persists it through
:mod:`person_graph_store` (validated at the boundary). Byte-level parity of the
graph renders against the live wiki is verified per account after migration.
"""

from __future__ import annotations

import hashlib
from typing import Any

import person_graph as pg
import person_graph_store as store
import question_tree
from person_graph import NodeState, Provenance, Visibility

# story-model visibility strings → graph visibility
_GRAPH_VIS = {
    "public": Visibility.PUBLIC.value,
    "private": Visibility.PRIVATE.value,
    "ai_only": Visibility.AYMA_ONLY.value,
}

_PROFILE_DERIVABLE = {
    "legal_first_name": "name",
    "date_of_birth": "birthdate",
    "gender_identity": "gender",
    "target_match_genders": "interested_in",
    "primary_location": "location",
}

_LITTLE_EXTRAS = "misc"

# questionnaire answer values that are meta / non-answers — not real content
# (Scout 2449 blocker 3: these leaked through as story bullets).
_META_SENTINELS = {"skipped", "addressed", "n/a", "none", "prefer not to say", ""}


def _emergent_id(prefix: str, *parts: str) -> str:
    h = hashlib.sha1("|".join(parts).encode("utf-8")).hexdigest()[:8]
    return f"emergent.{prefix}.{h}"


def _profile_doc(db, uid: str) -> dict:
    snap = (
        db.collection("users").document(uid)
        .collection("profile").document("main").get()
    )
    return (snap.to_dict() if snap and snap.exists else None) or {}


# --- 1. questionnaire answers ---------------------------------------------


def migrate_questionnaire(db, uid: str) -> dict[str, dict]:
    """Questionnaire docs → overlay entries on their matching seed nodes."""
    out: dict[str, dict] = {}
    stream = (
        db.collection("users").document(uid)
        .collection("questionnaire").stream()
    )
    for snap in stream:
        data = snap.to_dict() or {}
        nid = data.get("node_id") or getattr(snap, "id", None)
        if not nid or pg.seed_node(nid) is None:
            continue  # unknown/retired ids are handled by the wiki/extras path
        value = data.get("value")
        if value is None or value == "":
            continue
        if isinstance(value, str) and value.strip().lower() in _META_SENTINELS:
            continue  # skipped/addressed/etc. is not an answer — don't surface it
        src = str(data.get("source") or "stated").lower()
        prov = Provenance.INFERRED if src == "inferred" else Provenance.STATED
        entry: dict[str, Any] = {
            "answer": value,
            "state": NodeState.ANSWERED.value,
            "provenance": prov.value,
        }
        if prov is Provenance.INFERRED:
            # 'high'/'low' confidence strings → a float
            conf = str(data.get("confidence") or "low").lower()
            entry["confidence"] = 0.9 if conf == "high" else 0.5
        out[nid] = entry
    return out


# --- 2. profile fields -----------------------------------------------------


def migrate_profile(db, uid: str) -> dict[str, dict]:
    """The 5 derivable profile fields → their level-1 nodes, imported."""
    prof = _profile_doc(db, uid)
    out: dict[str, dict] = {}
    for nid, field in _PROFILE_DERIVABLE.items():
        val = prof.get(field)
        if val in (None, "", []):
            continue
        out[nid] = {
            "answer": val,
            "state": NodeState.ANSWERED.value,
            "provenance": Provenance.IMPORTED.value,
        }
    return out


# --- 3. wiki / story prose -------------------------------------------------


def migrate_wiki(db, uid: str) -> dict[str, dict]:
    """Every public/private story bullet → an emergent node homed in its
    section, keeping the bullet's visibility. Unknown sections land under Little
    Extras. Ayma-only passages are left to :func:`migrate_assessment`.

    The emergent id is derived from ``(section, normalised text)``, so the same
    bullet reached through **duplicate wiki pages** (same canonical section,
    different page_id) collapses to ONE node — the graph's "one home per fact"
    rule (design §2.4), matching the dedupe the legacy ``get_bullets`` did by
    text within a canonical page_type. On a collision the **more private**
    visibility wins (order-independent), so a private copy never becomes
    public."""
    import story
    import story_bullets

    # publicness order: lower = more public (public < private < ayma_only)
    _rank = {
        Visibility.PUBLIC.value: 0,
        Visibility.PRIVATE.value: 1,
        Visibility.AYMA_ONLY.value: 2,
    }

    out: dict[str, dict] = {}
    for sec in story.get_story(db, uid).get("sections", []):
        page_id = sec.get("page_id", "")
        if page_id in getattr(story, "REPORT_LINKED_PAGE_IDS", set()):
            continue  # report-linked pages become report-view nodes, not here
        page_type = sec.get("page_type") or ""
        if page_type not in question_tree.section_meta():
            # The live story only renders canonical sections (profile_bullets
            # skips the rest — e.g. the health/sensitive page). Match it: a
            # non-canonical page is NOT story content, so it does not surface
            # here (Scout 2449 blocker 4). Its content is retained Ayma-only by
            # migrate_assessment where applicable, never in Your Story/public.
            continue
        section = page_type
        vis = sec.get("visibility") or "private"
        bullets = story_bullets.parse_bullets(sec.get("body") or "", vis, page_id=page_id)
        for b in bullets:
            text = (b.get("text") or "").strip()
            if not text or b.get("visibility") == "ai_only":
                continue
            # id keyed on section + normalised text → duplicate-page bullets dedupe
            nid = _emergent_id("story", section, text.casefold())
            vis = _GRAPH_VIS.get(b.get("visibility"), Visibility.PRIVATE.value)
            if nid in out:
                # same fact already homed — keep the more private visibility
                if _rank[vis] > _rank[out[nid]["visibility"]]:
                    out[nid]["visibility"] = vis
                continue
            out[nid] = {
                "prompt": text,
                "section": section,
                "level": 2,
                "answer": text,
                "answer_type": "narrative",
                "state": NodeState.ANSWERED.value,
                "visibility": vis,
                "provenance": Provenance.IMPORTED.value,
            }
    return out


# --- 4. Ayma's private assessment -----------------------------------------


def migrate_assessment(db, uid: str) -> dict[str, dict]:
    """Ayma's private assessment (and any ai_only story passage) → Ayma-only
    emergent nodes, provenance inferred. These never render in Your Story or
    the public profile; they are Ayma's own knowledge of the user."""
    import story
    import story_bullets

    out: dict[str, dict] = {}
    notes = story.get_ai_notes(db, uid) if hasattr(story, "get_ai_notes") else {"sections": []}
    for sec in notes.get("sections", []):
        page_id = sec.get("page_id", "")
        page_type = sec.get("page_type") or _LITTLE_EXTRAS
        section = page_type if page_type in question_tree.section_meta() else _LITTLE_EXTRAS
        bullets = story_bullets.parse_bullets(
            sec.get("body") or "", sec.get("visibility") or "ai_only", page_id=page_id
        )
        for i, b in enumerate(bullets):
            if b.get("visibility") != "ai_only":
                continue  # public/private handled by migrate_wiki
            text = (b.get("text") or "").strip()
            if not text:
                continue
            nid = _emergent_id("assess", page_id or page_type, str(i), text)
            out[nid] = {
                "prompt": text,
                "section": section,
                "level": 2,
                "answer": text,
                "answer_type": "narrative",
                "state": NodeState.ANSWERED.value,
                "visibility": Visibility.AYMA_ONLY.value,
                "provenance": Provenance.INFERRED.value,
                "confidence": 0.5,
            }
    return out


# --- compose + write -------------------------------------------------------


def build_overlay(db, uid: str) -> dict[str, dict]:
    """The full migrated overlay. Precedence for a seed node that several
    sources touch: profile-derivable field wins over a questionnaire doc
    (mirrors completeness)."""
    overlay: dict[str, dict] = {}
    overlay.update(migrate_questionnaire(db, uid))
    overlay.update(migrate_profile(db, uid))  # derivable fields win
    # emergent nodes never collide with seed nodes (deterministic ids)
    overlay.update(migrate_wiki(db, uid))
    overlay.update(migrate_assessment(db, uid))
    return overlay


def migrate_user(
    db, uid: str, *, write: bool = False, replace: bool = False
) -> dict[str, dict]:
    """Build (and optionally persist) a user's migrated overlay.

    - ``write`` + ``replace=False`` (default): merge the fresh migration output
      over whatever the overlay already holds. Idempotent within one id scheme.
    - ``write`` + ``replace=True``: persist the fresh output as the WHOLE node
      set, dropping any stale node (e.g. the pre-dedupe duplicate ids). Use this
      to RE-migrate after a migration-logic change, while the graph is still
      migration-only (pre-switch, no user edits to preserve)."""
    overlay = build_overlay(db, uid)
    pg.validate_overlay(overlay)  # never persist a malformed node
    if write and replace:
        store.replace_overlay(db, uid, overlay)
        return overlay
    if write:
        existing = store.load_overlay(db, uid)
        existing.update(overlay)
        store._save_overlay(db, uid, existing)
        return existing
    return overlay
