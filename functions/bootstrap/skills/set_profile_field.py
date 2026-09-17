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
from typing import Callable

from firebase_admin import firestore

from ._base import Skill

_MIN_AGE_YEARS = 18

_FIELDS = {
    "name": "the person's first name / what to call them",
    "first_name": "their real given name (used to look them up online)",
    "last_name": "their real family name (used to look them up online)",
    "phone": "their phone number, digits and an optional leading +",
    "birthdate": "date of birth as YYYY-MM-DD",
    "gender": "one of: Woman, Man, Non-binary, Other",
    "interested_in": "comma-separated, from: Women, Men, Everyone",
    "location": 'their city, e.g. "Lisbon, Portugal"',
}
_GENDERS = {"woman", "man", "non-binary", "other"}
_INTERESTS = {"women", "men", "everyone"}
_PHONE_MAX = 32

DESCRIPTION = (
    "Update one of the person's own identity/profile fields from what they just "
    "told you, in their own words — during preboarding to autofill that screen's "
    "field, or any time later in an ongoing chat/voice call when a returning "
    "user asks to change something ('change my name to Sam', 'update my phone "
    "number', 'my birthday is actually March 3rd'). One call per field. Refuses "
    "a birthdate that would make them under 18 — Ayma is 18+ only."
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
                "description": "which field",
            },
            "value": {
                "type": "string",
                "description": "; ".join(f"{k}: {v}" for k, v in _FIELDS.items()),
            },
        },
        "required": ["field", "value"],
    },
}


def _is_adult_birthdate(value: str) -> bool:
    """Mirrors ``firestore.rules``' ``isAdultBirthdate()`` exactly (same
    year-minus-year-minus-hasnt-had-birthday-yet arithmetic, against today's
    UTC date). That rule never runs against this Admin SDK write (see module
    docstring) — this is the only enforcement of the 18+ floor on this path,
    so it must never be dropped or weakened without an equivalent replacement.
    """
    try:
        bd = datetime.date.fromisoformat(value)
    except (TypeError, ValueError):
        return False
    today = datetime.datetime.now(datetime.timezone.utc).date()
    had_birthday_this_year = (today.month, today.day) >= (bd.month, bd.day)
    age = today.year - bd.year - (0 if had_birthday_this_year else 1)
    return age >= _MIN_AGE_YEARS


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


def _bind(db, uid: str) -> Callable[..., str]:
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
                return (
                    "can't set that birthdate — it would make them under 18, "
                    "and Ayma is 18+ only"
                )
            normalised = v
        else:
            normalised = _normalise(field, value)
        if normalised is None:
            return f"could not use {value!r} for {field}"
        (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
        ).set(
            {field: normalised, "updated_at": firestore.SERVER_TIMESTAMP},
            merge=True,
        )
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
