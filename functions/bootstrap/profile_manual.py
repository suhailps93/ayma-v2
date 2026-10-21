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

New text is moderated like any other user-facing text: a length cap, no phone
numbers or email addresses (links are allowed), and a model safety pass
(``prompts/profile_text_moderation.md``).

Later AI updates to a public page's text are never applied silently:
:func:`route_ai_update` (called by ``wiki_ingest``) freezes the current public
text as the page's ``user_edits`` and stores the AI's rewrite as a
``pending_proposal`` on the page, which the user applies or dismisses
(:func:`apply_proposal` / :func:`dismiss_proposal`). Pinned sentences and
``ai_only`` spans are re-attached to every proposal, so approval can never
drop them. Everything lives on the ``wiki_pages`` docs, so account deletion
and the knowledge wipe already cover it.
"""

from __future__ import annotations

import asyncio
import difflib
import hashlib
import logging
import re
from datetime import datetime, timezone
from pathlib import Path

import gemini
import report_blocks as rb
import story

logger = logging.getLogger("ayma.profile_manual")

_PROMPTS = Path(__file__).with_name("prompts")

MAX_TEXT_CHARS = 12000
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
    (``bad_sections`` / ``too_long`` / ``contact_info`` / ``moderation`` /
    ``moderation_unavailable`` / ``stale``); ``str(exc)`` is user-facing."""

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


def parse_text(text: str, sections: list[dict]) -> dict[str, str]:
    """``{page_id: new public body}`` from the edited text. Headings are
    matched to the current sections by title (repeated titles by order); a
    section whose heading was deleted comes back empty."""
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
    by_title: dict[str, list[str]] = {}
    for s in sections:
        by_title.setdefault(s["title"].casefold(), []).append(s["page_id"])
    used: dict[str, int] = {}
    bodies: dict[str, str] = {s["page_id"]: "" for s in sections}
    for title, lines in parsed:
        key = title.casefold()
        idx = used.get(key, 0)
        ids = by_title.get(key, [])
        if idx >= len(ids):
            raise ProfileTextError(
                "bad_sections",
                f"\"{title}\" isn't one of your profile sections. "
                "Keep the ## headings as they are.",
            )
        used[key] = idx + 1
        bodies[ids[idx]] = story._SPAN_RE.sub("", "\n".join(lines)).strip()
    return bodies


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
            feature="profile_manual",
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
            feature="profile_manual",
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
    bodies = parse_text(text, sections)

    changed: list[dict] = []
    for sec in sections:
        new = bodies[sec["page_id"]]
        if _norm(new) == _norm(sec["body"]):
            continue
        changed.append(
            {
                "page_id": sec["page_id"],
                "title": sec["title"],
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
    if added_all:
        await _moderate(uid, "\n".join(added_all))
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
            _write_section, db, uid, sec["page_id"], sec["new"], removed, added
        )
    return {
        "ok": True,
        "changed": True,
        "sections": [s["page_id"] for s in changed],
        "removed_to_notes": counts[KIND_REMOVED],
        "added_facts": counts[KIND_ADDED],
        "wording_only": counts[KIND_WORDING],
    }


def _write_section(
    db, uid: str, page_id: str, new_public: str, removed: list[str], added: list[str]
) -> None:
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
    rewrite becomes a ``pending_proposal``. Pages with nothing public yet
    (first write, private, hidden) are written straight through."""
    if (
        payload.get("visibility") != story.VIS_PUBLIC
        or cur.get("visibility") != story.VIS_PUBLIC
        or page_id in story.REPORT_LINKED_PAGE_IDS
        or page_id in story.SKILL_PAGE_IDS
    ):
        return {}
    current = story._effective_body(cur)
    current_public = _norm(story.strip_private_spans(current))
    if not current_public:
        return {}
    after = preserve(payload["ai_body"], current, list(cur.get(F_PINNED) or []))
    if _norm(story.strip_private_spans(after)) == current_public:
        return {F_PROPOSAL: None} if cur.get(F_PROPOSAL) else {}
    out: dict = {F_PROPOSAL: {"before": current, "after": after, "created_at": _now()}}
    if not (cur.get(story.F_USER_EDITS) or "").strip():
        out[story.F_USER_EDITS] = current
    return out


def _proposal_view(page_id: str, data: dict) -> dict:
    prop = data.get(F_PROPOSAL) or {}
    before = story.strip_private_spans(prop.get("before") or "")
    after = story.strip_private_spans(prop.get("after") or "")
    created = prop.get("created_at")
    return {
        "page_id": page_id,
        "title": story._section_title(
            page_id, str(data.get(story.F_PAGE_TYPE) or "misc")
        ),
        "before": before,
        "after": after,
        "diff": diff_segments(before, after),
        "created_at": created.isoformat() if hasattr(created, "isoformat") else None,
    }


def list_proposals(db, uid: str) -> list[dict]:
    out = []
    for snap in story._pages_col(db, uid).stream():
        data = snap.to_dict() or {}
        if data.get(F_PROPOSAL) and data.get(story.F_USER_HIDDEN) is not True:
            out.append(_proposal_view(snap.id, data))
    out.sort(key=lambda p: p["title"].lower())
    return out


def apply_proposal(db, uid: str, page_id: str) -> dict:
    """Make the pending rewrite the page's text. ``KeyError`` when none."""
    ref, data = story._require_page(db, uid, page_id)
    prop = data.get(F_PROPOSAL)
    if not prop:
        raise KeyError(page_id)
    body = preserve(
        prop.get("after") or "",
        story._effective_body(data),
        list(data.get(F_PINNED) or []),
    )
    ref.set(
        {
            story.F_USER_EDITS: body,
            story.F_USER_UPDATED_AT: story._server_ts(),
            F_PROPOSAL: None,
        },
        merge=True,
    )
    return {
        "head_version_id": story._snapshot_section(
            db, uid, page_id, story.AUTHOR_AYMA, "update approved by you"
        )
    }


def dismiss_proposal(db, uid: str, page_id: str) -> dict:
    ref, data = story._require_page(db, uid, page_id)
    if not data.get(F_PROPOSAL):
        raise KeyError(page_id)
    ref.set({F_PROPOSAL: None}, merge=True)
    return {"ok": True}
