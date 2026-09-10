"""``set_profile_field`` — during voice-driven preboarding (§3.3, §4.2, Step 31)
Ayma calls this once per answer to autofill that screen's field. It writes the
structured ``users/{uid}/profile/main`` doc only; the client keeps every field
editable before the user confirms.
"""

from __future__ import annotations

from typing import Callable

from firebase_admin import firestore

from ._base import Skill

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
    "Autofill one preboarding profile field from what the person just told you. "
    "Call it once per answer, only during preboarding, using their own words."
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
        """Autofill one preboarding profile field."""
        if field not in _FIELDS:
            return f"unknown field: {field}"
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
