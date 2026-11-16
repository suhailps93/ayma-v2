"""Graph-backed read adapters for the live consumers (design §8.1, Phase 5b).

The person graph is the single source of truth; this module lets today's
consumers read it **without changing their math or output shape**. Each adapter
returns exactly what the old store read returned, built from the merged graph
(``seed ⊕ overlay``) instead of the questionnaire / profile / wiki documents.

Gated by ``CONFIG.person_graph_reads`` at the call site (flag off → the old
read path runs unchanged), so the switch is reversible and flag-off is today's
behaviour exactly.

What this swaps for the **deterministic scorer** (``match_deterministic`` via
``matching_skill._load_user``):

* ``qstore`` — the questionnaire subcollection ``{node_id: {"value": …}}`` —
  is rebuilt from the graph's answered seed nodes. The scorer's ``_typed_value``
  reads ``entry["value"]`` exactly as before; migration copied each
  questionnaire value verbatim onto its node, so the values are identical.
* ``profile`` — kept as the real ``profile/main`` doc (its gate fields —
  ``gender`` / ``interested_in`` / location / partner-age / ``completeness`` /
  ``trust_flags`` — are unchanged), **minus the ``qz_*`` questionnaire
  mirrors**, so the graph (not a stale mirror) is authoritative for a
  questionnaire answer once a user edits it through the graph tools.

Node ``weight`` stays the seed weight here (parity). Per-user relative weights
and emergent gates are Phase 5c, layered on top without touching this adapter.
"""

from __future__ import annotations

import logging

import person_graph as pg
import person_graph_store as store

logger = logging.getLogger("ayma.person_graph_source")


def structured_qstore(graph: dict[str, pg.GraphNode]) -> dict[str, dict]:
    """A questionnaire-store-shaped dict ``{node_id: {"value": answer}}`` from
    the answered **seed** nodes of ``graph``. Emergent (off-script) nodes carry
    non-seed ids the scorer never looks up, so they are skipped; narrative nodes
    are included but the scorer ignores narrative kinds. Mirrors the shape
    ``matching_skill._load_user`` built from the ``questionnaire`` subcollection.
    """
    out: dict[str, dict] = {}
    for nid, node in graph.items():
        if node.emergent:
            continue
        if node.answer in (None, ""):
            continue
        entry = {"value": node.answer}
        prov = getattr(node, "provenance", None)
        if prov is not None:
            entry["source"] = prov.value if hasattr(prov, "value") else str(prov)
        out[nid] = entry
    return out


# The core profile fields that today's ``set_profile_field`` /
# ``set_relationship_intent`` tools write to ``profile/main``, mapped from the
# level-1 **seed node id** that now holds the same value in the graph (the
# reverse of ``person_graph_migrate._PROFILE_DERIVABLE`` plus
# ``relationship_intent``, which migration keeps on ``profile/main`` directly).
# Once those writers swap to graph-only, these are the fields that would go
# stale on ``profile/main``; overlaying the graph answer here keeps every
# profile reader authoritative without changing its shape.
_PROFILE_FIELD_NODES = {
    "legal_first_name": "name",
    "date_of_birth": "birthdate",
    "gender_identity": "gender",
    "target_match_genders": "interested_in",
    "primary_location": "location",
    "relationship_intent": "relationship_intent",
}

# The three taste seed nodes, mapped to ``taste_backfill``'s domain keys.
_TASTE_FIELD_NODES = {
    "taste_music": "music",
    "taste_film": "film",
    "taste_food": "food",
}


def profile_overlay(graph: dict[str, pg.GraphNode]) -> dict:
    """``{profile_field: answer}`` for the core profile fields that are answered
    on their level-1 seed node in ``graph``. A blank/unanswered node is skipped,
    so overlaying this onto a ``profile/main`` dict only ever *replaces* a field
    the user has actually set through the graph — never blanks one."""
    out: dict = {}
    for nid, field in _PROFILE_FIELD_NODES.items():
        node = graph.get(nid)
        if node is None:
            continue
        ans = getattr(node, "answer", None)
        if ans in (None, "", [], {}):
            continue
        out[field] = ans
    return out


