"""Passage chat: shaping one Story section by chatting about a highlight.

Tier-2 sweep monolith split #12: the ``--- passage chat ---`` section of the
former ``story.py`` monolith (the chat turn itself; the file's trailing
``remove_section`` / ``revert_section`` / ``maybe_snapshot_section_after_ai``
are writes and live in :mod:`story_writes`), moved verbatim — no behavior
change.
"""

from __future__ import annotations

import logging

import gemini
import token_ledger
from story_common import F_VISIBILITY, VIS_PRIVATE, VIS_PUBLIC
from story_pages import _display_body
from story_spans import apply_span_action
from story_writes import _require_page

logger = logging.getLogger("ayma.story")

_CHAT_SYS = (
    "You help someone shape one section of their personal dating-profile story "
    "by chatting about a highlighted passage. You have the full section body "
    "and the passage they highlighted. Answer their message in one or two "
    "sentences (`reply`), then pick ONE action:\n"
    "- Just talking / still figuring it out -> action \"chat\".\n"
    "- They want to make ONLY the highlighted passage private, public, or "
    "deleted -> action \"span\" with `span_action` = private|public|delete. "
    "Do NOT write `revised_body` for this; the app applies it to exactly the "
    "highlighted text.\n"
    "- They want to reword the highlighted passage (or the section) -> action "
    "\"chat\" and return `revised_body`: the ENTIRE section body with the "
    "wording change applied, everything else byte-for-byte. Use "
    "{{private}}…{{/private}} only if they also asked for that.\n"
    "- They want the WHOLE section made private or public -> action \"move\" "
    "with `target_visibility`. Only when they clearly mean the whole section, "
    "not the passage.\n"
    "- They want the WHOLE section deleted -> action \"remove\".\n"
    "When unsure whether they mean the passage or the section, assume the "
    "passage (\"span\")."
)
_CHAT_SCHEMA = {
    "type": "object",
    "properties": {
        "reply": {"type": "string"},
        "revised_body": {"type": "string"},
        "action": {
            "type": "string",
            "enum": ["chat", "span", "move", "remove"],
        },
        "span_action": {
            "type": "string",
            "enum": ["private", "public", "delete"],
        },
        "target_visibility": {"type": "string", "enum": ["public", "private"]},
    },
    "required": ["reply"],
}


def _chat_contents(body: str, selection: str, messages: list[dict]) -> str:
    thread = "\n".join(
        f"{'Them' if str(m.get('role')) == 'user' else 'You'}: "
        f"{str(m.get('text', '')).strip()}"
        for m in messages
        if str(m.get("text", "")).strip()
    )
    return (
        f"Full section body:\n{body}\n\n"
        f"Highlighted passage:\n{selection.strip() or '(none)'}\n\n"
        f"Conversation so far:\n{thread or '(just opened)'}"
    )


async def edit_section(
    db, uid: str, page_id: str, selection: str, messages: list[dict]
) -> dict:
    """One turn of the passage chat. Returns ``{reply, revised_body, action,
    target_visibility}`` — ``revised_body`` set only when Ayma proposes a
    concrete rewrite. Writes nothing."""
    _ref, data = _require_page(db, uid, page_id)
    body = _display_body(db, uid, page_id, data)
    try:
        result = await gemini.generate_json(
            _chat_contents(body, selection, messages or []),
            system_prompt=_CHAT_SYS,
            response_schema=_CHAT_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_WIKI,
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    result = result if isinstance(result, dict) else {}
    action = str(result.get("action") or "chat").strip().lower()
    if action not in ("chat", "span", "move", "remove"):
        action = "chat"
    sel = (selection or "").strip()
    span_action = str(result.get("span_action") or "").strip().lower()

    # Safety net: the model likes to call a passage-level privacy change a whole
    # -section "move". If they highlighted a passage that's a real substring of
    # the body (not ~the whole thing), treat it as a span op on that passage.
    if (
        action == "move"
        and sel
        and sel in body
        and len(sel) < len(body) * 0.9
    ):
        action = "span"
        tv = str(result.get("target_visibility") or "").strip().lower()
        span_action = tv if tv in ("public", "private") else "private"

    out: dict = {
        "reply": str(result.get("reply") or "").strip(),
        "revised_body": str(result.get("revised_body") or "").strip(),
        "action": action,
    }

    if action == "span":
        if span_action not in ("private", "public", "delete") or not sel:
            # Nothing actionable — fall back to a plain chat turn.
            out["action"] = "chat"
        else:
            # Deterministic: only the highlighted passage changes, markers stay
            # well-formed. Never trust the model's own body here.
            out["span_action"] = span_action
            out["revised_body"] = apply_span_action(body, sel, span_action)
    elif action == "move":
        cur = data.get(F_VISIBILITY) or VIS_PRIVATE
        target = str(result.get("target_visibility") or "").strip().lower()
        out["target_visibility"] = (
            target
            if target in (VIS_PUBLIC, VIS_PRIVATE)
            else (VIS_PRIVATE if cur == VIS_PUBLIC else VIS_PUBLIC)
        )
    return out
