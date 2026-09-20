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
import token_ledger
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


# Page types that must never be user-visible by default, regardless of what
# the model requests: `interactions` is Ayma's own behavioural inference
# about the user (not something they stated or asked for), and `steering` is
# a standing instruction *about* the user, not a fact of theirs (founder
# call, 2026-09-13 — same treatment as `interactions`). `sensitive` stays
# model-directed `private` — that page's content is the user's own stated
# material, just not part of the shareable profile.
_FORCE_AI_ONLY_PAGE_TYPES = frozenset({"interactions", "steering"})


def _force_ai_only_page_types(op: dict) -> None:
    """The prompt already asks the model for `ai_only` on these page types,
    but this is enforced here too, unconditionally, so a misbehaving model
    response can never leak one into Story/Public view."""
    if isinstance(op, dict) and op.get("page_type") in _FORCE_AI_ONLY_PAGE_TYPES:
        op["visibility"] = "ai_only"


def _valid_op(op: dict) -> bool:
    # Any type in wiki_schema.json is model-writable through the same path —
    # including `interactions` and `steering` (forced to `ai_only`
    # server-side, see `_force_ai_only_page_types`). Every visibility tier
    # feeds read_wiki_context (unfiltered); only `ai_only` never reaches a
    # client.
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
        payload["ai_body_updated_at"] = firestore.SERVER_TIMESTAMP
    else:
        cur = existing.to_dict() or {}
        # Stamp when the compiled body actually moves — the Your Story editor
        # uses this to flag "Ayma learned something since your last edit".
        if payload["ai_body"] != (cur.get("ai_body") or "").strip():
            payload["ai_body_updated_at"] = firestore.SERVER_TIMESTAMP
        # The user's own public/private choice (client edit path stamps
        # user_updated_at) wins over the model's pick on every later ingest —
        # otherwise re-ingest silently re-hides a page they chose to share.
        if cur.get("user_updated_at") and cur.get("visibility") in (
            "public",
            "private",
        ):
            payload["visibility"] = cur["visibility"]
    # Hard, final override: `interactions`/`steering` are never user-visible
    # by default, regardless of the model's op or any user_updated_at
    # carry-forward above.
    if payload["page_type"] in _FORCE_AI_ONLY_PAGE_TYPES:
        payload["visibility"] = "ai_only"
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
    existing_bodies = {
        p["page_id"]: (p.get("ai_body") or "").strip() for p in existing
    }
    result = await gemini.generate_json(
        _build_contents(turns, existing),
        system_prompt=load_ingest_prompt(),
        response_schema=_RESPONSE_SCHEMA,
        uid=uid,
        feature="wiki",
    )
    ops = (result or {}).get("pages", []) if isinstance(result, dict) else []

    written = 0
    changed_pages: list[str] = []
    for op in ops:
        if force_visibility and force_visibility in visibility_values():
            op["visibility"] = force_visibility
        _force_ai_only_page_types(op)
        if not _valid_op(op):
            logger.warning("skipping invalid wiki op: %r", op)
            continue
        _write_page(db, uid, session_id, op)
        written += 1
        if op["visibility"] != "ai_only" and (
            op["ai_body"].strip() != existing_bodies.get(op["page_id"], "")
        ):
            changed_pages.append(op["page_id"])

    if changed_pages:
        # Commit a per-section version for each section whose compiled body
        # moved (the Your Story editor's per-file history). Best-effort:
        # maybe_snapshot_section_after_ai swallows its own errors, and this
        # guard makes doubly sure ingest never breaks on it.
        try:
            import story

            for page_id in changed_pages:
                story.maybe_snapshot_section_after_ai(db, uid, page_id)
        except Exception:  # noqa: BLE001
            logger.debug("story snapshot hook failed", exc_info=True)
    return written


async def ingest_or_defer(
    db,
    uid: str,
    session_id: str,
    turns: list[Turn],
    force_visibility: str | None = None,
) -> int:
    """Like :func:`ingest`, but when the user is out of credits mid-call,
    flags the session for later re-ingest (§15's ``backfill_ops``) instead of
    the turns silently never reaching the wiki.

    Every caller that has its own retry loop already does this by hand
    (``main._run_ingest`` catches :class:`token_ledger.TokenCapExceeded` and
    calls ``backfill_ops.mark_pending``). This is for callers that don't —
    notably the voice agent worker's own session-shutdown hook, which used to
    call :func:`ingest` nowhere at all and relied entirely on the client's
    later ``POST /post-turn`` (or an in-call ``remember`` tool call) to ever
    persist anything to the wiki. A room that closes because the user ran out
    of credits mid-session — or crashed, backgrounded, or dropped network —
    never reaches that client call, so whatever the user said in the last
    stretch before disconnect (including a real, substantive answer to a
    questionnaire question) was silently lost: never written to the wiki, and
    never even flagged ``ingest_pending`` so the nightly backfill sweep could
    catch it either. Root-caused against a real conversation (uid
    iWhWjiWhEpU7iyu9B9vy7GlT0PD2, 2026-09-20) where the user answered the
    `past_relationship_narrative` questionnaire node right before credits ran
    out, Ayma acknowledged it in-session, and it never appeared in
    `wiki_pages/relationships` — the node came back as still-unanswered in
    the very next session as a result.
    """
    try:
        return await ingest(
            db, uid, session_id, turns, force_visibility=force_visibility
        )
    except token_ledger.TokenCapExceeded:
        try:
            import backfill_ops

            backfill_ops.mark_pending(db, uid, session_id)
        except Exception:  # noqa: BLE001
            logger.exception("ingest_or_defer: mark_pending failed for %s", uid)
        return 0
