"""Service layer for the bullet editor (``/profile/bullets``).

Presents Your Story as the founder's section → bullets model and writes edits
back through the existing per-section save path (``story_writes``), so the
one-source wiki_pages model, moderation, hidden-span protection, version
snapshots and the public-profile assembly all keep working unchanged.

* Every canonical section (``question_tree.section_meta``) appears, even with
  no page yet — so the editor shows all sections with a "+" and is never an
  empty page, for every user including non-paid ones who never talk to Ayma.
* An existing page is split into bullets at read time (``story_bullets``); no
  migration. A section with more than one page shows one entry per page
  (lossless), each editable on its own.
* Ayma-only (``ai_only``) spans surface as Ayma-only bullets in the same list.
"""

from __future__ import annotations

import logging

import question_tree
import story
import story_bullets
from story_common import VIS_AI_ONLY, VIS_PRIVATE, VIS_PUBLIC

logger = logging.getLogger("ayma.story")

# The sections the bullet editor covers: the canonical story sections only.
# Ayma's own meta pages (steering/interactions) and the skill report pages
# (web findings, face/body analysis) have their own surfaces and are excluded.
_CANONICAL = tuple(question_tree.ordered_page_types())


def _section_shell(page_type: str) -> dict:
    return {
        "page_type": page_type,
        "title": question_tree.section_title(page_type),
        "subtitle": question_tree.section_subtitle(page_type),
        "order": question_tree.section_order(page_type),
    }


def get_bullets(db, uid: str) -> dict:
    """Every canonical section as a bullet list. Existing pages are split into
    bullets; sections with no page yet come back empty (``page_id`` empty) so
    the editor can show them with a "+"."""
    sections: list[dict] = []
    present: set[str] = set()
    for s in story.get_ai_notes(db, uid).get("sections", []):
        pt = s.get("page_type")
        if pt not in question_tree.section_meta():
            continue  # skill pages, steering/interactions, custom — not here
        present.add(pt)
        vis = s.get("visibility") or VIS_PRIVATE
        bullets = story_bullets.parse_bullets(
            s.get("edit_body") or s.get("body") or "",
            vis,
            page_id=s.get("page_id", ""),
        )
        shell = _section_shell(pt)
        shell.update(
            {
                "page_id": s.get("page_id", ""),
                "bullets": bullets,
                "has_ai_only": any(b["visibility"] == VIS_AI_ONLY for b in bullets),
                "empty": not bullets,
            }
        )
        sections.append(shell)
    for pt in _CANONICAL:
        if pt in present:
            continue
        shell = _section_shell(pt)
        shell.update({"page_id": "", "bullets": [], "has_ai_only": False, "empty": True})
        sections.append(shell)
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections, "visibilities": [VIS_PUBLIC, VIS_PRIVATE, VIS_AI_ONLY]}


def save_bullets(db, uid: str, page_id: str, bullets: list[dict]) -> dict:
    """Compose an edited bullet list back into an existing section's body and
    save it through the per-section save path (keeps moderation, hidden-span
    protection and version history). Raises ``KeyError`` if the page is gone and
    ``ValueError`` if the edit would drop a hidden Ayma-only passage."""
    composed = story_bullets.compose_body(bullets)
    vis = composed["visibility"]
    story.save_section(
        db,
        uid,
        page_id,
        composed["body"],
        visibility=vis if vis in (VIS_PUBLIC, VIS_PRIVATE) else None,
    )
    if vis == VIS_AI_ONLY:
        # an all-Ayma-only section: save_section won't set ai_only, so set it.
        story.set_section_ai_only(db, uid, page_id)
    return {"page_id": page_id, "visibility": vis}


def create_bullet_section(db, uid: str, page_type: str, bullets: list[dict]) -> dict:
    """Create a new section for ``page_type`` from the first bullet(s) the user
    adds to a previously-empty section."""
    if page_type not in question_tree.section_meta():
        raise ValueError(f"unknown section: {page_type}")
    composed = story_bullets.compose_body(bullets)
    res = story.create_section(db, uid, page_type, composed["body"], composed["visibility"])
    return {"page_id": res["page_id"], "visibility": composed["visibility"]}
