"""``session_mode`` derivation (ARCHITECTURE.md §3.3, §3.10 step 2).

Derived server-side on every ``/bootstrap`` (and used by ``/chat``) from auth
state + ``profile`` completeness — never trusted from the client.

- ``active``     — the structured ``profile`` is fully filled.
- ``interview``  — onboarding is underway: a real credential is linked, or the
  client has flagged ``onboarding_started`` on ``users/{uid}`` ("get started"),
  or some profile fields are already set.
- ``marketing``  — an anonymous session that hasn't started onboarding.

The ``onboarding_started`` flag is the minimal "get started" transition signal;
§3.3's two named inputs (auth state, profile completeness) can't otherwise tell
a just-tapped-get-started anonymous user from a browsing one.
"""

from __future__ import annotations

MODE_MARKETING = "marketing"
MODE_INTERVIEW = "interview"
MODE_ACTIVE = "active"

# The structured fields that make a profile "fully filled" (§4.2).
_REQUIRED_PROFILE_FIELDS = (
    "name",
    "birthdate",
    "gender",
    "interested_in",
    "location",
)


# Human-readable labels for the interview-progress summary (below). Order is the
# order Ayma should ask in.
_FIELD_LABELS = (
    ("name", "name"),
    ("birthdate", "date of birth"),
    ("gender", "gender"),
    ("interested_in", "who they're interested in"),
    ("location", "where they live"),
)


def _is_blank(value) -> bool:
    return value in (None, "", [], {})


def describe_progress(profile: dict | None) -> str:
    """A 'here's what we already have' summary for the interview-mode system
    prompt, so Ayma never re-asks for a field that's already filled.

    Returns "" when nothing is captured yet (a fresh interview — the mode
    prompt's own list is enough)."""
    profile = profile or {}
    have: list[str] = []
    need: list[str] = []
    for field, label in _FIELD_LABELS:
        (need if _is_blank(profile.get(field)) else have).append(label)
    (have if profile.get("photos") else need).append("at least one photo")

    if not have:
        return ""
    lines = [
        "PREBOARDING PROGRESS — the on-screen form already has these; do NOT "
        "ask for them again, just confirm if it comes up naturally: "
        + ", ".join(have)
        + "."
    ]
    if need:
        lines.append(
            "Still to collect, one at a time: " + ", ".join(need) + "."
        )
    else:
        lines.append(
            "Nothing else is needed — don't ask more preboarding questions; "
            "let them move on."
        )
    return "\n".join(lines)


def profile_complete(profile: dict | None) -> bool:
    if not profile:
        return False
    for field in _REQUIRED_PROFILE_FIELDS:
        value = profile.get(field)
        if value in (None, "", [], {}):
            return False
    photos = profile.get("photos")
    return bool(photos)


def derive(
    *,
    is_anonymous: bool,
    profile: dict | None,
    onboarding_started: bool,
) -> str:
    if profile_complete(profile):
        return MODE_ACTIVE
    if (not is_anonymous) or onboarding_started or bool(profile):
        return MODE_INTERVIEW
    return MODE_MARKETING


def derive_for(db, uid: str, is_anonymous: bool) -> str:
    """Read the two Firestore inputs and derive the mode."""
    user_ref = db.collection("users").document(uid)
    user_snap = user_ref.get()
    onboarding_started = bool(
        (user_snap.to_dict() or {}).get("onboarding_started")
    ) if user_snap.exists else False

    profile_snap = user_ref.collection("profile").document("main").get()
    profile = profile_snap.to_dict() if profile_snap.exists else None

    return derive(
        is_anonymous=is_anonymous,
        profile=profile,
        onboarding_started=onboarding_started,
    )
