"""Contact-info and safety moderation for public profile text.

Tier-2 sweep monolith split #12: the ``--- moderation ---`` section of the
former ``profile_manual.py`` monolith, moved verbatim — no behavior change.
"""

from __future__ import annotations

import logging

import gemini
import token_ledger
from profile_manual_common import (
    ProfileTextError,
    _EMAIL,
    _MIN_PHONE_DIGITS,
    _MODERATION_SCHEMA,
    _PHONE,
    _URL,
    _prompt,
)

logger = logging.getLogger("ayma.profile_manual")


def check_contact_info(text: str) -> None:
    """Reject obvious email addresses and phone numbers. Links are allowed."""
    plain = _URL.sub(" ", text)
    if _EMAIL.search(plain):
        raise ProfileTextError(
            "contact_info", "Email addresses can't go on your public profile."
        )
    for m in _PHONE.finditer(plain):
        if sum(c.isdigit() for c in m.group()) >= _MIN_PHONE_DIGITS:
            raise ProfileTextError(
                "contact_info", "Phone numbers can't go on your public profile."
            )


async def _moderate(uid: str, added_text: str) -> None:
    try:
        result = await gemini.generate_json(
            added_text,
            system_prompt=_prompt("profile_text_moderation.md"),
            response_schema=_MODERATION_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_PROFILE_MANUAL,
            enforce_cap=False,
        )
    except Exception as exc:  # noqa: BLE001 - public text fails closed
        logger.exception("profile text moderation failed for %s", uid)
        raise ProfileTextError(
            "moderation_unavailable",
            "Couldn't check your text just now. Please try again.",
        ) from exc
    if isinstance(result, dict) and result.get("flagged") is True:
        reason = str(result.get("reason") or "").strip()
        raise ProfileTextError(
            "moderation",
            reason or "That text isn't allowed on a public profile.",
        )
