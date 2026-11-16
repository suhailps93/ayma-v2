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


# Meta / non-answer sentinels that must never render as a story bullet
# (Scout 2449 blocker 3: "skipped", "addressed" leaked through as bullets).
_META_SENTINELS = {"skipped", "addressed", "n/a", "none", "prefer not to say"}

# node ids whose answer is really a date, not prose (they are `narrative` kind
# in the tree but carry a date value).
_DATE_NODE_IDS = {"date_of_birth"}


def _format_value(node: GraphNode, raw) -> str:
    """Humanise a structured value: booleans → Yes/No, dates → a plain date,
    everything else → trimmed text (Scout 2449 blocker 2 — raw timestamps and
    raw `true` leaked into story/public)."""
    if isinstance(raw, bool):
        return "Yes" if raw else "No"
    if node.answer_type == "bool":
        s = str(raw).strip().lower()
        if s in ("true", "yes", "1"):
            return "Yes"
        if s in ("false", "no", "0"):
            return "No"
    if node.id == "date_of_birth":
        # public as AGE only — the raw birthdate never renders (founder, Nov 15)
        age = _age_from(raw)
        return str(age) if age is not None else ""
    if node.id in _DATE_NODE_IDS or _looks_like_timestamp(raw):
        return _date_only(raw)
    if isinstance(raw, (list, tuple)):
        return ", ".join(str(x) for x in raw if str(x).strip())
    return str(raw).strip()


def _looks_like_timestamp(raw) -> bool:
    s = str(raw)
    # "1993-03-05 20:00:00+00:00" / ISO with a time component
    return len(s) >= 19 and s[:4].isdigit() and s[4:5] == "-" and (" " in s or "T" in s)


def _date_only(raw) -> str:
    s = str(raw).strip()
    # take the date part before a space or 'T'
    for sep in (" ", "T"):
        if sep in s:
            s = s.split(sep, 1)[0]
            break
    return s


def _age_from(raw):
    """Age in whole years from a birthdate value, or None if unparseable. The
    raw birthdate itself is never shown — only this derived age."""
    import datetime as _dt

    d = _date_only(raw)
    try:
        born = _dt.date.fromisoformat(d[:10])
    except (ValueError, TypeError):
        return None
    today = _dt.date.today()
    years = today.year - born.year - ((today.month, today.day) < (born.month, born.day))
    return years if 0 < years < 130 else None


def _answer_text(node: GraphNode) -> str:
    """A node's answer as display text. Narrative answers are the user's own
    words; a structured answer is labelled by its prompt. Meta/non-answer
    sentinels and empty values render nothing."""
    # An image node (design §6) renders as Ayma's read of the image, never the
    # raw storage URL — the url is for display, the read is the prose fact.
    if node.answer_type == "image":
        return (node.image_read or "").strip()
    a = node.answer
    if a is None:
        return ""
    if isinstance(a, str) and a.strip().lower() in _META_SENTINELS:
        return ""  # a skipped/addressed placeholder is not a bullet
    text = _format_value(node, a)
    if not text or text.strip().lower() in _META_SENTINELS:
        return ""
    # Emergent nodes (migrated story bullets, off-script facts) carry the
    # content itself as their prompt, so they render verbatim — never
    # "<text>: <text>". Narrative answers likewise render verbatim.
    if node.emergent or (node.answer_type == "narrative" and node.id not in _DATE_NODE_IDS):
        return text
    return f"{node.prompt}: {text}"


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


# Report-linked content (appearance / web-findings) has its own report screens
# and is excluded from the Your Story + public-profile renders, matching the wiki
# ``story_common.REPORT_LINKED_PAGE_IDS`` exclusion. It is NOT excluded from the
# persona / grounding renders (Ayma and the match report still see it).
_REPORT_PAGE_TYPES = frozenset(
    {"web_findings", "face_analysis", "body_analysis", "appearance", "physical_profile"}
)


def _sections_with_bullets(
    graph: dict[str, GraphNode],
    keep: set[str],
    *,
    drop_report_nodes: bool = False,
) -> dict[str, list[dict]]:
    by_section: dict[str, list[dict]] = {}
    seen_texts: set[str] = set()
    for n in _ordered_nodes(graph):
        if not _is_renderable(n):
            continue
        if drop_report_nodes and node_page_type(n) in _REPORT_PAGE_TYPES:
            continue
        bullets = _node_bullets(n, keep)
        deduped = []
        for b in bullets:
            norm = " ".join(b["text"].casefold().split())
            if not norm or norm in seen_texts:
                continue
            seen_texts.add(norm)
            deduped.append(b)
        if deduped:
            by_section.setdefault(n.section, []).extend(deduped)
    return by_section


def story_sections(graph: dict[str, GraphNode]) -> dict:
    """Your Story as a bullet list per canonical section (public + private;
    Ayma-only is never shown). Same shape as ``profile_bullets.get_bullets``:
    ``{"sections": [{page_type, title, subtitle, order, page_id, bullets, empty,
    has_ai_only}], "visibilities": [public, private]}``. Every canonical section
    appears (empty ones carry an empty bullet list, for the editor's "+")."""
    keep = {_VIS_PUBLIC, _VIS_PRIVATE}
    by_section = _sections_with_bullets(graph, keep, drop_report_nodes=True)
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
    by_section = _sections_with_bullets(graph, keep, drop_report_nodes=True)
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


# --- grounding block (the graph-native read_wiki_context) ------------------

