"""``submit_feedback`` — the in-app feedback catcher (F5 / founder request).

When the user, mid-chat, asks for a new feature or improvement, or reports
that something in the app is broken / not working, Ayma calls this to DRAFT a
feedback card the user reviews, edits and sends themselves. Calling the tool
does NOT file anything — it only populates the ``result`` sink
(``main._ChatCtx.feedback_draft``) that the ``/chat`` reply carries to the
client as ``feedback_card``, exactly the way ``edit_photo`` / ``generate_image``
deliver an image through their own sink. The client renders an editable
confirmation card; nothing reaches the ``feedback`` collection until the user
taps Send (``POST /feedback/submit``, ``source="chat_card"``).

Text-only (registered in ``skills._FEEDBACK_REGISTRY``, never ``_REGISTRY``):
a voice call has no surface to show or edit a confirmation card — the same
reason ``generate_image`` is text-only.

Distinct from the two sibling capture tools:

* ``record_feedback`` — about AYMA'S OWN conduct in the conversation; writes
  straight to the ``feedback`` bucket (``source="ayma"``), no card.
* ``report_bug`` — logs an app bug straight to ``bug_reports`` with no review
  step. ``submit_feedback`` supersedes it for the user-facing flow (confirm
  first, one unified ``feedback`` destination, feature requests too); the
  persona now steers bug/feature reports here.
"""

from __future__ import annotations

from typing import Callable

from ._base import Skill

DESCRIPTION = (
    "Draft a product-feedback card when the user asks for a NEW feature or "
    "improvement to the app, or reports that something in the app is broken "
    "or not working. Summarise their point into a crisp title and a one- or "
    "two-sentence body in their intent. This does NOT send anything: it shows "
    "the user a card to review, edit and send themselves. Keep chatting "
    "naturally otherwise. Do NOT use this for feedback about your own "
    "conversational conduct — that is `record_feedback`."
)

_KINDS = ("feature", "bug")
_TITLE_MAX = 120
_BODY_MAX = 4000

DECLARATION = {
    "name": "submit_feedback",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "kind": {
                "type": "string",
                "enum": list(_KINDS),
                "description": (
                    "`feature` for a request/improvement, `bug` for something "
                    "broken or not working"
                ),
            },
            "title": {
                "type": "string",
                "description": "a short headline for the request (<= 80 chars)",
            },
            "body": {
                "type": "string",
                "description": (
                    "one or two sentences describing the request / bug, "
                    "capturing the user's intent"
                ),
            },
        },
        "required": ["kind", "title", "body"],
    },
}


def _bind(db, uid: str, *, result: dict | None = None) -> Callable[..., str]:
    def submit_feedback(kind: str, title: str, body: str) -> str:
        """Populate the draft sink the chat reply reads back as
        ``feedback_card``. Never writes to Firestore — the user confirms."""
        k = kind if kind in _KINDS else "feature"
        t = (title or "").strip()[:_TITLE_MAX]
        b = (body or "").strip()[:_BODY_MAX]
        if not t and not b:
            return "nothing to draft — ask the user what they'd like to report"
        if result is not None:
            result.clear()
            result.update({"kind": k, "title": t, "body": b})
        return (
            "drafted a feedback card for them — tell the user it's ready to "
            "review, edit a screenshot onto, and send, and that nothing is "
            "filed until they tap Send"
        )

    return submit_feedback


SKILL = Skill(declaration=DECLARATION, bind=_bind)
