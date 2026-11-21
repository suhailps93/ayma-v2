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

import ast
import json
from typing import Iterable

import person_graph as pg
import question_tree
from person_graph import GraphNode, NodeState, Visibility


def _looks_like_raw_dump(text: str) -> bool:
    """True when ``text`` is a raw dict / JSON blob rather than human prose — a
    whole-value ``{...}`` dict dump (or a ``[{...}, …]`` list of dicts), the kind
    of structured scaffolding (``created_at``/``digest``/``web_image_stats`` …)
    that must NEVER surface as a node's rendered text (founder Nov 20: a report
    node's detail panel dumped the raw digest dict). A plain list of scalars or
    ordinary prose that merely contains a bracket is NOT flagged."""
    s = (text or "").strip()
    if len(s) < 2 or s[0] not in "{[" or s[-1] not in "}]":
        return False
    for parse in (ast.literal_eval, json.loads):
        try:
            v = parse(s)
        except (ValueError, SyntaxError, TypeError, MemoryError, RecursionError):
            continue
        if isinstance(v, dict):
            return True
        if isinstance(v, list) and any(isinstance(x, dict) for x in v):
            return True
    return False

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
    if isinstance(raw, dict):
        # A dict value is structured scaffolding, never a human fact — never dump
        # its repr (founder Nov 20). The node_display_text guard also catches a
        # dict that reaches here as a string; this stops it at the source.
        return ""
    if isinstance(raw, (list, tuple)):
        # Join only the scalar elements — a list that holds dicts is structured,
        # so its dict members are dropped rather than repr-dumped.
        return ", ".join(
            str(x).strip()
            for x in raw
            if not isinstance(x, (dict, list, tuple)) and str(x).strip()
        )
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
    # A report node (reports-as-nodes, founder Nov 16) carries a full report's
    # structured payload as its ``answer`` (a dict) purely so the report screen
    # can be rebuilt from the graph — it is scaffolding, never a prose fact, so
    # it renders nothing in story / public / grounding / persona. The human
    # findings reach the person model through the per-section grounding nodes.
    if node.answer_type == "report_doc":
        return ""
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


def node_display_text(node: GraphNode) -> str:
    """Public accessor for a node's display text — the Node Visualiser (tree
    render) reuses the exact same humanisation the story/public bullets use, so
    one node has one rendering everywhere (the whole point of the visualiser
    chunk). For a standard field the label is carried separately
    (``standard_field_label``) so the client formats "Label: value"; this returns
    the bare value in that case.

    RENDER GUARD (founder Nov 20): the result is NEVER a raw dict / JSON dump —
    if the humanised text still looks like structured scaffolding (an un-migrated
    report lump, a node whose answer is a dict), it falls back to the node's
    human ``gist``, else nothing (the client then shows the node's label). So a
    node detail panel can never dump raw JSON, even for an un-migrated node."""
    text = _node_display_text_raw(node)
    # Fall back to the human gist when the humanised text is still a raw dump, or
    # when it came out empty only because the answer was a dict (a report lump
    # whose answer is structured). ``report_doc`` nodes stay deliberately empty
    # (non-rendering scaffolding) — never resurface their gist.
    structured_empty = (
        not text
        and node.answer_type != "report_doc"
        and isinstance(getattr(node, "answer", None), dict)
    )
    if _looks_like_raw_dump(text) or structured_empty:
        gist = str(getattr(node, "gist", "") or "").strip()
        return gist if (gist and not _looks_like_raw_dump(gist)) else ""
    return text


def _node_display_text_raw(node: GraphNode) -> str:
    if node.standard:
        a = node.answer
        if a is None:
            return ""
        if isinstance(a, str) and a.strip().lower() in _META_SENTINELS:
            return ""
        return _format_value(node, a)
    return _answer_text(node)


def is_renderable(node: GraphNode) -> bool:
    """Public alias — a node carries content (an answer or a child)."""
    return _is_renderable(node)


# --- standard-fact restatement matching (zero-duplicates, founder build 2488) --
#
# A STANDARD node (Name, Age, Gender, Location, Interested in, Ethnic & cultural
# origin) renders as its own labelled row. The defect: another node in the same
# section restates the same fact as a plain bullet — the standard node
# ``ethnic_cultural_origin`` (South Asian) AND an editor bullet "Ethnic and
# cultural origin: South Asian", or "Age: 33" next to the Age row. These helpers
# are the ONE place both the tree render (suppress the restating bullet) and the
# write paths (never MINT one) decide "does this text restate that standard
# fact", so the two can never disagree. High precision: a restatement is the
# bare value, or the label+value content tokens exactly (so "Ethnic & cultural
# origin: South Asian" and "Ethnic and cultural origin: South Asian" match, past
# the ``&``/``and`` difference, while a longer distinct sentence does not).


