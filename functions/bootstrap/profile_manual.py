"""Manual editing of the user's public profile text, and the approve-before-
apply flow for Ayma's later updates to it.

The public profile is the set of ``public`` wiki pages (see
:mod:`public_profile`). The manual editor shows them as one plain text — each
section under a ``## Title`` heading — and :func:`save_text` turns an edit of
that text into per-section ``user_edits`` overrides:

* A sentence-level diff (before vs after) is classified by a model call
  (``prompts/profile_diff_classify.md``) into removed facts, added facts and
  wording-only changes.
* Removed facts are never lost: each is kept as an inline ``{{ai_only}}`` span
  in the section body, which is exactly how "Ayma's notes" already holds
  passages removed from the profile (the page's ``ai_body`` memory is not
  touched either). Users cannot delete individual notes.
* Added facts are written into the page's ``manual_pinned`` list (user-stated;
  Ayma must keep them) and appended to ``ai_body`` so Ayma knows them.
* Wording-only changes touch neither.
* The text the user wrote becomes the public text.

A ``## Title`` heading that matches none of the profile's sections becomes a
custom section of the user's own: a ``misc`` wiki page, public, whose
``title`` field carries the user's title (see :func:`_plan_sections`).
Removing it later follows the same removed-content rule as any section.

New text is moderated like any other user-facing text: a length cap, no phone
numbers or email addresses (links are allowed), and a model safety pass
(``prompts/profile_text_moderation.md``).

Later AI updates to a public page's text are never applied silently:
:func:`route_ai_update` (called by ``wiki_ingest``) freezes the current public
text as the page's ``user_edits`` and stores the AI's rewrite as a
``pending_proposal`` on the page. The user then reviews it **one change at a
time**: the sentence diff is split into per-change rows with stable ids
(:func:`list_proposals`), and each added or removed sentence is applied
(:func:`apply_change`) or dismissed (:func:`dismiss_change`) on its own; the
decisions so far are kept in the proposal's ``decided`` map until every change
is resolved, when the proposal is cleared. :func:`apply_proposal` /
:func:`dismiss_proposal` decide the whole section at once (Apply all / Dismiss
all).

Applying a change shows it on the **public** profile; dismissing it never
discards anything. A dismissed addition — and any sentence removed from the
public text — is kept as an inline ``{{ai_only}}`` span and in the page's
``ai_body``, which is exactly how "Ayma's notes" holds material that is off
the public profile: ``story.get_ai_notes`` still shows it and Ayma's
matching/chat read path (``wiki_query.read_wiki_context``) reads every page's
``ai_body`` unfiltered, so Ayma keeps knowing it. Pinned sentences and
``ai_only`` spans are re-attached on every rebuild, so a decision can never
drop them. Everything lives on the ``wiki_pages`` docs, so account deletion
and the knowledge wipe already cover it.
"""

from __future__ import annotations

import asyncio
import difflib
import hashlib
import logging
import re
import unicodedata
from datetime import datetime, timezone
from pathlib import Path

import gemini
import report_blocks as rb
import story
import token_ledger
from wiki_schema import page_types

logger = logging.getLogger("ayma.profile_manual")


def _mark_avatar_stale(db, uid: str) -> None:
    """Flag the user's standing AI-avatar snapshot stale after a manual
    profile/wiki edit. Cheap (no LLM); the background sweep rebuilds it at most
    once an hour and only if the source actually changed. Best-effort — a stale
    hook must never break a profile write."""
    try:
        import persona_snapshot

        persona_snapshot.mark_persona_stale(db, uid)
    except Exception:  # noqa: BLE001
        logger.debug("persona stale hook failed", exc_info=True)

_PROMPTS = Path(__file__).with_name("prompts")

MAX_TEXT_CHARS = 12000
MAX_TITLE_CHARS = 40
MAX_CUSTOM_SECTIONS = 10
F_CUSTOM = "custom_section"
CUSTOM_PAGE_TYPE = "misc"
_CUSTOM_ID_PREFIX = "custom-"
_MAX_SLUG_CHARS = 40
F_PINNED = "manual_pinned"
F_PROPOSAL = "pending_proposal"

KIND_REMOVED = "removed_fact"
KIND_ADDED = "added_fact"
KIND_WORDING = "wording_only"
_KINDS = (KIND_REMOVED, KIND_ADDED, KIND_WORDING)

_HEADING = re.compile(r"^##\s+(.+?)\s*$")
_URL = re.compile(r"(?:https?://|www\.)\S+", re.IGNORECASE)
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
_PHONE = re.compile(r"\+?\d[\d\s().\-]{6,}\d")
_MIN_PHONE_DIGITS = 9

_CLASSIFY_SCHEMA = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "kind": {"type": "string", "enum": list(_KINDS)},
                },
                "required": ["id", "kind"],
            },
        }
    },
    "required": ["items"],
}

