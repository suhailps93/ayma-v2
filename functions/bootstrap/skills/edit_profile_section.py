"""Profile-edit tools — available only when the Ayma chat is opened to edit the
user's own public profile (``profile_edit`` on the chat request).

They operate on the caller's own ``users/{uid}/wiki_pages`` — the same sections
the Your Story editor shows. Each write goes through :mod:`story`, which stores
the text as ``user_edits`` verbatim (never a model-massaged body) and commits a
version so a revert is always possible.

Never exposed in normal chat or voice.
"""

from __future__ import annotations

from typing import Callable

import story

from ._base import Skill

_LIST_DECL = {
    "name": "list_profile_sections",
    "description": (
        "List the sections of the user's own public profile — each section's "
        "title, whether it's currently public or private, and a short "
        "snippet. Call this first so you know what's there before editing."
    ),
    "parameters": {"type": "object", "properties": {}},
}

_EDIT_DECL = {
    "name": "edit_profile_section",
    "description": (
        "Rewrite one section of the user's own public profile. Pass the "
        "section's title and the full replacement text for that section. Only "
        "write what the user actually told you — keep it truthful."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "the section title, e.g. 'Work & study'",
            },
            "new_text": {
                "type": "string",
                "description": "the full new body for that section",
            },
        },
        "required": ["title", "new_text"],
    },
}

_VIS_DECL = {
    "name": "set_profile_section_visibility",
    "description": (
        "Show or hide a whole section of the user's own public profile."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {"type": "string"},
            "public": {
                "type": "boolean",
                "description": "true to show it publicly, false to hide it",
            },
        },
        "required": ["title", "public"],
    },
}


def _find_page(db, uid: str, title: str) -> dict | None:
    want = (title or "").strip().lower()
    if not want:
        return None
    for s in story.get_story(db, uid).get("sections", []):
        if str(s.get("title", "")).strip().lower() == want:
            return s
    # A looser contains-match so "work" finds "Work & study".
    for s in story.get_story(db, uid).get("sections", []):
        if want in str(s.get("title", "")).strip().lower():
            return s
    return None


def _bind_list(db, uid: str) -> Callable[..., str]:
    def list_profile_sections() -> str:
        sections = story.get_story(db, uid).get("sections", [])
        if not sections:
            return "your public profile has no sections yet"
        lines = []
        for s in sections:
            body = " ".join(str(s.get("body") or "").split())
            snippet = (body[:120] + "…") if len(body) > 120 else body
            vis = "public" if s.get("visibility") == "public" else "private"
            lines.append(f"- {s.get('title')} [{vis}]: {snippet or '(empty)'}")
        return "\n".join(lines)

    return list_profile_sections


def _bind_edit(db, uid: str) -> Callable[..., str]:
    def edit_profile_section(title: str = "", new_text: str = "") -> str:
        new_text = (new_text or "").strip()
        if not new_text:
            return "give me the new wording for that section"
        page = _find_page(db, uid, title)
        if page is None:
            return f"couldn't find a section called '{title}'"
        story.save_section(db, uid, page["page_id"], new_text)
        return f"updated '{page['title']}'"

    return edit_profile_section


def _bind_visibility(db, uid: str) -> Callable[..., str]:
    def set_profile_section_visibility(
        title: str = "", public: bool = True
    ) -> str:
        page = _find_page(db, uid, title)
        if page is None:
            return f"couldn't find a section called '{title}'"
        story.set_visibility(
            db, uid, page["page_id"], "public" if public else "private"
        )
        return (
            f"'{page['title']}' is public now"
            if public
            else f"'{page['title']}' is hidden now"
        )

    return set_profile_section_visibility


SKILLS: list[Skill] = [
    Skill(declaration=_LIST_DECL, bind=_bind_list),
    Skill(declaration=_EDIT_DECL, bind=_bind_edit),
    Skill(declaration=_VIS_DECL, bind=_bind_visibility),
]