def standard_fact_forms(node: GraphNode) -> tuple[str, frozenset[str]]:
    """``(value_norm, labelvalue_tokens)`` for a STANDARD ``node`` — the two
    forms a restating node's text is matched against: the normalized bare value
    and the content-token set of ``"<label> <value>"``. ``("", frozenset())``
    when the standard node has no renderable value."""
    import person_graph_index as index_mod

    val = node_display_text(node)
    if not val:
        return "", frozenset()
    label = node.standard_field_label or node.prompt or ""
    return index_mod.normalize_text(val), index_mod.token_set(f"{label} {val}")


def text_restates_standard_fact(
    value_norm: str, labelvalue_tokens: frozenset[str], text: str
) -> bool:
    """True when ``text`` restates the standard fact described by ``value_norm``
    / ``labelvalue_tokens`` (from :func:`standard_fact_forms`): its normalized
    text equals the bare value, or its content tokens equal the label+value
    tokens. Genuine restatements only — never a merely overlapping sentence."""
    import person_graph_index as index_mod

    if not text:
        return False
    if value_norm and index_mod.normalize_text(text) == value_norm:
        return True
    if labelvalue_tokens and index_mod.token_set(text) == labelvalue_tokens:
        return True
    # A "<label>: <value>" bullet whose OWN label wording differs from the
    # standard field's canonical label (NOTE 252 leg 28: an editor bullet
    # "Gender identity: Man" beside the standard Gender row "Man" — the import's
    # label "Gender identity" is not the field label "Gender", so neither the
    # bare-value nor the label+value token check above fires and the restatement
    # survived). Match when the text after the FIRST colon normalises exactly to
    # the bare value: high precision — a longer distinct sentence never has a
    # colon tail equal to the bare value, and the caller restricts the compare to
    # the same section's standard facts.
    if value_norm and ":" in text:
        tail = text.split(":", 1)[1]
        if index_mod.normalize_text(tail) == value_norm:
            return True
    return False


def standard_restatement_id(
    graph: dict[str, GraphNode], text: str, section: str
) -> str | None:
    """The id of a STANDARD node in ``section`` whose fact ``text`` restates, or
    ``None``. The write-time guard (never mint a bullet that restates a standard
    fact) and the data-merge tool both call this; the tree render uses the
    per-form helpers directly (it is surface/visibility-aware). Restricted to the
    same section — a fact only collides with the labelled row it sits beside."""
    if not text:
        return None
    for n in graph.values():
        if not getattr(n, "standard", False) or n.section != section:
            continue
        vn, lv = standard_fact_forms(n)
        if text_restates_standard_fact(vn, lv, text):
            return n.id
    return None


def _editor_restated_standard(
    graph: dict[str, GraphNode], node: GraphNode
) -> GraphNode | None:
    """The canonical STANDARD node whose fact ``node`` (an editor-owned emergent
    bullet) restates, or ``None``. Unlike :func:`standard_restatement_id` this is
    deliberately NOT section-restricted: a header/structured-fact import lands as
    an ``emergent.editor.<section>.*`` duplicate that often sits in the wrong
    section — e.g. an ``emergent.editor.identity.*`` "Interested in: Women"
    duplicate of the ``looking_for`` ``target_match_genders`` fact, or an
    "Age: 29" duplicate of the ``identity`` ``date_of_birth`` fact — so the public
    render must recognise it across sections to suppress or relocate it (NOTE 263:
    the id-based ``HEADER_FIELD_IDS`` drop never matched these duplicates, so they
    leaked into About Me). Scoped to emergent, non-standard nodes so a genuine
    narrative bullet is never matched — the text test
    (:func:`text_restates_standard_fact`) is high precision (the bare value, the
    label+value token set, or a ``label: value`` tail equal to the value)."""
    if getattr(node, "standard", False) or not getattr(node, "emergent", False):
        return None
    text = _answer_text(node)
    if not text:
        return None
    for other in graph.values():
        if other is node or not getattr(other, "standard", False):
            continue
        vn, lv = standard_fact_forms(other)
        if text_restates_standard_fact(vn, lv, text):
            return other
    return None


