"""Wiki ingest pipeline (ARCHITECTURE.md §2.3, §2.8 step 3).

Fires after a chat turn is complete (`/chat`) and on `/post-turn`. Reads the
recent turn window plus the user's existing wiki pages, asks Gemini for the set
of page writes the conversation warrants, validates them against
`wiki_schema.json`, and upserts `users/{uid}/wiki_pages/{pageId}`.

Best-effort by design: any failure is logged and the turn is skipped — ingest
never blocks or fails the request it rides on.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

from firebase_admin import firestore

import gemini
from transcript import ROLE_USER, Turn
from wiki_schema import (
    is_valid_page_id,
    load_wiki_schema,
    page_types,
    visibility_values,
)

logger = logging.getLogger("ayma.wiki")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "wiki_ingest.md"

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "pages": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "page_id": {"type": "string"},
                    "page_type": {"type": "string"},
                    "visibility": {"type": "string"},
                    "ai_body": {"type": "string"},
                    "links": {"type": "array", "items": {"type": "string"}},
                    "frontmatter": {"type": "object"},
                },
                "required": ["page_id", "page_type", "visibility", "ai_body"],
            },
        }
    },
    "required": ["pages"],
}


@lru_cache(maxsize=1)
def load_ingest_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _page_types_block() -> str:
    lines = ["Page types (type — default visibility — what it covers):"]
    for pt in load_wiki_schema()["page_types"]:
        lines.append(
            f"- {pt['type']} — {pt['default_visibility']} — {pt['description']}"
        )
    return "\n".join(lines)


def _existing_pages_block(pages: list[dict]) -> str:
    if not pages:
        return "Existing wiki pages: (none yet)"
    out = ["Existing wiki pages:"]
    for p in pages:
        out.append(
            f"--- page_id: {p['page_id']} (type: {p.get('page_type', '?')}) ---\n"
            f"{p.get('ai_body', '').strip()}"
        )
    return "\n".join(out)


def _conversation_block(turns: list[Turn]) -> str:
    out = ["Recent conversation:"]
    for t in turns:
        who = "User" if t.role == ROLE_USER else "Ayma"
        text = t.text.strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)


def _build_contents(turns: list[Turn], existing: list[dict]) -> str:
    return "\n\n".join(
        [
            _page_types_block(),
            _existing_pages_block(existing),
            _conversation_block(turns),
        ]
    )


def _read_existing_pages(db, uid: str) -> list[dict]:
    col = (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
    )
    pages = []
    for snap in col.stream():
        data = snap.to_dict() or {}
        pages.append(
            {
                "page_id": snap.id,
                "page_type": data.get("page_type"),
                "ai_body": data.get("ai_body", ""),
            }
        )
    return pages


def _valid_op(op: dict) -> bool:
    return (
        isinstance(op, dict)
        and is_valid_page_id(str(op.get("page_id", "")))
        and op.get("page_type") in page_types()
        and op.get("visibility") in visibility_values()
        and isinstance(op.get("ai_body"), str)
        and op["ai_body"].strip() != ""
    )


def _write_page(db, uid: str, session_id: str, op: dict) -> None:
    doc = (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(op["page_id"])
    )
    existing = doc.get()
    payload = {
        "ai_body": op["ai_body"].strip(),
        "visibility": op["visibility"],
        "page_type": op["page_type"],
        "links": [str(x) for x in op.get("links", []) if str(x).strip()],
        "frontmatter": op.get("frontmatter") or {},
        "updated_at": firestore.SERVER_TIMESTAMP,
    }
    if session_id:
        payload["source_turn_ids"] = firestore.ArrayUnion([session_id])
    if not existing.exists:
        payload["created_at"] = firestore.SERVER_TIMESTAMP
    else:
        cur = existing.to_dict() or {}
        # The user's own public/private choice (client edit path stamps
        # user_updated_at) wins over the model's pick on every later ingest —
        # otherwise re-ingest silently re-hides a page they chose to share.
        if cur.get("user_updated_at") and cur.get("visibility") in (
            "public",
            "private",
        ):
            payload["visibility"] = cur["visibility"]
    doc.set(payload, merge=True)


async def ingest(
    db,
    uid: str,
    session_id: str,
    turns: list[Turn],
    force_visibility: str | None = None,
) -> int:
    """Run one ingest pass. Returns the number of pages written.

    ``force_visibility`` overrides the model's choice on every page — used for
    DM-image / DM-voice derived content, which defaults to ``ai_only`` (§6.8).
    """
    if not uid or not turns:
        return 0
    existing = _read_existing_pages(db, uid)
    result = await gemini.generate_json(
        _build_contents(turns, existing),
        system_prompt=load_ingest_prompt(),
        response_schema=_RESPONSE_SCHEMA,
        uid=uid,
        feature="wiki",
    )
    ops = (result or {}).get("pages", []) if isinstance(result, dict) else []

    written = 0
    for op in ops:
        if force_visibility and force_visibility in visibility_values():
            op["visibility"] = force_visibility
        if not _valid_op(op):
            logger.warning("skipping invalid wiki op: %r", op)
            continue
        _write_page(db, uid, session_id, op)
        written += 1
    return written