def hydrate_profile(db, uid: str, profile: dict) -> dict:
    """``profile`` with the graph's core profile answers overlaid on top, so a
    field the user edited through the graph tools takes precedence over a stale
    ``profile/main`` value. Best-effort: on a graph read failure the profile is
    returned unchanged (the old read path's behaviour). Caller gates on
    ``CONFIG.person_graph_reads``."""
    merged = dict(profile or {})
    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: hydrate_profile read failed for %s", uid)
        return merged
    merged.update(profile_overlay(graph))
    return merged


def taste_values(graph: dict[str, pg.GraphNode]) -> dict[str, str]:
    """``{domain: value}`` (music/film/food) from the three taste seed nodes of
    ``graph`` — the graph-native replacement for ``taste_backfill._taste_values``
    reading the questionnaire subcollection. Missing/blank → ``""``."""
    out: dict[str, str] = {d: "" for d in _TASTE_FIELD_NODES.values()}
    for nid, domain in _TASTE_FIELD_NODES.items():
        node = graph.get(nid)
        if node is None:
            continue
        ans = getattr(node, "answer", None)
        out[domain] = " ".join(str(ans or "").split())
    return out


def questionnaire_matches(db, uid: str, qtok: set[str], scorer) -> list[dict]:
    """Recall/fact-source matches over the graph's answered seed nodes — the
    graph-native replacement for ``fact_source._questionnaire_matches`` reading
    the questionnaire subcollection. A graph node carries a provenance *tag*, not
    the verbatim chat line, so matches come back as inexact (``exact: False``,
    empty ``quote``) exactly like a store entry with no provenance block did.
    ``scorer(qtok, text)`` is the caller's token scorer."""
    import question_tree

    out: list[dict] = []
    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: questionnaire_matches read failed for %s", uid)
        return out
    for nid, node in graph.items():
        if getattr(node, "emergent", False):
            continue
        ans = getattr(node, "answer", None)
        if ans in (None, ""):
            continue
        value = str(ans)
        meta = question_tree.node(nid) or {}
        label = str(meta.get("label") or nid)
        score = scorer(qtok, f"{label} {value}")
        if score <= 0:
            continue
        out.append(
            {
                "type": "chat",
                "exact": False,
                "field": label,
                "current_value": value,
                "quote": "",
                "when": "",
                "_score": score,
            }
        )
    return out


def persona(
    db, uid: str, *, public_only: bool = False, include_ayma_only: bool = False
) -> str:
    """A prose render of ``uid``'s graph for a narrative consumer (sims, the
    match report), the graph-native replacement for ``read_wiki_context`` /
    ``public_profile.build`` prose (design §8.1). Best-effort: a read failure
    yields ``""`` (the old reads returned ``""`` on an empty/failed wiki too).

    - default → the owner's own persona (public + private), excluding Ayma-only
      inferred nodes — matching the match report's generic wiki dump, which
      excludes Ayma's assessment page (fed separately via its digest).
    - ``public_only`` → another member's viewer-visible persona (public nodes).
    - ``include_ayma_only`` → also fold in Ayma's own inferred knowledge (never
      a viewer-facing surface)."""
    import person_graph_render as render

    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: persona read failed for %s", uid)
        return ""
    return render.persona_prose(
        graph, public_only=public_only, include_ayma_only=include_ayma_only
    )


