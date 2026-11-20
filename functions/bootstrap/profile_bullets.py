"""Service layer for the bullet editor (``/profile/bullets``).

Presents Your Story as the founder's section → bullets model and writes edits
back through the existing per-section save path (``story_writes``), so the
one-source wiki_pages model, moderation, hidden-span protection, version
snapshots and the public-profile assembly all keep working unchanged.

* Every canonical section (``question_tree.section_meta``) appears, even with
  no page yet — so the editor shows all sections with a "+" and is never an
  empty page, for every user including non-paid ones who never talk to Ayma.
* An existing page is split into bullets at read time (``story_bullets``); no
  migration. A section with more than one page has its pages merged into a
  single canonical section entry with all bullets preserved in order.
* Ayma-only (``ai_only``) bullets are NEVER shown in Your Story — not to the
  public, not even to the owner (founder order, Nov 15 2026: Ayma-only is for
  Ayma alone). The editor/view payload carries only public + private bullets:
  :func:`get_bullets` reads from the ai-only-stripped story view, and
  :func:`save_bullets` re-attaches the page's existing Ayma-only spans so a
  user edit of the visible bullets never destroys content Ayma's own tools and
  context still rely on.
"""

from __future__ import annotations

import logging

import question_tree
import story
import story_bullets
import story_spans
from story_common import AI_ONLY_CLOSE, AI_ONLY_OPEN, VIS_AI_ONLY, VIS_PRIVATE, VIS_PUBLIC

logger = logging.getLogger("ayma.story")


def _preserved_ai_only(db, uid: str, page_id: str) -> str:
    """The page's current Ayma-only spans, serialised back as
    ``{{ai_only}}…{{/ai_only}}`` — re-attached on save so editing the visible
    (public/private) bullets never drops content Ayma keeps for herself.
    Empty when the page is gone or has no Ayma-only content."""
    try:
        _ref, data = story._require_page(db, uid, page_id)
    except KeyError:
        return ""
    body = story._display_body(db, uid, page_id, data)
    return "".join(
        AI_ONLY_OPEN + s["text"] + AI_ONLY_CLOSE
        for s in story_spans.parse_spans(body)
        if s.get("kind") == VIS_AI_ONLY
    )

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


def get_bullets(db, uid: str, *, public_edit: bool = False) -> dict:
    """Every canonical section as a bullet list. Existing pages are split into
    bullets; sections with no page yet come back empty (``page_id`` empty) so
    the editor can show them with a "+". Duplicate pages of the same canonical
    page_type are merged so each canonical type appears exactly once with all
    bullets preserved.

    ``public_edit`` → the PUBLIC-only profile edit view (``GET /profile/bullets``):
    the payload matches the rendered public profile (header facts not shown as
    About Me bullets; "Interested in" grouped under What I'm Looking For — Scout
    NOTE 275, founder ruling Nov 18), while private bullets are still carried so
    the save round-trip never drops them. Off (the person-graph net via
    ``profile_graph``) keeps every row and its raw section."""
    # Person-graph authoritative (design §8.1, NOTE 230): Your Story is a render
    # of the GRAPH, not the frozen wiki. With the flag on, wiki ingest is gated
    # (NOTE 227) so new facts land only in the graph — a volunteered fact becomes
    # a loose emergent node in ``misc`` / Little Extras (NOTE 228). The wiki read
    # below can never surface it; the graph render does. Flag off → the wiki path
    # below runs unchanged (today's behaviour exactly, reversible by the flag).
    from config import CONFIG

    if CONFIG.person_graph_reads:
        import person_graph_source

        graph_story = person_graph_source.story_bullets(db, uid, public_edit=public_edit)
        if graph_story is not None:
            return graph_story
        # graph read failed — fall through to the frozen-wiki read, never blank.
    by_pt: dict[str, dict] = {}
    # get_story is the ai-only-stripped owner view (public + private only, and
    # whole ai_only pages excluded), so Ayma-only content never reaches the
    # client for display (founder order, Nov 15 2026).
    for s in story.get_story(db, uid).get("sections", []):
        pt = s.get("page_type")
        if pt not in question_tree.section_meta():
            continue  # skill pages, steering/interactions, custom — not here
        vis = s.get("visibility") or VIS_PRIVATE
        cur_page_id = s.get("page_id", "")
        bullets = [
            b
            for b in story_bullets.parse_bullets(
                s.get("body") or "", vis, page_id=cur_page_id
            )
            if b["visibility"] != VIS_AI_ONLY  # defensive: never emit Ayma-only
        ]
        canonical_id = pt.replace("_", "-")
        if pt not in by_pt:
            shell = _section_shell(pt)
            shell.update(
                {
                    "page_id": cur_page_id,
                    "bullets": list(bullets),
                    "has_ai_only": False,  # Ayma-only is never shown in Your Story
                    "empty": not bullets,
                }
            )
            by_pt[pt] = shell
        else:
            cur_sec = by_pt[pt]
            if not cur_sec["page_id"]:
                cur_sec["page_id"] = cur_page_id
            elif cur_page_id in (pt, canonical_id) and cur_sec["page_id"] not in (pt, canonical_id):
                cur_sec["page_id"] = cur_page_id

            seen_texts = {b["text"].strip().lower() for b in cur_sec["bullets"]}
            for b in bullets:
                t = b["text"].strip().lower()
                if t and t in seen_texts:
                    continue
                cur_sec["bullets"].append(b)
                if t:
                    seen_texts.add(t)

            cur_sec["empty"] = not cur_sec["bullets"]

    for pt in _CANONICAL:
        if pt in by_pt:
            continue
        shell = _section_shell(pt)
        shell.update({"page_id": "", "bullets": [], "has_ai_only": False, "empty": True})
        by_pt[pt] = shell

    sections = list(by_pt.values())
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections, "visibilities": [VIS_PUBLIC, VIS_PRIVATE]}


