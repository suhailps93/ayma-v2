"""``set_profile_field`` — update one of the user's own structured identity /
profile fields (§3.3, §4.2, Step 31). Originally preboarding-only ("autofill
this screen's field"); extended (founder scope-expansion request,
2026-09-16) to also work in ordinary ongoing chat/voice, so a returning user
can say "change my name to Sam" or "update my number" any time — the tool
itself was never actually gated to preboarding in code (it's always been in
the shared ``_REGISTRY``, so voice and text always had it available); only
the system prompt ever restricted *when* Ayma reached for it. It writes the
structured ``users/{uid}/profile/main`` doc only.

SAFETY: this Cloud Run service writes with Admin SDK credentials, so
``firestore.rules`` (client-side security rules) never runs against this
write — including ``isAdultBirthdate()``, the 18+ floor added there
specifically because ``birthdate`` used to have no backend HTTP endpoint at
all (a direct client Firestore write, so the rule was the only enforcement
layer). Making this tool reachable from general chat reopens exactly that
gap unless the same 18+ check also lives here, at the Python layer — see
``_is_adult_birthdate`` below, which mirrors the rule's exact arithmetic.
Never remove that check without adding an equivalent one.
"""

from __future__ import annotations

import datetime
import logging
from typing import Callable

from firebase_admin import firestore

import age_gate

from ._base import Skill, last_user_quote

logger = logging.getLogger("ayma.set_profile_field")

_FIELDS = (
    "name",
    "first_name",
    "last_name",
    "phone",
    "birthdate",
    "gender",
    "interested_in",
    "location",
)
_VALUE_HINT = (
    "their words; birthdate YYYY-MM-DD; gender Woman|Man|Non-binary|Other; "
    "interested_in comma-separated of Women|Men|Everyone"
)
_GENDERS = {"woman", "man", "non-binary", "other"}
_INTERESTS = {"women", "men", "everyone"}
_PHONE_MAX = 32

DESCRIPTION = (
    "Update one profile field the user stated or asked to change (preboarding "
    "or any time). One call per field. Refuses a birthdate under 18 (Ayma is "
    "18+ only)."
)

DECLARATION = {
    "name": "set_profile_field",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "field": {
                "type": "string",
                "enum": list(_FIELDS),
            },
            "value": {
                "type": "string",
                "description": _VALUE_HINT,
            },
        },
        "required": ["field", "value"],
    },
}


def _is_adult_birthdate(value: str) -> bool:
    """The 18+ floor for this Admin SDK write path (``firestore.rules`` never
    runs against it — see module docstring). Delegates to the one shared
    implementation so every write path judges age identically."""
    return age_gate.is_adult(value)


def _normalise(field: str, value: str):
    v = value.strip()
    if not v:
        return None
    if field == "gender":
        return v.title() if v.lower() in _GENDERS else None
    if field == "phone":
        plus = "+" if v.lstrip().startswith("+") else ""
        digits = "".join(c for c in v if c.isdigit())
        cleaned = (plus + digits)[:_PHONE_MAX]
        return cleaned or None
    if field == "interested_in":
        picks = [
            p.strip().title()
            for p in v.replace("and", ",").split(",")
            if p.strip().lower() in _INTERESTS
        ]
        return picks or None
    return v


def _bind(
    db, uid: str, *, session_id: str = "", turn_index: int = 0,
    turns: list | None = None,
) -> Callable[..., str]:
    def set_profile_field(field: str, value: str) -> str:
        """Update one of the person's own profile fields."""
        if field not in _FIELDS:
            return f"unknown field: {field}"
        if field == "birthdate":
            v = value.strip()
            try:
                datetime.date.fromisoformat(v)
            except (TypeError, ValueError):
                return f"could not use {value!r} for birthdate — use YYYY-MM-DD"
            if not _is_adult_birthdate(v):
                logger.warning("refused under-18 birthdate uid=%s", uid)
                return (
                    "can't set that birthdate — it would make them under 18, "
                    "and Ayma is 18+ only"
                )
            normalised = v
        else:
            normalised = _normalise(field, value)
        if normalised is None:
            return f"could not use {value!r} for {field}"

        from config import CONFIG

        if CONFIG.person_graph_reads:
            import person_graph_store as store
            from person_graph import Provenance

            _FIELD_TO_NODE = {
                "name": "legal_first_name",
                "first_name": "legal_first_name",
                "birthdate": "date_of_birth",
                "gender": "gender_identity",
                "interested_in": "target_match_genders",
                "location": "primary_location",
            }
            if field in _FIELD_TO_NODE:
                nid = _FIELD_TO_NODE[field]
                store.set_answer(
                    db, uid, nid, normalised,
                    provenance=Provenance.STATED,
                )
            elif field in ("last_name", "phone"):
                store.upsert_fact_node(
                    db, uid, f"emergent.profile.{field}", str(normalised),
                    section="identity", visibility="private",
                    provenance="stated", label=field.replace("_", " ").title(),
                )

            try:
                import completeness

                completeness.schedule(db, uid)
            except Exception:  # noqa: BLE001 - best-effort, never fail the write
                pass
            return f"set {field}"

        payload = {field: normalised, "updated_at": firestore.SERVER_TIMESTAMP}
        merge_paths = [field, "updated_at"]
        # Provenance (§ fact-source-of-truth, 2026-09-21): the verbatim user
        # message that prompted this write, so `find_fact_source` can later
        # answer "where did you get this from" with the user's own words
        # instead of a generic answer. `merge=[...]` (explicit field paths,
        # not a bare `merge=True`) so only *this* field's provenance entry is
        # touched — a bare `merge=True` would replace the whole nested
        # `provenance` map and silently wipe every other field's entry.
        quote = last_user_quote(turns)
        if quote:
            payload["provenance"] = {
                field: {
                    "source_type": "chat",
                    "quote": quote,
                    "session_id": session_id,
                    "turn_index": turn_index,
                    "at": firestore.SERVER_TIMESTAMP,
                }
            }
            merge_paths.append(f"provenance.{field}")
        (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
        ).set(payload, merge=merge_paths)
        # Graph-authoritative: a conversational edit to an L1 seed field must
        # update the seed NODE itself, not leave it stale (NOTE 233 defect 3).
        # `load_user` hydrates matching FROM the graph seed nodes and Your Story
        # renders them, so a profile/main-only write would leave the match score
        # and the About Me bullet on the old value. set_answer retires the prior
        # value to the node's Ayma-only history (the settled answer-history rule).
        try:
            from config import CONFIG

            if CONFIG.person_graph_reads:
                import person_graph_source
                import person_graph_store as pg_store

                seed = person_graph_source.seed_node_for_field(field)
                if seed is not None:
                    pg_store.set_answer(db, uid, seed, normalised)
        except Exception:  # noqa: BLE001 - best-effort, never fail the write
            logger.exception("set_profile_field: graph seed update failed for %s", uid)
        # A preboarding field can satisfy a questionnaire node (name, DOB,
        # gender, interested_in, location) — refresh the completeness score.
        try:
            import completeness

            completeness.schedule(db, uid)
        except Exception:  # noqa: BLE001 - best-effort, never fail the write
            pass
        return f"set {field}"

    return set_profile_field


SKILL = Skill(declaration=DECLARATION, bind=_bind)
