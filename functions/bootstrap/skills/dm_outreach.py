"""``propose_dm_message`` / ``send_dm_message`` — Ayma composing, and only on
the user's explicit confirmation, actually sending a direct message to
another real person on the user's behalf (founder scope-expansion request,
2026-09-16: "...even to open a message with a person from Explore and
sending them a message as the user says").

This is categorically riskier than any other tool in the registry: it
delivers something to a THIRD PARTY, irreversibly, with no undo — unlike
``set_profile_field`` or the profile-edit tools, which only ever touch the
user's own data. So it is built as an explicit two-step confirm, never a
one-shot compose-and-send:

1. ``propose_dm_message`` resolves who the user means (against the same
   Explore roster ``/explore`` itself lists — see ``explore.explore``, which
   already excludes blocked/paused people), drafts the message text, and
   returns it as **plain text only**. It has no side effect visible to the
   recipient or anyone else — no DM thread message is created, nothing is
   sent. The only thing it writes is a short-lived "pending draft" note
   under the *sender's own* session doc
   (``users/{uid}/sessions/{id}.pending_dm``), which only this same
   conversation can ever act on.
2. ``send_dm_message`` is the ONLY function in this pair that can reach
   ``dm_ops.post_message``. It never accepts new message text from the model
   — it re-sends exactly the draft ``propose_dm_message`` stored, so a model
   can never compose-and-send in a single call, and what actually gets
   delivered can never drift from what the user saw and agreed to. It
   refuses when there's no matching pending draft (nothing was proposed this
   conversation) or the draft has gone stale (``_DRAFT_TTL_SECONDS``).

No other tool in this codebase already does a two-step confirm (checked
``skills/`` broadly before building this), so this is a fresh, minimal
pattern: a same-conversation "pending draft" doc is the simplest thing that
(a) can't be satisfied by a single tool call and (b) doesn't require any new
cross-request session machinery beyond what ``remember`` (§13.6) already
uses for its own per-session doc.

Moderation: a message Ayma sends here is a real DM from the user's own
account, so it goes through the exact same ``dm_moderation.moderate`` /
``dm_ops.post_message`` path ``/dm/{thread_id}/messages`` already uses for
user-typed DMs — flag but always deliver, never block (see
``dm_moderation.py``). No separate policy for Ayma-authored text.
"""

from __future__ import annotations

import datetime
from typing import Callable

from firebase_admin import firestore

import dm_moderation
import dm_ops
import explore

from ._base import Skill

# How long a proposed-but-unconfirmed draft stays sendable. Generous enough to
# cover a natural back-and-forth ("send it" a minute later), short enough that
# a much later, unrelated "yes" in the same long-running voice/chat session
# can't accidentally fire off a stale draft.
_DRAFT_TTL_SECONDS = 30 * 60

DESCRIPTION_PROPOSE = (
    "Draft a direct message to send to a specific person on the user's behalf "
    "— someone from Explore, a match, anyone they name — based on what they "
    "asked for ('send Jordan a hi and ask about their trip'). This does NOT "
    "send anything. It only composes the text and says it back so the user "
    "can approve, edit, or cancel. Always say the draft back to them and wait "
    "for an explicit yes before ever calling `send_dm_message`."
)

DECLARATION_PROPOSE = {
    "name": "propose_dm_message",
    "description": DESCRIPTION_PROPOSE,
    "parameters": {
        "type": "object",
        "properties": {
            "person": {
                "type": "string",
                "description": "who to message, as the user refers to them",
            },
            "message": {
                "type": "string",
                "description": (
                    "the message text to propose, in your own words, based "
                    "on what the user asked for"
                ),
            },
        },
        "required": ["person", "message"],
    },
}

DESCRIPTION_SEND = (
    "Actually deliver the message drafted moments ago with "
    "`propose_dm_message`, after — and only after — the user explicitly "
    "confirms in a later turn ('yes', 'send it', 'go ahead'). Never call this "
    "in the same turn you drafted the message, never call it on a guess, and "
    "never pass new message text — it always sends exactly what was already "
    "proposed and shown to the user."
)

DECLARATION_SEND = {
    "name": "send_dm_message",
    "description": DESCRIPTION_SEND,
    "parameters": {
        "type": "object",
        "properties": {
            "person": {
                "type": "string",
                "description": (
                    "optional — who you're confirming the send is for, if it "
                    "helps disambiguate"
                ),
            },
        },
    },
}


def _session_doc(db, uid: str, session_id: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("sessions")
        .document(session_id or "_adhoc")
    )


