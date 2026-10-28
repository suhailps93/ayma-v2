"""Story-manage tools — always in the TEXT chat tool set (never voice).

These are the plain-chat counterparts to the Your Story *editor* tools in
``story_edit.py``. The editor tools only exist when the chat is opened from the
story screen with a specific page and highlighted passage in focus
(``story=True``); in the ordinary chat Ayma had no way to act when someone said
"change my story to say…" or "take that out of my story", so she'd fall back on
"I can't do that directly". These two tools close that gap:

* ``edit_story_entry`` — replace one story/wiki section's wording with a
  rewrite the user asked for.
* ``remove_story_entry`` — take one section off the user's story. Like the
  editor's "remove from profile", this is a SOFT remove via the shared
  ``user_hidden`` mechanism (:func:`story.remove_section`): the section is
  hidden from the story and the public profile, Ayma keeps its ``ai_body`` in
  her own notes, and the pre-remove state is committed to the section's version
  history first, so it is always revertible — never a hard, unrecoverable
  delete.

Both resolve the section the user means by matching their words against the
titles / types / bodies of the caller's OWN story sections (``story.get_story``,
scoped to ``uid``) — they can never reach another user's wiki. Each returns a
plain confirmation string naming the section it changed so Ayma tells the user
exactly what happened rather than acting silently.
"""

from __future__ import annotations

import re
from typing import Callable

import story

from ._base import Skill

_WORD_RE = re.compile(r"[a-z0-9]{3,}")
_STOPWORDS = frozenset(
    "the and for with what who how does did about their they them from have "
    "has was were are can section story entry part bit thing about please "
    "change edit update remove delete take out off say says said that this "
    "your you".split()
)


def _terms(text: str) -> set[str]:
    return {w for w in _WORD_RE.findall((text or "").lower()) if w not in _STOPWORDS}


def _titles(sections: list[dict]) -> str:
    return ", ".join(f'"{s.get("title") or s.get("page_id")}"' for s in sections)


def _resolve_section(db, uid, section: str) -> tuple[dict | None, str | None]:
    """Find the one story section ``section`` names, among the caller's own.

    Returns ``(section_dict, None)`` on a confident single match, or
    ``(None, message)`` — a user-facing line naming the available sections —
    when there's nothing to match, the phrase is empty, or it's ambiguous."""
    sections = (story.get_story(db, uid) or {}).get("sections") or []
    if not sections:
        return None, "you don't have any story sections yet for me to change"
    q = (section or "").strip().lower()
    if not q:
        return None, "tell me which part of your story you mean and I'll change it"

    # 1) exact page_id or title.
    for s in sections:
        if str(s.get("page_id") or "").lower() == q:
            return s, None
    exact_title = [s for s in sections if str(s.get("title") or "").lower() == q]
    if len(exact_title) == 1:
        return exact_title[0], None

    # 2) a title that contains the phrase, or vice-versa.
    sub = [
        s
        for s in sections
        if q in str(s.get("title") or "").lower()
        or str(s.get("title") or "").lower() in q
    ]
    if len(sub) == 1:
        return sub[0], None

    # 3) keyword overlap against title / page_type / body — pick a clear winner.
    qterms = _terms(q)
    scored: list[tuple[int, dict]] = []
    for s in sections:
        hay = _terms(
            f"{s.get('title') or ''} {s.get('page_type') or ''} {s.get('body') or ''}"
        )
        score = len(qterms & hay)
        if score:
            scored.append((score, s))
    scored.sort(key=lambda t: t[0], reverse=True)
    if len(scored) == 1 or (
        len(scored) >= 2 and scored[0][0] > scored[1][0]
    ):
        return scored[0][1], None

    return None, (
        "I'm not sure which part you mean — your story has these sections: "
        f"{_titles(sections)}. Which one?"
    )


_EDIT_DECL = {
    "name": "edit_story_entry",
    "description": (
        "Rewrite the wording of ONE section of the user's own story/wiki when "
        "they ask you to change or correct what it says. YOU CAN do this from "
        "an ordinary chat — you no longer need them to open the story editor. "
        "`section` names the part to change (its title, topic, or a few words "
        "from it); `new_text` is the full replacement wording for that section. "
        "The change is saved to history, so it can always be reverted. After "
        "it succeeds, tell them in one line what you changed."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {
                "type": "string",
                "description": (
                    "which story section to change — its title, topic, or a "
                    "short phrase from it (e.g. 'career', 'about my family')"
                ),
            },
            "new_text": {
                "type": "string",
                "description": "the full replacement wording for that section",
            },
        },
        "required": ["section", "new_text"],
    },
}

_REMOVE_DECL = {
    "name": "remove_story_entry",
    "description": (
        "Take ONE section off the user's own story/wiki when they ask you to "
        "remove or delete it. YOU CAN do this from an ordinary chat. It is a "
        "soft removal: the section is hidden from their story and public "
        "profile, you keep it in your own notes, and it can always be brought "
        "back — so it is safe and reversible. `section` names the part to "
        "remove (its title, topic, or a few words from it). After it "
        "succeeds, confirm to them in one line exactly what you removed."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "section": {
                "type": "string",
                "description": (
                    "which story section to remove — its title, topic, or a "
                    "short phrase from it"
                ),
            }
        },
        "required": ["section"],
    },
}


def _bind_edit(db, uid: str) -> Callable[..., str]:
    def edit_story_entry(section: str = "", new_text: str = "") -> str:
        new_text = (new_text or "").strip()
        if not new_text:
            return "give me the new wording and I'll update that section"
        s, err = _resolve_section(db, uid, section)
        if err:
            return err
        page_id = str(s.get("page_id"))
        title = s.get("title") or page_id
        try:
            # Commit the current wording to history first, so this edit is
            # revertible to exactly what it said before.
            story._snapshot_section(
                db, uid, page_id, story.AUTHOR_USER, f"before chat edit of {title}"
            )
            story.save_section(
                db, uid, page_id, new_text, allow_hidden_changes=True
            )
        except KeyError:
            return "that section isn't there anymore"
        return f'updated your "{title}" — tell me if you want the old wording back'

    return edit_story_entry


def _bind_remove(db, uid: str) -> Callable[..., str]:
    def remove_story_entry(section: str = "") -> str:
        s, err = _resolve_section(db, uid, section)
        if err:
            return err
        page_id = str(s.get("page_id"))
        title = s.get("title") or page_id
        try:
            story.remove_section(db, uid, page_id)
        except KeyError:
            return "that section isn't there anymore"
        return (
            f'removed "{title}" from your story — it\'s hidden now, '
            "just say the word and I'll bring it back"
        )

    return remove_story_entry


SKILLS: list[Skill] = [
    Skill(declaration=_EDIT_DECL, bind=_bind_edit),
    Skill(declaration=_REMOVE_DECL, bind=_bind_remove),
]