def persona_pages(
    db, uid: str, *, public_only: bool = False, include_ayma_only: bool = False
) -> list[dict]:
    """``uid``'s persona as ``[{title, body}]`` pages for
    ``practice_core.PersonaContext.pages`` (sims), from the graph instead of the
    wiki. Best-effort: ``[]`` on a failed/empty graph (the old wiki reads also
    yielded no pages then). Visibility matches :func:`person_graph_render`:
    ``public_only`` for a MATCH persona (public nodes only — the privacy
    boundary is still enforced by the caller's ``public_profile.build`` gate),
    default/``include_ayma_only`` for the owner's own SELF persona."""
    import person_graph_render as render

    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: persona_pages read failed for %s", uid)
        return []
    return render.persona_sections(
        graph, public_only=public_only, include_ayma_only=include_ayma_only
    )


def story_bullets(db, uid: str) -> dict | None:
    """Your Story as the section→bullets model, rendered from the graph — the
    graph-native replacement for the wiki-backed ``profile_bullets.get_bullets``
    (design §8.1: "the story is a render of the graph"). Returns exactly the
    same shape (``{"sections": [...], "visibilities": ["public", "private"]}``,
    every canonical section present, Ayma-only never shown), so the editor reads
    it with no change.

    This is the read half of the story switch: with ``person_graph_reads`` on,
    the wiki is frozen (``wiki_ingest.ingest`` is gated, NOTE 227), so a fact a
    user volunteers now lands only in the graph — a loose emergent node homed in
    ``misc`` / Little Extras (NOTE 228's ``remember`` → ``add_loose_node``). Read
    from the wiki, that fact can never appear; read from the graph, it does
    (NOTE 230). Best-effort: ``None`` on a failed read so the caller falls back
    to the wiki (flag-off behaviour), never a blank story.

    Not covered here (still the frozen-wiki path, flagged for the Phase-6b story
    write-back): editing/creating a bullet still writes ``wiki_pages`` via
    ``profile_bullets.save_bullets`` / ``create_bullet_section`` — those edits
    won't round-trip into this graph-backed read until the write half lands.
    """
    import person_graph_render as render

    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: story_bullets read failed for %s", uid)
        return None
    if not graph:
        return None
    return render.story_sections(graph)


def grounding_context(
    db,
    uid: str,
    *,
    max_chars: int,
    include_page_types=None,
    exclude_page_types=None,
    include_ayma_only: bool = True,
) -> str:
    """The standing chat/voice grounding block, rendered from the graph — the
    graph-native replacement for ``wiki_query.read_wiki_context`` at every
    call site, gated on ``CONFIG.person_graph_reads``. Same output contract (one
    prose block, same page_type grouping, same include/exclude filters,
    truncated at ``max_chars``), so ``compose_system_prompt`` is unchanged. A
    read failure yields ``""`` — exactly what the wiki read returned for a user
    with no pages, so the turn degrades gracefully and never falls back to the
    wiki (keeping wiki_pages out of the flag-on path)."""
    import person_graph_render as render

    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001 - a grounding read must not break the turn
        logger.exception("person_graph_source: grounding read failed for %s", uid)
        return ""
    return render.grounding_block(
        graph,
        max_chars=max_chars,
        include_page_types=include_page_types,
        exclude_page_types=exclude_page_types,
        include_ayma_only=include_ayma_only,
    )