# Live-written meta content that has no question-tree section of its own is
# homed as emergent nodes under a stable id PREFIX; this maps the prefix back to
# the wiki page_type the context-diet filters (``context_opt.CORE_PAGE_TYPES`` /
# ``ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT`` / ``wiki_include_types``) name, so
# the grounding block keeps grouping and filtering by page_type exactly as the
# wiki read did. Order matters: the most specific prefix is matched first.
_META_PREFIX_PAGE_TYPE: tuple[tuple[str, str], ...] = (
    ("emergent.steering.", "steering"),
    ("emergent.interaction.", "interactions"),
    ("emergent.assess.", "assessment"),
    ("emergent.webfind.", "web_findings"),
    ("emergent.appearance.", "appearance"),
)

# A live skill writer homes its compiled report at ``emergent.skill.<page_type>``;
# the page_type is the id suffix (``physical-profile`` → the "appearance" family).
_SKILL_PREFIX = "emergent.skill."
_SKILL_SUFFIX_PAGE_TYPE = {"physical-profile": "appearance", "physical_profile": "appearance"}

# The meta page_types, in the order they trail the canonical sections in the
# grounding block (assessment is normally filtered out by the caller).
_META_PAGE_TYPE_ORDER = (
    "steering",
    "interactions",
    "web_findings",
    "face_analysis",
    "body_analysis",
    "appearance",
    "assessment",
)


def node_page_type(node: GraphNode) -> str:
    """The wiki-style page_type a node maps to for the context-diet filters:
    its id-prefix for live-written meta content (steering/interactions/
    assessment/web_findings/appearance), else its question-tree section (which is
    the canonical wiki page_type verbatim)."""
    nid = node.id or ""
    if nid.startswith(_SKILL_PREFIX):
        suffix = nid[len(_SKILL_PREFIX):]
        return _SKILL_SUFFIX_PAGE_TYPE.get(suffix, suffix)
    for prefix, pt in _META_PREFIX_PAGE_TYPE:
        if nid.startswith(prefix):
            return pt
    return node.section


def _grounding_label(page_type: str) -> str:
    try:
        if page_type in question_tree.section_meta():
            return question_tree.section_title(page_type)
    except Exception:  # noqa: BLE001
        pass
    return page_type.replace("_", " ").title()


def grounding_block(
    graph: dict[str, GraphNode],
    *,
    max_chars: int,
    include_page_types: Iterable[str] | None = None,
    exclude_page_types: Iterable[str] | None = None,
    include_ayma_only: bool = True,
) -> str:
    """The user's grounding context as one prose block — the graph-native
    replacement for ``wiki_query.read_wiki_context``. Groups renderable nodes by
    their wiki-style page_type (:func:`node_page_type`), honours the same
    ``include_page_types`` / ``exclude_page_types`` filters the wiki read took,
    and truncates at ``max_chars``. ``include_ayma_only`` folds in Ayma-only
    nodes (the standing chat/voice grounding sees Ayma's own knowledge; a
    viewer-facing caller passes False). Empty string when nothing renders —
    exactly as the wiki read returned ``""`` for a user with no pages."""
    keep = {_VIS_PUBLIC, _VIS_PRIVATE}
    if include_ayma_only:
        keep = keep | {_VIS_AI_ONLY}
    inc = set(include_page_types) if include_page_types is not None else None
    exc = set(exclude_page_types) if exclude_page_types else set()

    by_pt: dict[str, list[dict]] = {}
    seen_texts: set[str] = set()
    for n in _ordered_nodes(graph):
        if not _is_renderable(n):
            continue
        pt = node_page_type(n)
        if inc is not None and pt not in inc:
            continue
        if pt in exc:
            continue
        deduped = []
        for b in _node_bullets(n, keep):
            norm = " ".join(b["text"].casefold().split())
            if not norm or norm in seen_texts:
                continue
            seen_texts.add(norm)
            deduped.append(b)
        if deduped:
            by_pt.setdefault(pt, []).extend(deduped)

    if not by_pt:
        return ""

    ordered_pts = [pt for pt in question_tree.ordered_page_types() if pt in by_pt]
    ordered_pts += [pt for pt in _META_PAGE_TYPE_ORDER if pt in by_pt and pt not in ordered_pts]

    out = [
        "What you already know about this person, from previous conversations "
        "(your compiled notes — do not read them back verbatim, just talk like "
        "someone who remembers):"
    ]
    used = 0
    for pt in ordered_pts:
        lines = "\n".join(f"- {b['text']}" for b in by_pt[pt])
        block = f"\n### {_grounding_label(pt)}\n{lines}"
        if used + len(block) > max_chars:
            break
        out.append(block)
        used += len(block)
    return "\n".join(out) if len(out) > 1 else ""


def persona_sections(
    graph: dict[str, GraphNode],
    *,
    public_only: bool = False,
    include_ayma_only: bool = False,
) -> list[dict]:
    """The persona as a list of ``{title, body}`` pages, one per non-empty
    section in section order — the shape ``practice_core.PersonaContext.pages``
    takes (its ``to_prompt_block`` renders each as ``[title]\\nbody``). Same
    visibility keep-sets as :func:`persona_prose`:

    - ``public_only`` → the viewer-visible (public) persona of another member.
    - default → the owner's own persona (public + private).
    - ``include_ayma_only`` → also fold in Ayma-only knowledge (the owner's own
      agent, which may read everything about itself)."""
    if public_only:
        keep = {_VIS_PUBLIC}
    elif include_ayma_only:
        keep = {_VIS_PUBLIC, _VIS_PRIVATE, _VIS_AI_ONLY}
    else:
        keep = {_VIS_PUBLIC, _VIS_PRIVATE}

    by_section = _sections_with_bullets(graph, keep)
    pages: list[dict] = []
    for pt in question_tree.ordered_page_types():
        bullets = by_section.get(pt, [])
        if not bullets:
            continue
        body = "\n".join(b["text"] for b in bullets)
        pages.append({"title": question_tree.section_title(pt), "body": body})
    return pages
