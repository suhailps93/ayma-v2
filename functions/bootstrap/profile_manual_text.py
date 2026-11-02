"""Reading the public profile text and planning manual edits.

Tier-2 sweep monolith split #12: the ``--- reading the public text ---``
section of the former ``profile_manual.py`` monolith, moved verbatim — no
behavior change.
"""

from __future__ import annotations

import hashlib
import logging
import re
import unicodedata

import story
from wiki_schema import page_types
from profile_manual_common import (
    CUSTOM_PAGE_TYPE,
    F_CUSTOM,
    MAX_CUSTOM_SECTIONS,
    MAX_TEXT_CHARS,
    MAX_TITLE_CHARS,
    ProfileTextError,
    _CUSTOM_ID_PREFIX,
    _HEADING,
    _MAX_SLUG_CHARS,
    _URL,
)
from profile_manual_moderation import check_contact_info

logger = logging.getLogger("ayma.profile_manual")


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