def _public_fact_placement(
    graph: dict[str, GraphNode], node: GraphNode
) -> tuple[str, str | None]:
    """Where ``node`` renders on a PUBLIC surface that sits under the photo
    header (name/age/location). Returns ``("drop", None)``, ``("move", section)``
    or ``("keep", None)`` — the single "is this a header/duplicate fact?" decision
    both the id-keyed canonical nodes AND their editor-identity duplicates flow
    through (NOTE 263):

    - a HEADER fact (name / age / location) — the canonical seed node
      (``HEADER_FIELD_IDS``) OR an editor-owned emergent duplicate of one — is
      DROPPED: the photo header already shows it (founder build 2509);
    - an editor-owned emergent duplicate of a NON-header standard fact is SURFACE-
      AWARE (NOTE 264). When the canonical row itself renders publicly it is the
      single source for the fact — it already shows in its own section — so the
      duplicate is DROPPED wherever it sits (this is why an ``Interested in: …``
      editor bullet in About Me disappears: the canonical ``target_match_genders``
      row renders it under *What I'm Looking For*). Only when the canonical is
      PRIVATE (it contributes no public bullet) is this public editor bullet the
      ONLY public copy of the fact: it is then MOVED to the canonical section if it
      sits in the wrong one (so *What I'm Looking For* still appears), else KEPT —
      otherwise the fact would silently vanish from the public profile;
    - everything else is KEPT where it is.

    The two public surfaces format a standard row differently (the Living Report
    inlines ``label: value``, the Node-Visualiser keeps label and value apart), so
    textual de-dup alone cannot keep them consistent — routing BOTH through this
    one predicate is what makes About Me and *What I'm Looking For* match on each."""
    if node.id in pg.HEADER_FIELD_IDS:
        return "drop", None
    std = _editor_restated_standard(graph, node)
    if std is None:
        return "keep", None
    if std.id in pg.HEADER_FIELD_IDS:
        return "drop", None
    # A duplicate of a non-header standard fact. When the canonical row renders
    # publicly it is the single source, so drop the duplicate wherever it sits.
    # Only a PRIVATE canonical makes this public bullet the sole public copy:
    # relocate it to the canonical section (or keep it) so the fact survives.
    if _story_vis(std.visibility) == _VIS_PUBLIC:
        return "drop", None
    if std.section != node.section:
        return "move", std.section
    return "keep", None


def public_fact_placement(
    graph: dict[str, GraphNode], node: GraphNode
) -> tuple[str, str | None]:
    """Public accessor for :func:`_public_fact_placement` — where ``node`` lands
    on a PUBLIC surface: ``("keep", None)``, ``("drop", None)`` or
    ``("move", section)``. The public-edit SAVE path uses it to tell a node the
    public-edit view HID or RELOCATED (``"drop"`` / ``"move"``) from one the user
    actually removed, so a filtered save never prunes a hidden duplicate (NOTE
    279 defect 4)."""
    return _public_fact_placement(graph, node)


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
        bullet = {"id": node.id, "text": text, "visibility": node_vis}
        # An image node carries the Firebase Storage link so the client can show
        # the photo itself; the bullet ``text`` is Ayma's read of it. The url is
        # a reference the viewer opens, never the bytes.
        if node.answer_type == "image" and isinstance(node.answer, str):
            bullet["image_url"] = node.answer
        out.append(bullet)
    for i, child in enumerate(node.children):
        cv = _story_vis(child.visibility)
        if child.text.strip() and cv in keep:
            out.append(
                {"id": f"{node.id}#c{i}", "text": child.text.strip(), "visibility": cv}
            )
    return out


def _node_order_key(n: GraphNode, graph: dict[str, GraphNode]) -> tuple:
    """Section-then-level-then-id order, except an image node homed under a fact
    in the same section renders *immediately after that fact's bullet* instead of
    sinking to the end of the section by its deeper level — "each photo sits with
    its fact" (founder Nov 16; NOTE 235 defect 3 render). Scoped to image nodes so
    all other ordering is unchanged."""
    if getattr(n, "answer_type", "") == "image" and getattr(n, "parent", ""):
        parent = graph.get(n.parent)
        if parent is not None and parent.section == n.section:
            return (
                question_tree.section_order(parent.section),
                parent.level,
                parent.id,
                1,
                n.id,
            )
    return (question_tree.section_order(n.section), n.level, n.id, 0, n.id)


