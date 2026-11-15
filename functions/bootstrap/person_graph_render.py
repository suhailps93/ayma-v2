"""Renders over the person graph.

The story, public profile, and the prose the sims / match report consume are
all **renders of the graph**, not separate stores (design §1, §8.1). This
module walks the effective graph (``person_graph.GraphNode`` objects) and emits
the same shapes today's wiki-backed renders produce, so consumers can switch
with no change to their own output contract:

- :func:`story_sections` → Your Story (public + private; Ayma-only never shown).
- :func:`public_sections` → the public profile (public bullets only).
- :func:`persona_prose` → the prose block the persona / sims / match report read.

The graph's ``ayma_only`` visibility maps to the story model's ``ai_only`` at
this boundary (the two models name the same thing differently). Byte-level
parity with the live wiki is pinned per account in the migration phase; this
module owns the render logic and its structure/visibility/ordering guarantees.
"""

from __future__ import annotations

from typing import Iterable

import person_graph as pg
import question_tree
from person_graph import GraphNode, NodeState, Visibility

# story-model visibility strings (story_common.VIS_*). The graph's ayma_only is
# the story model's ai_only.
_VIS_PUBLIC = "public"
_VIS_PRIVATE = "private"
_VIS_AI_ONLY = "ai_only"

_STORY_VIS = {
    Visibility.PUBLIC: _VIS_PUBLIC,
    Visibility.PRIVATE: _VIS_PRIVATE,
    Visibility.AYMA_ONLY: _VIS_AI_ONLY,
}


def _story_vis(v: Visibility) -> str:
    return _STORY_VIS[v]


def _answer_text(node: GraphNode) -> str:
    """A node's answer as display text. Narrative answers are the user's own
    words; a structured answer is labelled by its prompt."""
    a = node.answer
    if a is None:
        return ""
    if isinstance(a, (list, tuple)):
        a = ", ".join(str(x) for x in a if str(x).strip())
    a = str(a).strip()
    if not a:
        return ""
    if node.answer_type == "narrative":
        return a
    return f"{node.prompt}: {a}"


def _is_renderable(node: GraphNode) -> bool:
    """A node renders as a bullet once it carries content — an answer or at
    least one child. Unanswered seed scaffolding does not render."""
    if node.state is NodeState.PREFER_NOT_TO_SAY:
        return False
    return bool(_answer_text(node)) or bool(node.children)


def _node_bullets(node: GraphNode, keep: set[str]) -> list[dict]:
    """The bullets a single node contributes, filtered to the ``keep`` story
    visibilities. The node's own answer is one bullet; each child is another
    (a child may carry its own visibility)."""
    out: list[dict] = []
    text = _answer_text(node)
    node_vis = _story_vis(node.visibility)
    if text and node_vis in keep:
        out.append({"id": node.id, "text": text, "visibility": node_vis})
    for i, child in enumerate(node.children):
        cv = _story_vis(child.visibility)
        if child.text.strip() and cv in keep:
            out.append(
                {"id": f"{node.id}#c{i}", "text": child.text.strip(), "visibility": cv}
            )
    return out


def _ordered_nodes(graph: dict[str, GraphNode]) -> list[GraphNode]:
    return sorted(
        graph.values(),
        key=lambda n: (question_tree.section_order(n.section), n.level, n.id),
    )


def _sections_with_bullets(
    graph: dict[str, GraphNode], keep: set[str]
) -> dict[str, list[dict]]:
    by_section: dict[str, list[dict]] = {}
    for n in _ordered_nodes(graph):
        if not _is_renderable(n):
            continue
        bullets = _node_bullets(n, keep)
        if bullets:
            by_section.setdefault(n.section, []).extend(bullets)
    return by_section


def story_sections(graph: dict[str, GraphNode]) -> dict:
    """Your Story as a bullet list per canonical section (public + private;
    Ayma-only is never shown). Same shape as ``profile_bullets.get_bullets``:
    ``{"sections": [{page_type, title, subtitle, order, page_id, bullets, empty,
    has_ai_only}], "visibilities": [public, private]}``. Every canonical section
    appears (empty ones carry an empty bullet list, for the editor's "+")."""
    keep = {_VIS_PUBLIC, _VIS_PRIVATE}
    by_section = _sections_with_bullets(graph, keep)
    sections = []
    for pt in question_tree.ordered_page_types():
        bullets = by_section.get(pt, [])
        sections.append(
            {
                "page_type": pt,
                "title": question_tree.section_title(pt),
                "subtitle": question_tree.section_subtitle(pt),
                "order": question_tree.section_order(pt),
                "page_id": pt.replace("_", "-"),
                "bullets": bullets,
                "has_ai_only": False,
                "empty": not bullets,
            }
        )
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections, "visibilities": [_VIS_PUBLIC, _VIS_PRIVATE]}


def public_sections(graph: dict[str, GraphNode]) -> list[dict]:
    """The public profile: public bullets only, in section order; sections with
    no public bullet are dropped. Same shape as
    ``public_profile.public_bullet_sections``:
    ``[{page_id, page_type, title, bullets: [str, ...]}]``."""
    keep = {_VIS_PUBLIC}
    by_section = _sections_with_bullets(graph, keep)
    out: list[dict] = []
    for pt in question_tree.ordered_page_types():
        bullets = [b["text"] for b in by_section.get(pt, [])]
        if not bullets:
            continue
        out.append(
            {
                "page_id": pt.replace("_", "-"),
                "page_type": pt,
                "title": question_tree.section_title(pt),
                "bullets": bullets,
            }
        )
    return out


def persona_prose(
    graph: dict[str, GraphNode],
    *,
    public_only: bool = False,
    include_ayma_only: bool = False,
) -> str:
    """A prose render of the graph for the persona / sims / match report.

    - ``public_only`` → another member's viewer-visible persona (public nodes).
    - default → the owner's own full persona (public + private).
    - ``include_ayma_only`` → also fold in Ayma-only knowledge (for Ayma's own
      grounding, never a viewer-facing surface).
    """
    if public_only:
        keep = {_VIS_PUBLIC}
    elif include_ayma_only:
        keep = {_VIS_PUBLIC, _VIS_PRIVATE, _VIS_AI_ONLY}
    else:
        keep = {_VIS_PUBLIC, _VIS_PRIVATE}

    by_section = _sections_with_bullets(graph, keep)
    blocks: list[str] = []
    for pt in question_tree.ordered_page_types():
        bullets = by_section.get(pt, [])
        if not bullets:
            continue
        lines = "\n".join(f"- {b['text']}" for b in bullets)
        blocks.append(f"## {question_tree.section_title(pt)}\n{lines}")
    return "\n\n".join(blocks)