def _resolve_target(db, uid: str, person: str) -> tuple[str, str] | None:
    """Find the uid + display name for ``person`` among everyone this user can
    reach through Explore (§6.2) — the same roster ``/explore`` shows, which
    already excludes people who are blocked (either direction) or paused.
    Best-effort exact/first-name/substring match, mirroring
    ``read_dm_thread._resolve_other_uid``'s scoring."""
    want = person.strip().lower()
    if not want:
        return None
    try:
        # No filters, a large cap — resolving a *named* person must see the
        # whole reachable roster, not just Explore's default top-30 page.
        cards = explore.explore(db, uid, {}, limit=10_000)
    except Exception:  # noqa: BLE001 - a lookup failure just means "not found"
        return None

    best: tuple[int, str, str] | None = None  # (strength, uid, name)
    for card in cards:
        if card.get("self"):
            continue
        name = str(card.get("name") or "").strip().lower()
        if not name:
            continue
        first = name.split(" ")[0]
        strength = 0
        if name == want:
            strength = 3
        elif first == want:
            strength = 2
        elif want in name or name in want:
            strength = 1
        if strength and (best is None or strength > best[0]):
            best = (strength, str(card["uid"]), str(card.get("name") or person))
    return (best[1], best[2]) if best else None


def _is_stale(proposed_at) -> bool:
    """``True`` only when we can positively tell the draft is older than
    ``_DRAFT_TTL_SECONDS``. An unresolved/unfamiliar timestamp shape (e.g. a
    fake/test double, or a sentinel that hasn't round-tripped through a real
    Firestore read yet) never blocks the send on its own."""
    if proposed_at is None:
        return True
    try:
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        return (now - proposed_at.timestamp()) > _DRAFT_TTL_SECONDS
    except Exception:  # noqa: BLE001
        return False


def _bind_propose(db, uid: str, *, session_id: str = "") -> Callable[..., str]:
    def propose_dm_message(person: str, message: str) -> str:
        """Compose a draft DM and say it back — never sends anything."""
        target = _resolve_target(db, uid, person)
        if not target:
            return (
                f"I couldn't find anyone named '{person}' to message — check "
                "the name."
            )
        other_uid, other_name = target
        body = message.strip()
        if not body:
            return "what would you like to say to them?"

        # The only write here: a same-user, same-conversation "what I just
        # proposed" note. Nothing reaches the recipient or their thread.
        _session_doc(db, uid, session_id).set(
            {
                "pending_dm": {
                    "other_uid": other_uid,
                    "other_name": other_name,
                    "body": body,
                    "proposed_at": firestore.SERVER_TIMESTAMP,
                }
            },
            merge=True,
        )
        return f'I\'ll send {other_name}: "{body}" — want me to send that?'

    return propose_dm_message


def _bind_send(db, uid: str, *, session_id: str = "") -> Callable[..., str]:
    async def send_dm_message(person: str = "") -> str:
        """Deliver the pending draft exactly as proposed. Refuses if nothing
        was proposed this conversation, or the draft has gone stale."""
        sess = _session_doc(db, uid, session_id)
        snap = sess.get()
        draft = (snap.to_dict() or {}).get("pending_dm") if snap.exists else None
        if not draft or not draft.get("other_uid") or not draft.get("body"):
            return (
                "there's nothing drafted to send yet — ask me to draft a "
                "message first, then confirm it"
            )
        if _is_stale(draft.get("proposed_at")):
            return "that draft's gone stale — ask me to draft it again before sending"

        other_name = str(draft.get("other_name") or "them")
        if person.strip():
            want = person.strip().lower()
            have = other_name.lower()
            first = have.split(" ")[0] if have else ""
            if want not in (have, first) and want not in have and have not in want:
                return (
                    f"that draft was for {other_name}, not {person} — ask me "
                    f"to draft a message to {person} first"
                )

        other_uid = str(draft["other_uid"])
        body = str(draft["body"])
        moderation = await dm_moderation.moderate(body)

        try:
            dm_ops.post_message(db, uid, other_uid, "text", body, None, moderation)
        except PermissionError:
            sess.set({"pending_dm": firestore.DELETE_FIELD}, merge=True)
            return f"couldn't send — you and {other_name} can't message each other"
        except ValueError as exc:
            return f"couldn't send: {exc}"
        except Exception:  # noqa: BLE001 - never crash the turn on a send failure
            return "something went wrong sending that — try again in a moment"

        sess.set({"pending_dm": firestore.DELETE_FIELD}, merge=True)
        return f'sent to {other_name}: "{body}"'

    return send_dm_message


PROPOSE_SKILL = Skill(declaration=DECLARATION_PROPOSE, bind=_bind_propose)
SEND_SKILL = Skill(declaration=DECLARATION_SEND, bind=_bind_send)
SKILLS = [PROPOSE_SKILL, SEND_SKILL]