def _page_id_to_section(page_id: str) -> str:
    """The canonical section (question-tree page_type) for an editor ``page_id``.
    The editor's page_id is ``page_type.replace("_", "-")`` (``story_sections``),
    so reverse it; fall back to the raw id if that is already a section."""
    if page_id in question_tree.section_meta():
        return page_id
    candidate = page_id.replace("-", "_")
    if candidate in question_tree.section_meta():
        return candidate
    raise ValueError(f"unknown story section for page_id {page_id!r}")


def save_bullets(db, uid: str, page_id: str, bullets: list[dict]) -> dict:
    """Compose an edited bullet list back into an existing section's body and
    save it through the per-section save path (keeps moderation and version
    history). Raises ``KeyError`` if the page is gone.

    The editor only shows and sends public + private bullets, so the composed
    body loses any Ayma-only content — which the user must never destroy. The
    page's existing Ayma-only spans are re-attached before the write, so Ayma's
    own tools/context keep them while the owner never sees them (founder order,
    Nov 15 2026). The per-section save guard then confirms nothing hidden was
    dropped."""
    visible = [b for b in (bullets or []) if b.get("visibility") != VIS_AI_ONLY]
    # Person-graph authoritative: write the edited bullets back to the graph
    # (closing the NOTE 230 Phase-6b gap), not the frozen wiki section page.
    from config import CONFIG

    if CONFIG.person_graph_reads:
        import person_graph_store as pg_store

        section = _page_id_to_section(page_id)
        pg_store.replace_section_bullets(db, uid, section, visible)
        vis = story_bullets.compose_body(visible)["visibility"]
        return {"page_id": page_id, "visibility": vis}
    composed = story_bullets.compose_body(visible)
    vis = composed["visibility"]  # public or private (never ai_only now)
    body = composed["body"]
    preserved = _preserved_ai_only(db, uid, page_id)
    if preserved:
        body = f"{body} {preserved}".strip() if body else preserved
    story.save_section(
        db,
        uid,
        page_id,
        body,
        visibility=vis if vis in (VIS_PUBLIC, VIS_PRIVATE) else None,
    )
    return {"page_id": page_id, "visibility": vis}


def create_bullet_section(db, uid: str, page_type: str, bullets: list[dict]) -> dict:
    """Create a new section for ``page_type`` from the first bullet(s) the user
    adds to a previously-empty section (public/private only — the editor never
    offers Ayma-only)."""
    if page_type not in question_tree.section_meta():
        raise ValueError(f"unknown section: {page_type}")
    visible = [b for b in (bullets or []) if b.get("visibility") != VIS_AI_ONLY]
    from config import CONFIG

    if CONFIG.person_graph_reads:
        import person_graph_store as pg_store

        pg_store.replace_section_bullets(db, uid, page_type, visible)
        vis = story_bullets.compose_body(visible)["visibility"]
        return {"page_id": page_type.replace("_", "-"), "visibility": vis}
    composed = story_bullets.compose_body(visible)
    res = story.create_section(db, uid, page_type, composed["body"], composed["visibility"])
    return {"page_id": res["page_id"], "visibility": composed["visibility"]}