def _ordered_nodes(graph: dict[str, GraphNode]) -> list[GraphNode]:
    return sorted(graph.values(), key=lambda n: _node_order_key(n, graph))


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
    drop_header_fields: bool = False,
) -> dict[str, list[dict]]:
    by_section: dict[str, list[dict]] = {}
    seen_texts: set[str] = set()
    for n in _ordered_nodes(graph):
        if not _is_renderable(n):
            continue
        if drop_report_nodes and node_page_type(n) in _REPORT_PAGE_TYPES:
            continue
        # The public profile sits under a photo header that already shows
        # name/age/location, so the public render drops those standard rows to
        # avoid showing each twice, and relocates a mis-sectioned structured
        # duplicate (e.g. an "Interested in: …" editor bullet) to its canonical
        # section — the same placement rule the Node-Visualiser tree applies on
        # its public surface. Both the canonical seed nodes AND their editor
        # duplicates flow through one predicate so an id-keyed drop can't miss a
        # duplicate (NOTE 263). Owner surfaces (Your Story, persona/grounding)
        # have no photo header and keep the rows.
        section = n.section
        if drop_header_fields:
            kind, moved = _public_fact_placement(graph, n)
            if kind == "drop":
                continue
            if kind == "move" and moved:
                section = moved
        bullets = _node_bullets(n, keep)
        deduped = []
        for b in bullets:
            # An image node is distinct content (it carries a photo), never a
            # duplicate of a text bullet — keep it even if its read matches a
            # fact's text (e.g. the fact it is homed with).
            if b.get("image_url"):
                deduped.append(b)
                continue
            norm = " ".join(b["text"].casefold().split())
            if not norm or norm in seen_texts:
                continue
            seen_texts.add(norm)
            deduped.append(b)
        if deduped:
            by_section.setdefault(section, []).extend(deduped)
    return by_section


def story_sections(graph: dict[str, GraphNode], *, drop_header_fields: bool = False) -> dict:
    """Your Story as a bullet list per canonical section (public + private;
    Ayma-only is never shown). Same shape as ``profile_bullets.get_bullets``:
    ``{"sections": [{page_type, title, subtitle, order, page_id, bullets, empty,
    has_ai_only}], "visibilities": [public, private]}``. Every canonical section
    appears (empty ones carry an empty bullet list, for the editor's "+").

    ``drop_header_fields`` (default off) applies the public placement rule (the
    same one :func:`public_sections` uses) to the PUBLIC bullets — header facts
    shown under the photo header are dropped and a mis-sectioned structured
    duplicate (e.g. "Interested in: …") relocates to its canonical section.
    Private bullets are untouched (``_public_fact_placement`` returns "keep" for
    them), so an owner surface keeps them. Off = Your Story (keeps the header
    rows, which have no photo header there)."""
    keep = {_VIS_PUBLIC, _VIS_PRIVATE}
    by_section = _sections_with_bullets(
        graph, keep, drop_report_nodes=True, drop_header_fields=drop_header_fields
    )
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


def public_edit_sections(graph: dict[str, GraphNode]) -> dict:
    """The data model for the PUBLIC-ONLY profile edit view (``My public
    profile`` → edit). Same shape as :func:`story_sections` — public + private
    bullets per section, so the editor's save round-trip
    (``replace_section_bullets``) still sees the private bullets and never drops
    them — but with the public placement rule applied (``drop_header_fields``),
    so the edit view matches the RENDERED public profile: header facts under the
    photo header are NOT reintroduced as About Me bullets, and the "Interested
    in" node lands under *What I'm Looking For*, not About Me (founder ruling
    Nov 18; Scout NOTE 275). Your Story (:func:`story_sections`) is unchanged."""
    return story_sections(graph, drop_header_fields=True)


def public_sections(graph: dict[str, GraphNode]) -> list[dict]:
    """The public profile: public bullets only, in section order; sections with
    no public bullet are dropped. Same shape as
    ``public_profile.public_bullet_sections``:
    ``[{page_id, page_type, title, bullets: [str, ...]}]``."""
    keep = {_VIS_PUBLIC}
    by_section = _sections_with_bullets(
        graph, keep, drop_report_nodes=True, drop_header_fields=True
    )
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
    # ai_assessment's live graph home (founder Nov 17, part (a)); mapped to the
    # "assessment" page_type so EXCLUDED_FROM_CHAT_CONTEXT keeps Ayma's private
    # judgment OUT of the standing chat/voice grounding. Listed before the older
    # ``emergent.assess.`` (migration-seeded) prefix: longest match first.
    ("emergent.assessment.", "assessment"),
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
        if suffix in _SKILL_SUFFIX_PAGE_TYPE:
            return _SKILL_SUFFIX_PAGE_TYPE[suffix]
        # A per-element skill node homes its findings at
        # ``emergent.skill.<page_type>.<kind>.<n>`` (appearance findings,
        # founder Nov 18) — map the BASE segment to its page_type so grounding /
        # context-diet group them exactly as the old single lump node did.
        base = suffix.split(".", 1)[0]
        return _SKILL_SUFFIX_PAGE_TYPE.get(base, base)
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