_MODERATION_SCHEMA = {
    "type": "object",
    "properties": {"flagged": {"type": "boolean"}, "reason": {"type": "string"}},
    "required": ["flagged", "reason"],
}


class ProfileTextError(ValueError):
    """A manual-edit save that cannot proceed. ``code`` is machine-readable
    (``bad_sections`` / ``bad_title`` / ``too_many_sections`` / ``too_long`` /
    ``contact_info`` / ``moderation`` / ``moderation_unavailable`` /
    ``stale``); ``str(exc)`` is user-facing."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _prompt(name: str) -> str:
    return (_PROMPTS / name).read_text(encoding="utf-8").strip()


def _norm(text: str) -> str:
    return " ".join((text or "").split())


def _now() -> datetime:
    return datetime.now(timezone.utc)


# --- reading the public text -------------------------------------------


def public_sections(db, uid: str) -> list[dict]:
    """The narrative pages shown on the public profile, in display order, each
    ``{page_id, title, body}`` with the body being exactly its public text."""
    out: list[dict] = []
    for sec in story.get_story(db, uid).get("sections", []):
        if sec.get("visibility") != story.VIS_PUBLIC:
            continue
        if sec["page_id"] in story.REPORT_LINKED_PAGE_IDS or sec.get("is_skill"):
            continue
        body = story.strip_private_spans(sec.get("body") or "")
        if body:
            out.append(
                {"page_id": sec["page_id"], "title": sec["title"], "body": body}
            )
    return out


def assemble_text(sections: list[dict]) -> str:
    return "\n\n".join(f"## {s['title']}\n{s['body']}" for s in sections)


def text_version(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:16]


def get_text(db, uid: str) -> dict:
    sections = public_sections(db, uid)
    text = assemble_text(sections)
    return {
        "text": text,
        "version": text_version(text),
        "max_chars": MAX_TEXT_CHARS,
    }


def _parse_headings(text: str) -> list[tuple[str, list[str]]]:
    parsed: list[tuple[str, list[str]]] = []
    cur: tuple[str, list[str]] | None = None
    for line in text.replace("\r\n", "\n").split("\n"):
        m = _HEADING.match(line)
        if m:
            cur = (m.group(1).strip(), [])
            parsed.append(cur)
        elif cur is not None:
            cur[1].append(line)
        elif line.strip():
            raise ProfileTextError(
                "bad_sections",
                "Keep every paragraph under one of the ## section headings.",
            )
    return parsed


def _clean_body(lines: list[str]) -> str:
    return story._SPAN_RE.sub("", "\n".join(lines)).strip()


def _reserved_titles() -> set[str]:
    """Names of the profile's built-in sections; a custom section cannot take
    one of them (a visible built-in section is matched by its heading before
    this is ever consulted)."""
    names = {story.humanize(t) for t in page_types()}
    names |= set(story._SKILL_TITLES.values())
    names |= {story.humanize(pid) for pid in story.REPORT_LINKED_PAGE_IDS}
    return {n.casefold() for n in names}


def validate_title(title: str) -> None:
    """Raise ``bad_title`` unless ``title`` can name a custom section."""
    if len(title) > MAX_TITLE_CHARS:
        raise ProfileTextError(
            "bad_title",
            f"Section titles are limited to {MAX_TITLE_CHARS} characters: "
            f"\"{title[:MAX_TITLE_CHARS]}...\".",
        )
    if not any(c.isalnum() for c in title):
        raise ProfileTextError(
            "bad_title", "Section titles need at least one letter or number."
        )
    if _URL.search(title) or "://" in title:
        raise ProfileTextError(
            "bad_title", f"\"{title}\": links can't go in a section title."
        )
    try:
        check_contact_info(title)
    except ProfileTextError as exc:
        raise ProfileTextError("bad_title", f"\"{title}\": {exc}") from exc
    if title.casefold() in _reserved_titles():
        raise ProfileTextError(
            "bad_title",
            f"\"{title}\" is one of Ayma's own section names. "
            "Pick a different title.",
        )


def custom_pages(db, uid: str) -> dict[str, dict]:
    """Every custom-section page of the user, whatever its visibility (a
    removed custom section keeps its page, holding the removed facts)."""
    out: dict[str, dict] = {}
    for snap in story._pages_col(db, uid).stream():
        data = snap.to_dict() or {}
        if data.get(F_CUSTOM) is True:
            out[snap.id] = data
    return out


def _slug(title: str) -> str:
    ascii_title = (
        unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode()
    )
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_title.lower()).strip("-")
    return slug[:_MAX_SLUG_CHARS].strip("-") or "section"


def _new_page_id(title: str, taken: set[str]) -> str:
    base = _CUSTOM_ID_PREFIX + _slug(title)
    page_id, n = base, 1
    while page_id in taken:
        n += 1
        page_id = f"{base}-{n}"
    return page_id


def plan_sections(
    text: str, sections: list[dict], customs: dict[str, dict]
) -> dict:
    """Read the edited text against the current public sections.

    Headings match sections by title (case-insensitive, repeated titles by
    order). A heading matching none becomes a custom section: a rename of a
    custom section whose own heading vanished when the unmatched headings and
    the vanished custom sections are equal in number (paired in order),
    otherwise a new one (reusing the page of a previously removed custom
    section of the same title). A vanished section comes back empty; its
    facts are kept by the removed-content rule.

    Returns ``{bodies, titles, creates}``: ``bodies`` is ``{page_id: new
    public body}`` for every current section plus every new one, ``titles``
    the titles to store ``{page_id: title}`` (renames and new pages), and
    ``creates`` the page ids of new or revived custom sections."""
    parsed = _parse_headings(text)
    by_title: dict[str, list[str]] = {}
    for s in sections:
        by_title.setdefault(s["title"].casefold(), []).append(s["page_id"])
    used: dict[str, int] = {}
    bodies: dict[str, str] = {s["page_id"]: "" for s in sections}
    unmatched: list[tuple[str, str]] = []
    for title, lines in parsed:
        key = title.casefold()
        idx = used.get(key, 0)
        ids = by_title.get(key, [])
        used[key] = idx + 1
        if idx < len(ids):
            bodies[ids[idx]] = _clean_body(lines)
        else:
            unmatched.append((title, _clean_body(lines)))

    seen: set[str] = set()
    for title, _body in unmatched:
        if title.casefold() in seen:
            raise ProfileTextError(
                "bad_sections", f"You have two sections titled \"{title}\"."
            )
        seen.add(title.casefold())
        validate_title(title)

    orphans = [
        s["page_id"]
        for s in sections
        if s["page_id"] in customs and not bodies[s["page_id"]]
    ]
    by_custom_title = {
        str(d.get(story.F_TITLE) or "").casefold(): pid for pid, d in customs.items()
    }
    pair = len(orphans) == len(unmatched) and not any(
        t.casefold() in by_custom_title for t, _b in unmatched
    )
    titles: dict[str, str] = {}
    creates: list[str] = []
    taken = set(customs) | {s["page_id"] for s in sections}
    for i, (title, body) in enumerate(unmatched):
        if not body:
            continue
        if pair:
            pid = orphans[i]
            titles[pid] = title
        elif title.casefold() in by_custom_title:
            pid = by_custom_title[title.casefold()]
            creates.append(pid)
        else:
            pid = _new_page_id(title, taken)
            taken.add(pid)
            creates.append(pid)
            titles[pid] = title
        bodies[pid] = body

    visible = {
        pid
        for pid in [s["page_id"] for s in sections if s["page_id"] in customs]
        + creates
        if bodies.get(pid)
    }
    if len(visible) > MAX_CUSTOM_SECTIONS:
        raise ProfileTextError(
            "too_many_sections",
            f"You can have up to {MAX_CUSTOM_SECTIONS} sections of your own.",
        )
    return {"bodies": bodies, "titles": titles, "creates": creates}


# --- diffing -----------------------------------------------------------


def _blocks(before: str, after: str) -> list[dict]:
    b = rb.split_sentences(before)
    a = rb.split_sentences(after)
    sm = difflib.SequenceMatcher(
        None, [_norm(x) for x in b], [_norm(x) for x in a], autojunk=False
    )
    return [
        {"removed": b[i1:i2], "added": a[j1:j2]}
        for tag, i1, i2, j1, j2 in sm.get_opcodes()
        if tag != "equal"
    ]


def diff_segments(before: str, after: str) -> list[dict]:
    """Sentence-level diff for display: ``[{op: same|add|remove, text}]``."""
    b = rb.split_sentences(before)
    a = rb.split_sentences(after)
    sm = difflib.SequenceMatcher(
        None, [_norm(x) for x in b], [_norm(x) for x in a], autojunk=False
    )
    out: list[dict] = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            out += [{"op": "same", "text": t} for t in b[i1:i2]]
            continue
        out += [{"op": "remove", "text": t} for t in b[i1:i2]]
        out += [{"op": "add", "text": t} for t in a[j1:j2]]
    return out


async def _classify(uid: str, blocks: list[dict]) -> dict[str, str]:
    """``{sentence id: kind}`` — ``r<n>`` ids default to ``removed_fact`` and
    ``a<n>`` to ``added_fact`` (the safe reading) for anything the model does
    not answer, or if the call fails."""
    lines: list[str] = []
    verdicts: dict[str, str] = {}
    for n, blk in enumerate(blocks, 1):
        lines.append(f"Block {n} (section: {blk['title']})")
        lines.append("REMOVED:")
        for sent_id, text in blk["removed_ids"]:
            lines.append(f"{sent_id}: {text}")
            verdicts[sent_id] = KIND_REMOVED
        lines.append("ADDED:")
        for sent_id, text in blk["added_ids"]:
            lines.append(f"{sent_id}: {text}")
            verdicts[sent_id] = KIND_ADDED
        lines.append("")
    try:
        result = await gemini.generate_json(
            "\n".join(lines),
            system_prompt=_prompt("profile_diff_classify.md"),
            response_schema=_CLASSIFY_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_PROFILE_MANUAL,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001 - fall back to the safe defaults
        logger.exception("profile diff classification failed for %s", uid)
        return verdicts
    for item in (result or {}).get("items", []) if isinstance(result, dict) else []:
        if (
            isinstance(item, dict)
            and item.get("id") in verdicts
            and item.get("kind") in _KINDS
        ):
            verdicts[item["id"]] = item["kind"]
    return verdicts


# --- moderation --------------------------------------------------------


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


# --- saving a manual edit ----------------------------------------------


def _build_body(existing_body: str, new_public: str, removed: list[str]) -> str:
    """New stored body: the user's text as the public part, every existing
    private / ai_only span kept, and each removed fact added as an ai_only
    span (unless that sentence is already held in one)."""
    kept = [s for s in story.parse_spans(existing_body) if s["kind"] != "public"]
    held = _norm(" ".join(s["text"] for s in kept if s["kind"] == "ai_only"))
    new_removed = [r for r in removed if _norm(r) not in held]
    segments = [{"text": new_public, "kind": "public"}]
    if kept or new_removed:
        segments.append({"text": "\n\n", "kind": "public"})
    segments += kept
    if new_removed:
        sep = "\n" if kept and kept[-1]["kind"] == "ai_only" else ""
        segments.append(
            {"text": sep + "\n".join(new_removed), "kind": "ai_only"}
        )
    return story._serialize_spans(segments).strip()


async def save_text(db, uid: str, text: str, base_version: str) -> dict:
    """Apply a manual edit of the whole public text. Raises
    :class:`ProfileTextError` without writing anything when it is refused."""
    text = text or ""
    if len(text) > MAX_TEXT_CHARS:
        raise ProfileTextError(
            "too_long",
            f"Your profile text is over {MAX_TEXT_CHARS:,} characters. "
            "Please shorten it.",
        )
    sections = await asyncio.to_thread(public_sections, db, uid)
    if text_version(assemble_text(sections)) != base_version:
        raise ProfileTextError(
            "stale",
            "Your profile changed while you were editing. Reopen the editor "
            "to see the latest text.",
        )
    customs = await asyncio.to_thread(custom_pages, db, uid)
    plan = plan_sections(text, sections, customs)
    bodies, titles, creates = plan["bodies"], plan["titles"], set(plan["creates"])

    current = {s["page_id"]: s for s in sections}
    changed: list[dict] = []
    for page_id, new in bodies.items():
        sec = current.get(page_id) or {"title": titles.get(page_id, ""), "body": ""}
        new_title = titles.get(page_id)
        renamed = (
            page_id in current
            and new_title is not None
            and new_title != sec["title"]
        )
        if page_id not in creates and not renamed and _norm(new) == _norm(sec["body"]):
            continue
        changed.append(
            {
                "page_id": page_id,
                "title": new_title or sec["title"],
                "new_title": new_title,
                "create": page_id in creates,
                "new": new,
                "blocks": _blocks(sec["body"], new),
            }
        )
    if not changed:
        return {"ok": True, "changed": False, "sections": []}

    counter = {"r": 0, "a": 0}
    flat: list[dict] = []
    for sec in changed:
        for blk in sec["blocks"]:
            ids = {}
            for side, key in (("r", "removed"), ("a", "added")):
                ids[key + "_ids"] = []
                for sent in blk[key]:
                    counter[side] += 1
                    ids[key + "_ids"].append((f"{side}{counter[side]}", sent))
            blk.update(ids)
            blk["title"] = sec["title"]
            flat.append(blk)

    added_all = [t for blk in flat for _i, t in blk["added_ids"]]
    for sentence in added_all:
        check_contact_info(sentence)
    new_titles = [
        f"Section title: {sec['new_title']}" for sec in changed if sec["new_title"]
    ]
    if added_all or new_titles:
        await _moderate(uid, "\n".join(new_titles + added_all))
    verdicts = await _classify(uid, flat)

    counts = {KIND_REMOVED: 0, KIND_ADDED: 0, KIND_WORDING: 0}
    for sec in changed:
        removed = [
            t
            for blk in sec["blocks"]
            for sid, t in blk["removed_ids"]
            if verdicts[sid] == KIND_REMOVED
        ]
        added = [
            t
            for blk in sec["blocks"]
            for sid, t in blk["added_ids"]
            if verdicts[sid] == KIND_ADDED
        ]
        for blk in sec["blocks"]:
            for sid, _t in blk["removed_ids"] + blk["added_ids"]:
                counts[verdicts[sid]] += 1
        await asyncio.to_thread(
            _write_section,
            db,
            uid,
            sec["page_id"],
            sec["new"],
            removed,
            added,
            sec["new_title"],
            sec["create"],
        )
    _mark_avatar_stale(db, uid)
    return {
        "ok": True,
        "changed": True,
        "sections": [s["page_id"] for s in changed],
        "removed_to_notes": counts[KIND_REMOVED],
        "added_facts": counts[KIND_ADDED],
        "wording_only": counts[KIND_WORDING],
    }


def _write_section(
    db,
    uid: str,
    page_id: str,
    new_public: str,
    removed: list[str],
    added: list[str],
    title: str | None = None,
    create: bool = False,
) -> None:
    ref = story._pages_col(db, uid).document(page_id)
    if create:
        # A new custom section, or a removed one coming back: always a public
        # ``misc`` page; whatever a revived page still holds stays untouched.
        base = {
            story.F_PAGE_TYPE: CUSTOM_PAGE_TYPE,
            story.F_VISIBILITY: story.VIS_PUBLIC,
            story.F_USER_HIDDEN: False,
            F_CUSTOM: True,
        }
        if not ref.get().exists:
            base["created_at"] = story._server_ts()
            base[story.F_AI_BODY] = ""
        ref.set(base, merge=True)
    ref, data = story._require_page(db, uid, page_id)
    existing_body = story._display_body(db, uid, page_id, data)
    norm_new = _norm(new_public)
    pinned = [
        p for p in (data.get(F_PINNED) or []) if _norm(p) and _norm(p) in norm_new
    ]
    pinned += [a for a in added if _norm(a) not in {_norm(p) for p in pinned}]
    ai_body = (data.get(story.F_AI_BODY) or "").strip()
    fresh = [a for a in added if _norm(a) not in _norm(ai_body)]
    if fresh:
        ai_body = (ai_body + "\n\n" if ai_body else "") + " ".join(fresh)
    ref.set(
        {
            story.F_USER_EDITS: _build_body(existing_body, new_public, removed),
            story.F_USER_UPDATED_AT: story._server_ts(),
            story.F_AI_BODY: ai_body,
            F_PINNED: pinned,
            F_PROPOSAL: None,
            **({story.F_TITLE: title} if title else {}),
        },
        merge=True,
    )
    story._snapshot_section(db, uid, page_id, story.AUTHOR_USER, "edited manually")


# --- Ayma's updates: propose, then apply or dismiss --------------------


def preserve(new_body: str, current_body: str, pinned: list[str]) -> str:
    """``new_body`` with every ``ai_only`` span of ``current_body`` and every
    pinned sentence guaranteed present."""
    segments = story.parse_spans(new_body)
    have_ai = _norm(" ".join(s["text"] for s in segments if s["kind"] == "ai_only"))
    public_now = _norm(story.strip_private_spans(new_body))
    for seg in story.parse_spans(current_body):
        if seg["kind"] == "ai_only" and _norm(seg["text"]) not in have_ai:
            segments.append({"text": "\n", "kind": "public"})
            segments.append({"text": seg["text"].strip(), "kind": "ai_only"})
    for sentence in pinned:
        if _norm(sentence) and _norm(sentence) not in public_now:
            segments.append({"text": "\n\n" + sentence, "kind": "public"})
    return story._serialize_spans(segments).strip()


def route_ai_update(page_id: str, cur: dict, payload: dict) -> dict:
    """Extra fields for ``wiki_ingest._write_page`` when Ayma rewrites a page
    that already shows public text. The new ``ai_body`` itself is always kept
    (it is Ayma's memory), but the text visitors see only changes when the
    user approves: the current public text is frozen as ``user_edits`` and the
    rewrite becomes a ``pending_proposal``. A new proposal always REPLACES the
    page's previous one, so a section is never carrying two cards at once —
    only the latest rewrite is ever pending. Pages with nothing public yet
    (first write, private, hidden) are written straight through.

    The propose/Apply-Dismiss flow is only for Ayma's OWN discovered edits.
    When the user themselves just edited this section in place
    (``story.save_section``/``remove_section`` stamped the one-shot
    ``suppress_next_proposal`` guard and already cleared the live card), the
    **next** rewrite that would differ from their text is swallowed instead of
    re-surfaced as a pending card — so a lagging re-ingest can never revert the
    user's own change, and a user-requested edit never produces a proposal
    (founder bug 2026-10-28). The guard is spent only on that one suppressed
    rewrite: writes with nothing to propose (private/hidden page, first public
    write, or a rewrite that already matches the live public text) keep it, so
    it still catches the first rewrite that genuinely diverges rather than
    being wasted on an unrelated no-op pass in between."""
    suppress = bool(cur.get(story.F_SUPPRESS_PROPOSAL))
    has_proposal = bool(cur.get(F_PROPOSAL))

    def _settle(spend: bool) -> dict:
        """A write with nothing to propose: clear any stale card, and consume
        the user-edit guard only when ``spend`` (i.e. we actually swallowed a
        diverging rewrite)."""
        out: dict = {}
        if has_proposal:
            out[F_PROPOSAL] = None
        if suppress and spend:
            out[story.F_SUPPRESS_PROPOSAL] = False
        return out

    if (
        payload.get("visibility") != story.VIS_PUBLIC
        or cur.get("visibility") != story.VIS_PUBLIC
        or page_id in story.REPORT_LINKED_PAGE_IDS
        or page_id in story.SKILL_PAGE_IDS
    ):
        return _settle(spend=False)
    current = story._effective_body(cur)
    current_public = _norm(story.strip_private_spans(current))
    if not current_public:
        return _settle(spend=False)
    after = preserve(payload["ai_body"], current, list(cur.get(F_PINNED) or []))
    if _norm(story.strip_private_spans(after)) == current_public:
        return _settle(spend=False)
    # Ayma's rewrite diverges from the live public text.
    if suppress:
        # The user just edited this section directly: swallow this one diverging
        # rewrite (never re-propose or revert their change) and spend the guard.
        return _settle(spend=True)
    out: dict = {F_PROPOSAL: {"before": current, "after": after, "created_at": _now()}}
    if not (cur.get(story.F_USER_EDITS) or "").strip():
        out[story.F_USER_EDITS] = current
    return out


def _title(page_id: str, data: dict) -> str:
    return story._section_title(
        page_id,
        str(data.get(story.F_PAGE_TYPE) or "misc"),
        data.get(story.F_TITLE) or "",
    )


def _iter_changes(before_public: str, after_public: str):
    """Yield ``(segment, change_id)`` over the sentence diff. ``change_id`` is
    ``None`` for unchanged sentences and ``c0``, ``c1`` … for each added or
    removed sentence, in diff order. Both ``before`` and ``after`` are frozen
    on the proposal, so these ids are stable — a single change can be applied
    or dismissed on its own and the rest re-render correctly."""
    k = 0
    for seg in diff_segments(before_public, after_public):
        if seg["op"] == "same":
            yield seg, None
        else:
            yield seg, f"c{k}"
            k += 1


def _change_items(before_public: str, after_public: str) -> list[dict]:
    """The reviewable changes: one ``{id, op, text}`` per added/removed
    sentence."""
    return [
        {"id": cid, "op": seg["op"], "text": seg["text"]}
        for seg, cid in _iter_changes(before_public, after_public)
        if cid is not None
    ]


def _decided_map(prop: dict) -> dict[str, str]:
    dec = prop.get("decided")
    return dict(dec) if isinstance(dec, dict) else {}


def _rebuild_public(
    before_public: str, after_public: str, decided: dict[str, str]
) -> tuple[str, list[str]]:
    """The public text to show given the decisions so far, plus the sentences
    to keep privately (so nothing is discarded):

    * unchanged sentence -> stays public;
    * added sentence -> public once *applied*; a *dismissed* one is kept
      privately (never shown publicly);
    * removed sentence -> stays public until the removal is *applied*, then it
      is kept privately rather than dropped.

    An undecided change leaves the public text exactly as it was.
    """
    public: list[str] = []
    private: list[str] = []
    for seg, cid in _iter_changes(before_public, after_public):
        if cid is None:
            public.append(seg["text"])
            continue
        verdict = decided.get(cid)
        if seg["op"] == "add":
            if verdict == "applied":
                public.append(seg["text"])
            elif verdict == "dismissed":
                private.append(seg["text"])
        else:  # remove
            if verdict == "applied":
                private.append(seg["text"])
            else:
                public.append(seg["text"])
    return _norm(" ".join(public)), private


def _compose_body(
    current_body: str, new_public: str, private: list[str], pinned: list[str]
) -> str:
    """Rebuild the stored body: ``new_public`` as the public text, every
    existing private / ``ai_only`` span kept, each ``private`` sentence added
    as an ``ai_only`` note (Ayma still has it and it shows in Ayma's Notes, but
    never on the public profile), and every pinned sentence kept public."""
    body = _build_body(current_body, new_public, private)
    public_now = _norm(story.strip_private_spans(body))
    segments = story.parse_spans(body)
    for sentence in pinned:
        if _norm(sentence) and _norm(sentence) not in public_now:
            segments.append({"text": "\n\n" + sentence, "kind": "public"})
    return story._serialize_spans(segments).strip()


def _write_decided(
    db,
    uid: str,
    page_id: str,
    ref,
    data: dict,
    prop: dict,
    before_public: str,
    after_public: str,
    items: list[dict],
    decided: dict[str, str],
) -> dict:
    """Write the public text, private notes and ``ai_body`` implied by
    ``decided``, keep the proposal with its decisions until every change is
    resolved (then clear it), and commit a version. Dismissed additions and
    applied removals are appended to ``ai_body`` so Ayma's matching/chat still
    know them."""
    new_public, private = _rebuild_public(before_public, after_public, decided)
    pinned = list(data.get(F_PINNED) or [])
    body = _compose_body(story._effective_body(data), new_public, private, pinned)
    ai_body = (data.get(story.F_AI_BODY) or "").strip()
    fresh = [p for p in private if _norm(p) not in _norm(ai_body)]
    if fresh:
        ai_body = (ai_body + "\n\n" if ai_body else "") + " ".join(fresh)
    remaining = [it for it in items if it["id"] not in decided]
    ref.set(
        {
            story.F_USER_EDITS: body,
            story.F_USER_UPDATED_AT: story._server_ts(),
            story.F_AI_BODY: ai_body,
            F_PROPOSAL: None if not remaining else {**prop, "decided": decided},
        },
        merge=True,
    )
    version_id = story._snapshot_section(
        db, uid, page_id, story.AUTHOR_AYMA, "update reviewed by you"
    )
    _mark_avatar_stale(db, uid)
    return {"ok": True, "remaining": len(remaining), "head_version_id": version_id}


def _live_matches_decisions(
    data: dict, before_public: str, after_public: str, decided: dict[str, str]
) -> bool:
    """Whether the live public text is still exactly what the proposal's
    decisions so far imply (``_rebuild_public``). It is, in the normal flow:
    an undecided proposal leaves the live text as the frozen ``before``, and
    each per-change apply writes exactly the rebuilt text. It is NOT when the
    user edited the section directly in the meantime (``save_section`` already
    clears the card, but a pre-fix card may linger) or a newer rewrite moved
    the base: the proposal is then built on text that no longer exists, so
    applying it would overwrite the user's current wording. Such a proposal is
    stale — dropped on read and refused on apply, never regressed onto."""
    live = _norm(story.strip_private_spans(story._effective_body(data)))
    expected, _private = _rebuild_public(before_public, after_public, decided)
    return live == expected


def list_proposals(db, uid: str) -> list[dict]:
    """Every pending public-profile change, grouped by section, each change a
    ``{id, op, text}`` row with its own stable id. The profile banner counts
    the changes across this list. A proposal that is not a dict, whose changes
    have all been decided, or that is stale — its frozen base no longer matches
    the live public text, because the user edited the line directly or a newer
    rewrite superseded it (:func:`_live_matches_decisions`) — has nothing left
    to review: it is cleared here and logged, so the banner never counts a
    change that cannot render and a lingering stale card self-heals on read."""
    out = []
    for snap in story._pages_col(db, uid).stream():
        data = snap.to_dict() or {}
        prop = data.get(F_PROPOSAL)
        if not prop or data.get(story.F_USER_HIDDEN) is True:
            continue
        if not isinstance(prop, dict):
            snap.reference.set({F_PROPOSAL: None}, merge=True)
            logger.info(
                "profile proposal cleared as malformed uid=%s page=%s", uid, snap.id
            )
            continue
        before_public = story.strip_private_spans(prop.get("before") or "")
        after_public = story.strip_private_spans(prop.get("after") or "")
        decided = _decided_map(prop)
        pending = [
            it for it in _change_items(before_public, after_public)
            if it["id"] not in decided
        ]
        if not pending or not _live_matches_decisions(
            data, before_public, after_public, decided
        ):
            snap.reference.set({F_PROPOSAL: None}, merge=True)
            logger.info(
                "profile proposal cleared as stale uid=%s page=%s", uid, snap.id
            )
            continue
        out.append(
            {"page_id": snap.id, "title": _title(snap.id, data), "changes": pending}
        )
    out.sort(key=lambda p: p["title"].lower())
    return out


# The set of pending-change keys the user was last notified about — a
# top-level field on ``users/{uid}`` so the suggestion push is deduped.
F_SUGGEST_NOTIFIED = "profile_suggestions_notified"


def pending_change_keys(db, uid: str) -> set[str]:
    """A content-stable key per undecided public-profile change
    (``page_id:sha1(op+text)``), across all sections. Stable across re-renders
    and re-ingests: a re-proposed section with different wording yields
    different keys, so a genuinely new change is detected even when its
    positional id (``c0`` …) is reused."""
    keys: set[str] = set()
    for sec in list_proposals(db, uid):
        for change in sec["changes"]:
            digest = hashlib.sha1(
                f"{change['op']}:{_norm(change['text'])}".encode("utf-8")
            ).hexdigest()[:12]
            keys.add(f"{sec['page_id']}:{digest}")
    return keys


def consume_new_suggestions(db, uid: str) -> int:
    """Compare the current pending public-profile changes to the set the user
    was last notified about, updating the stored set.

    Returns the number of currently-pending changes **when there is at least
    one that is genuinely new** (the pending count went from 0 to >0, or new
    items were added) — the caller then sends one notification. Returns 0 when
    nothing is new (so the nightly run doesn't re-ping for an unchanged set),
    and resets the stored set when there is nothing pending (so a future 0->>0
    fires again)."""
    keys = pending_change_keys(db, uid)
    user_ref = db.collection("users").document(uid)
    stored = (user_ref.get().to_dict() or {}).get(F_SUGGEST_NOTIFIED)
    prev = set(stored) if isinstance(stored, list) else set()
    if not keys:
        if prev:
            user_ref.set({F_SUGGEST_NOTIFIED: []}, merge=True)
        return 0
    has_new = bool(keys - prev)
    if keys != prev:
        user_ref.set({F_SUGGEST_NOTIFIED: sorted(keys)}, merge=True)
    return len(keys) if has_new else 0


def _load_proposal(db, uid: str, page_id: str) -> tuple:
    """``(ref, data, prop, before_public, after_public, items)`` for a page
    with a dict proposal. ``KeyError`` when there is none, or when the proposal
    is stale — its frozen base no longer matches the live public text
    (:func:`_live_matches_decisions`), so applying it would overwrite the
    user's current wording. A stale proposal is cleared here before raising, so
    an Apply/Apply-all can never regress a line to an older proposed value; the
    client's refetch then shows the card gone."""
    ref, data = story._require_page(db, uid, page_id)
    prop = data.get(F_PROPOSAL)
    if not isinstance(prop, dict):
        raise KeyError(page_id)
    before_public = story.strip_private_spans(prop.get("before") or "")
    after_public = story.strip_private_spans(prop.get("after") or "")
    if not _live_matches_decisions(
        data, before_public, after_public, _decided_map(prop)
    ):
        ref.set({F_PROPOSAL: None}, merge=True)
        logger.info(
            "profile proposal cleared as stale on decide uid=%s page=%s",
            uid,
            page_id,
        )
        raise KeyError(page_id)
    items = _change_items(before_public, after_public)
    return ref, data, prop, before_public, after_public, items


def _decide_one(db, uid: str, page_id: str, change_id: str, verdict: str) -> dict:
    ref, data, prop, before_public, after_public, items = _load_proposal(
        db, uid, page_id
    )
    decided = _decided_map(prop)
    if change_id not in {it["id"] for it in items} or change_id in decided:
        raise KeyError(change_id)
    decided[change_id] = verdict
    return _write_decided(
        db, uid, page_id, ref, data, prop, before_public, after_public, items, decided
    )


def apply_change(db, uid: str, page_id: str, change_id: str) -> dict:
    """Show one added sentence on the public profile (or carry out one
    removal). ``KeyError`` when the change is unknown or already decided."""
    return _decide_one(db, uid, page_id, change_id, "applied")


def dismiss_change(db, uid: str, page_id: str, change_id: str) -> dict:
    """Keep one change off the public profile. It is not discarded: it stays
    in the private profile and Ayma's notes. ``KeyError`` when the change is
    unknown or already decided."""
    return _decide_one(db, uid, page_id, change_id, "dismissed")


def _decide_all(db, uid: str, page_id: str, verdict: str) -> dict:
    ref, data, prop, before_public, after_public, items = _load_proposal(
        db, uid, page_id
    )
    decided = _decided_map(prop)
    for it in items:
        decided.setdefault(it["id"], verdict)
    return _write_decided(
        db, uid, page_id, ref, data, prop, before_public, after_public, items, decided
    )


def apply_proposal(db, uid: str, page_id: str) -> dict:
    """Apply every remaining change in one section (Apply all). ``KeyError``
    when there is no pending update."""
    return _decide_all(db, uid, page_id, "applied")


def dismiss_proposal(db, uid: str, page_id: str) -> dict:
    """Dismiss every remaining change in one section (Dismiss all) — each is
    kept in the private profile and Ayma's notes. ``KeyError`` when there is no
    pending update."""
    return _decide_all(db, uid, page_id, "dismissed")