def recall_context(db, uid: str, topic: str, max_chars: int = 3000) -> str:
    """Targeted graph retrieval backing the ``recall(topic)`` tool — the
    graph-native replacement for ``wiki_query.recall_snippets``. Scores every
    renderable node (incl. Ayma-only, since recall grounds Ayma herself) by
    keyword overlap with ``topic`` and returns the best matches' text up to
    ``max_chars``. Keyword scoring only (no LLM/embedding). Never raises."""
    import re

    import person_graph_render as render

    terms = [
        w for w in re.findall(r"[a-z0-9]{3,}", (topic or "").lower())
        if w not in _RECALL_STOPWORDS
    ]
    if not uid or not terms:
        return "No notes found on that topic."
    try:
        graph = store.effective(db, uid)
    except Exception:  # noqa: BLE001 - a recall failure must not break the turn
        logger.exception("person_graph_source: recall read failed for %s", uid)
        return "Could not check the notes right now."

    keep = {"public", "private", "ai_only"}
    scored: list[tuple[int, str, str]] = []
    for node in graph.values():
        bullets = render._node_bullets(node, keep) if render._is_renderable(node) else []
        for b in bullets:
            text = b["text"]
            hay = f"{render.node_page_type(node)} {text}".lower()
            score = sum(hay.count(t) for t in terms)
            if score > 0:
                scored.append((score, render.node_page_type(node), text))
    if not scored:
        return "No notes found on that topic."

    scored.sort(key=lambda p: (-p[0], p[1], p[2]))
    out = ["From your notes on this person:"]
    used = 0
    for _score, pt, text in scored:
        block = f"\n### {render._grounding_label(pt)}\n- {text}"
        if used + len(block) > max_chars:
            if used == 0:
                out.append(block[:max_chars])
            break
        out.append(block)
        used += len(block)
    return "\n".join(out)


_RECALL_STOPWORDS = frozenset(
    "the and for with what who how does did about their they them she her his "
    "him you your this that from have has was were are can tell know like "
    "want said says user ayma".split()
)


# A node whose personal weight reaches this (on the 0–5 tool scale, where 5 is
# "crucial") counts as top-of-budget — a confirmed personal hard filter (§4.3).
# Set here so it is the one founder-verifiable knob for the emergent-gate policy.
_TOP_BAND_WEIGHT = 4.5


def personal_gate_ids(db, uid: str, *, top_band: float = _TOP_BAND_WEIGHT) -> frozenset[str]:
    """The SEED node ids ``uid`` raised to the top of their weight budget — their
    personal emergent gates (§4.3), read from the OVERLAY (a user divergence, not
    a seed default) so only weights the user actually set count. Restricted to
    seed nodes, because the deterministic scorer can only compare a gate across
    two users when they share the node id (an emergent-node gate is a semantic
    match, handled by the LLM report layer). Empty on any read failure."""
    try:
        overlay = store.load_overlay(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: overlay read failed for %s", uid)
        return frozenset()
    out = set()
    for nid, entry in overlay.items():
        if not isinstance(entry, dict):
            continue
        w = entry.get("weight")
        if isinstance(w, (int, float)) and w >= top_band and pg.seed_node(nid) is not None:
            out.add(nid)
    return frozenset(out)


def _strip_qz_mirrors(profile: dict) -> dict:
    """The profile doc without its ``qz_*`` questionnaire mirrors, so the graph
    is the single authority for a questionnaire answer. Every other profile
    field (gate inputs, completeness, name, location, trust) is kept as-is."""
    return {k: v for k, v in (profile or {}).items() if not str(k).startswith("qz_")}


def load_user(db, uid: str) -> tuple[dict, dict]:
    """Graph-backed ``(profile, qstore)`` — the drop-in for
    ``matching_skill._load_user`` when ``person_graph_reads`` is on. Best-effort:
    a graph read failure falls back to an empty qstore (profile still read), so
    scoring degrades exactly as the old path did on a missing store rather than
    raising."""
    base = db.collection("users").document(uid)
    profile: dict = {}
    try:
        snap = base.collection("profile").document("main").get()
        if snap is not None:
            profile = snap.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: profile read failed for %s", uid)

    qstore: dict = {}
    profile = _strip_qz_mirrors(profile)
    try:
        graph = store.effective(db, uid)
        qstore = structured_qstore(graph)
        # Graph-stored profile edits (made through the graph tools) take
        # precedence over a stale profile/main field, so matching scores against
        # what the user last set. Only answered fields are overlaid — a blank
        # node never clears a profile value.
        profile.update(profile_overlay(graph))
    except Exception:  # noqa: BLE001
        logger.exception("person_graph_source: graph read failed for %s", uid)

    return profile, qstore
