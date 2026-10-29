"""Wiki ingest pipeline (ARCHITECTURE.md §2.3, §2.8 step 3).

Fires after a chat turn is complete (`/chat`) and on `/post-turn`. Reads the
recent turn window plus the user's existing wiki pages, asks Gemini for the set
of page writes the conversation warrants, validates them against
`wiki_schema.json`, and upserts `users/{uid}/wiki_pages/{pageId}`.

Best-effort by design: any failure is logged and the turn is skipped — ingest
never blocks or fails the request it rides on.

Exempt from the credit gate (founder directive, 2026-09-20): capturing what
the user told Ayma is core product value and must not be lost or delayed just
because their credit balance hit zero. ``ingest()`` calls Gemini with
``enforce_cap=False`` — the real call still costs real tokens and is still
recorded via ``token_ledger.add``/``record`` exactly as for any other call
(this can legitimately push a user's ``used`` above their ``grant + added``;
the credit view already clamps ``remaining`` to 0 for that case). Only the
pre-call ``token_ledger.check`` block is skipped, and only for this call
site — chat, voice, matching, and every other feature still block on
``TokenCapExceeded`` exactly as before.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
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
        },
        # Named taste favourites the user stated — composed into the structured
        # public Taste page (Music:/Film:/Food:) the Qloo engine reads, NOT into
        # a narrative page. See the taste rule in prompts/wiki_ingest.md.
        "taste": {
            "type": "object",
            "properties": {
                "music": {"type": "array", "items": {"type": "string"}},
                "film": {"type": "array", "items": {"type": "string"}},
                "food": {"type": "array", "items": {"type": "string"}},
            },
        },
    },
    "required": ["pages"],
}

# The structured Taste page is owned by the deterministic taste-capture path
# (skills/questionnaire.py::_sync_taste_page, fed by the `taste` field above);
# a narrative `taste` page op from the model would overwrite it with prose the
# Qloo parser can't read, so those ops are dropped here.
_TASTE_PAGE_TYPE = "taste"


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
        block = (
            f"--- page_id: {p['page_id']} (type: {p.get('page_type', '?')}) ---\n"
            f"{p.get('ai_body', '').strip()}"
        )
        pinned = [str(x) for x in p.get("pinned") or [] if str(x).strip()]
        if pinned:
            block += "\npinned sentences:\n" + "\n".join(f"- {x}" for x in pinned)
        out.append(block)
    return "\n".join(out)


def _conversation_block(turns: list[Turn]) -> str:
    out = ["Recent conversation:"]
    for t in turns:
        who = "User" if t.role == ROLE_USER else "Ayma"
        text = t.text.strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)


# Provenance (§ fact-source-of-truth, 2026-09-21): a wiki page's `ai_body` is
# Gemini's own prose, synthesised from the conversation + the page's existing
# body — there's no reliable way to point at "the exact word" behind one
# sentence of it. What IS reliable, and cheap: whenever a page's `ai_body`
# actually changes, keep the verbatim conversation window that produced that
# change, so `find_fact_source` can later hand it to Ayma and let *her* judge
# whether it supports the specific fact the user is asking about — the same
# judgment call a human would make re-reading their own chat log. Bounded to
# the last _MAX_SOURCE_LOG entries per page so the doc never grows unbounded.
_MAX_SOURCE_LOG = 6
_MAX_EXCERPT_CHARS = 1200


def _conversation_excerpt(turns: list[Turn]) -> str:
    """Verbatim ``Speaker: text`` lines from ``turns`` (no header), tail-capped
    to ``_MAX_EXCERPT_CHARS`` — the most recent part of the window is the part
    most likely to explain a page write that just happened."""
    lines = []
    for t in turns:
        who = "User" if t.role == ROLE_USER else "Ayma"
        text = t.text.strip()
        if text:
            lines.append(f"{who}: {text}")
    excerpt = "\n".join(lines)
    return excerpt[-_MAX_EXCERPT_CHARS:]


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
                # The saved text, so Ayma's rewrite starts from what the
                # person approved or wrote rather than her own earlier draft.
                "ai_body": (data.get("user_edits") or "").strip()
                or data.get("ai_body", ""),
                "pinned": data.get("manual_pinned") or [],
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


def _write_page(
    db, uid: str, session_id: str, op: dict, *, source_excerpt: str = ""
) -> None:
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
    body_changed = False
    if not existing.exists:
        payload["created_at"] = firestore.SERVER_TIMESTAMP
        payload["ai_body_updated_at"] = firestore.SERVER_TIMESTAMP
        body_changed = True
        prior_log: list = []
    else:
        cur = existing.to_dict() or {}
        prior_log = list(cur.get("source_log") or [])
        # Stamp when the compiled body actually moves — the Your Story editor
        # uses this to flag "Ayma learned something since your last edit".
        if payload["ai_body"] != (cur.get("ai_body") or "").strip():
            payload["ai_body_updated_at"] = firestore.SERVER_TIMESTAMP
            body_changed = True
        # The user's own public/private choice (client edit path stamps
        # user_updated_at) wins over the model's pick on every later ingest —
        # otherwise re-ingest silently re-hides a page they chose to share.
        if cur.get("user_updated_at") and cur.get("visibility") in (
            "public",
            "private",
        ):
            payload["visibility"] = cur["visibility"]
    # Provenance (§ fact-source-of-truth, 2026-09-21): only log an entry when
    # the compiled body actually moved AND there's a real excerpt to keep —
    # a no-op rewrite or an excerpt-less caller (e.g. a future non-chat
    # ingest source) leaves the existing log untouched. Not a Firestore
    # array-transform sentinel (SERVER_TIMESTAMP can't live inside an array
    # element) — a plain UTC datetime instead, same as deep_dive.py's
    # disputed_facts timestamps.
    if body_changed and source_excerpt.strip():
        prior_log.append(
            {
                "at": datetime.now(timezone.utc),
                "session_id": session_id or "",
                "excerpt": source_excerpt.strip()[:_MAX_EXCERPT_CHARS],
            }
        )
        payload["source_log"] = prior_log[-_MAX_SOURCE_LOG:]
    # Hard, final override: `interactions`/`steering` are never user-visible
    # by default, regardless of the model's op or any user_updated_at
    # carry-forward above.
    if payload["page_type"] in _FORCE_AI_ONLY_PAGE_TYPES:
        payload["visibility"] = "ai_only"
    if existing.exists:
        # Never change the text visitors see without the user's approval.
        import profile_manual

        payload.update(
            profile_manual.route_ai_update(
                op["page_id"], existing.to_dict() or {}, payload
            )
        )
    doc.set(payload, merge=True)


async def ingest(
    db,
    uid: str,
    session_id: str,
    turns: list[Turn],
    force_visibility: str | None = None,
    record_source: bool = True,
) -> int:
    """Run one ingest pass. Returns the number of pages written.

    ``force_visibility`` overrides the model's choice on every page — used for
    DM-image / DM-voice derived content, which defaults to ``ai_only`` (§6.8).

    ``record_source=False`` skips writing the ``source_log`` provenance entry
    (see ``_write_page``) even when a page's body genuinely changes. This
    module's own docstring promises Gmail/Calendar content "never persisted
    verbatim to any Firestore doc" — more sensitive than a chat message, by
    design not even kept in ``raw_turns``. ``source_log`` would otherwise
    quietly reopen exactly that hole (it stores the verbatim ``turns`` text),
    so ``google_account.py`` passes ``record_source=False`` on its call,
    exactly like it already passes ``force_visibility="private"`` for the
    same reason. Every other caller keeps the default.
    """
    if not uid or not turns:
        return 0
    existing = _read_existing_pages(db, uid)
    existing_bodies = {
        p["page_id"]: (p.get("ai_body") or "").strip() for p in existing
    }
    # enforce_cap=False: wiki ingest is exempt from the credit gate (see the
    # module docstring) — the same escape hatch dm_moderation/persona_evolution/
    # completeness/deep_dive_images already use for Ayma-initiated work. This
    # only skips the pre-call TokenCapExceeded check; the call is still
    # metered via token_ledger.record below exactly as before.
    result = await gemini.generate_json(
        _build_contents(turns, existing),
        system_prompt=load_ingest_prompt(),
        response_schema=_RESPONSE_SCHEMA,
        uid=uid,
        feature="wiki",
        session_id=session_id,
        enforce_cap=False,
    )
    ops = (result or {}).get("pages", []) if isinstance(result, dict) else []
    excerpt = _conversation_excerpt(turns) if record_source else ""

    written = 0
    changed_pages: list[str] = []
    for op in ops:
        if force_visibility and force_visibility in visibility_values():
            op["visibility"] = force_visibility
        _force_ai_only_page_types(op)
        if not _valid_op(op):
            logger.warning("skipping invalid wiki op: %r", op)
            continue
        if op.get("page_type") == _TASTE_PAGE_TYPE:
            # Owned by the structured taste path — never a narrative overwrite.
            logger.debug("skipping narrative taste page op: %r", op.get("page_id"))
            continue
        _write_page(db, uid, session_id, op, source_excerpt=excerpt)
        written += 1
        if op["visibility"] != "ai_only" and (
            op["ai_body"].strip() != existing_bodies.get(op["page_id"], "")
        ):
            changed_pages.append(op["page_id"])

    # Named taste favourites the user stated go on the structured public Taste
    # page (Music:/Film:/Food:) the Qloo engine reads — never dumped into the
    # Interests story. Best-effort: a sync failure never breaks ingest, and it
    # only appends (dedup, cap 5) so it can't clobber a direct taste answer.
    taste = (result or {}).get("taste") if isinstance(result, dict) else None
    if isinstance(taste, dict) and any(
        isinstance(taste.get(d), list) and taste.get(d) for d in ("music", "film", "food")
    ):
        try:
            from skills import questionnaire as questionnaire_skill

            if questionnaire_skill.merge_taste_mentions(db, uid, taste):
                written += 1
        except Exception:  # noqa: BLE001 - best-effort; never break ingest
            logger.debug("taste-mention merge failed", exc_info=True)

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

    # Tell the user when this pass produced genuinely new public-profile
    # suggestions to review. Deduped (consume_new_suggestions) so an ingest
    # that changed nothing public — or re-ran over an unchanged pending set —
    # never re-pings. Best-effort: a notify failure must not break ingest.
    try:
        import profile_manual

        new_count = await asyncio.to_thread(
            profile_manual.consume_new_suggestions, db, uid
        )
        if new_count:
            from notifications_triggers import notify_profile_suggestions

            await notify_profile_suggestions(db, uid, new_count)
    except Exception:  # noqa: BLE001
        logger.debug("profile-suggestions notify hook failed", exc_info=True)

    # Persistent AI-avatar snapshot: this user's wiki/own-context just changed
    # (chat-turn ingest, voice session, Google sync, backfill), so flag their
    # standing avatar snapshot stale. Cheap, no LLM — the background sweep
    # rebuilds it at most once an hour and only if the source actually changed.
    if written:
        try:
            import persona_snapshot

            persona_snapshot.mark_persona_stale(db, uid)
        except Exception:  # noqa: BLE001 - the stale hook must never break ingest
            logger.debug("persona stale hook failed", exc_info=True)
    return written


async def ingest_or_defer(
    db,
    uid: str,
    session_id: str,
    turns: list[Turn],
    force_visibility: str | None = None,
) -> int:
    """Like :func:`ingest`, but on a *genuine* ingest failure flags the
    session for later re-ingest (§15's ``backfill_ops``) instead of the turns
    silently never reaching the wiki.

    History: this used to catch specifically :class:`token_ledger.
    TokenCapExceeded` and defer to the nightly backfill sweep when the user
    was out of credits mid-call. Founder directive (2026-09-20): "Instead of
    just marking them ingest pending I want even if the user run out of
    credits to save and invest [ingest] the data" — capturing what the user
    told Ayma is core product value and shouldn't be lost or delayed just
    because the credit balance hit zero. :func:`ingest` now calls Gemini with
    ``enforce_cap=False`` (see the module docstring), so it runs — and
    actually writes real wiki pages — even for a completely broke user; the
    call is still metered as normal, which can legitimately push their
    ``used`` above their ``grant + added`` (the credit view already handles
    that by clamping ``remaining`` to 0). ``TokenCapExceeded`` is therefore no
    longer a distinct case here.

    What's left for this ``except`` clause is a *real* failure — a Gemini API
    error, an unparseable response, a transient Firestore write blip — where
    the nightly sweep retrying later still has genuine value. Every caller
    that used to hand-roll this now gets the same safety net for real
    failures by going through this one function — notably the voice agent
    worker's own session-shutdown hook, which used to call :func:`ingest`
    nowhere at all and relied entirely on the client's later
    ``POST /post-turn`` (or an in-call ``remember`` tool call) to ever
    persist anything to the wiki. A room that closes abnormally — crashed,
    backgrounded, or dropped network, credits or no credits — never reaches
    that client call, so whatever the user said in the last stretch before
    disconnect (including a real, substantive answer to a questionnaire
    question) would otherwise be silently lost. Root-caused against a real
    conversation (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2, 2026-09-20) where the user
    answered the `past_relationship_narrative` questionnaire node right
    before credits ran out, Ayma acknowledged it in-session, and it never
    appeared in `wiki_pages/relationships` — the node came back as
    still-unanswered in the very next session as a result.
    """
    try:
        return await ingest(
            db, uid, session_id, turns, force_visibility=force_visibility
        )
    except Exception:  # noqa: BLE001 - genuine ingest failure; see docstring
        logger.exception(
            "ingest_or_defer: ingest failed for %s/%s, marking pending",
            uid, session_id,
        )
        try:
            import backfill_ops

            backfill_ops.mark_pending(db, uid, session_id)
        except Exception:  # noqa: BLE001
            logger.exception("ingest_or_defer: mark_pending failed for %s", uid)
        return 0
