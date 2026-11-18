"""DATA-LEVEL node dedupe sweep (founder Nov 17: "merge duplicate nodes on the
SERVER"). Layer 2 of the three-layer dedupe — the post-processing pass that
actually REMOVES duplicate nodes from a user's graph, where Layer 1
(write-time prevention/fold in ``person_graph_store``) and the render-level
zero-dup suppression only stop or hide them.

It runs in two places (both gated behind ``CONFIG.graph_dedupe_sweep``):

* when a conversation SESSION ENDS (``post_turn.persist_and_ingest``), right
  after the session's facts are ingested, so the pair the user just created in
  different words is merged before they see the graph again;
* a NIGHTLY backstop (``POST /cron/graph-dedupe``) over every user, catching
  anything a session-end pass missed.

Per section of the user's graph it finds near-duplicate pairs (reusing the
existing candidate finder — Gemini-embedding nearest-neighbour when
``graph_embedding_dedupe`` is on, else the lexical pre-filter), has the LiveKit
judge label each (``person_graph_crosscheck.classify_pairs`` — never rerouted off
LiveKit), and then:

* MERGES the pairs the judge calls a clear duplicate (exact text, or judge
  verdict "duplicate"). The merge rules (founder Nov 17):
    - the FULLER / more-complete text survives;
    - the survivor keeps BOTH sources (``merge_nodes`` retires the duplicate's
      answer + its source to the survivor's Ayma-only history);
    - merged visibility = the MORE PRIVATE of the two — a merge NEVER makes a
      fact more public (HARD privacy rule: private > ayma_only > public);
    - where one of the pair is a STANDARD node, the standard node survives
      (settled build-2490 rule).
* RECORDS every UNCERTAIN pair (lexically near but not judge-confirmed, merely
  related, or disagreeing) with ``store.record_pending_dedupe`` so Ayma raises it
  in chat for the user to decide — the sweep never guesses and never merges an
  uncertain pair silently.

Read/compute is reusable and tested with a Firestore fake and a mocked embedding
backend; no live calls in tests.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

import person_graph as pg
import person_graph_crosscheck as crosscheck
import person_graph_index as index_mod
import person_graph_store as store

logger = logging.getLogger("ayma.graph_dedupe_sweep")

# Visibility privacy ranking — SMALLER is MORE PRIVATE. The merge survivor takes
# the minimum rank of the pair, so a merge can only ever tighten visibility.
_VIS_RANK = {
    pg.Visibility.PRIVATE.value: 0,
    pg.Visibility.AYMA_ONLY.value: 1,
    pg.Visibility.PUBLIC.value: 2,
}

# Only these relations are auto-merged: exact text identity, or a pair the
# LiveKit judge confirmed is the same fact reworded. A merely lexical near-dup
# (NEAR_DUP) or a related pair is NOT merged on similarity alone — it is raised.
_AUTO_MERGE = {crosscheck.EXACT, crosscheck.SEMANTIC_DUP}


@dataclass
class SweepReport:
    """What one user's sweep found. ``merged`` = ``(survivor, removed)`` pairs
    actually folded; ``raised`` = ``(a, b, reason)`` uncertain pairs recorded for
    the in-chat raise; ``found`` = total candidate pairs considered."""

    found: int = 0
    merged: list[tuple[str, str]] = field(default_factory=list)
    raised: list[tuple[str, str, str]] = field(default_factory=list)
    dry_run: bool = True
    node_count: int = 0

    def summary(self) -> dict:
        return {
            "found": self.found,
            "merged": len(self.merged),
            "raised": len(self.raised),
            "dry_run": self.dry_run,
            "nodes": self.node_count,
        }


def _vis_value(node) -> str:
    v = getattr(node, "visibility", None)
    return v.value if hasattr(v, "value") else str(v)


def more_private(a_vis: str, b_vis: str) -> str:
    """The MORE PRIVATE of two visibility strings (private > ayma_only > public).
    Unknown values are treated as most private (fail safe — never widen)."""
    ra = _VIS_RANK.get(a_vis, 0)
    rb = _VIS_RANK.get(b_vis, 0)
    return a_vis if ra <= rb else b_vis


def choose_survivor(graph, a_id: str, b_id: str) -> tuple[str, str]:
    """Return ``(survivor_id, duplicate_id)`` per the merge rules: a STANDARD node
    always survives; otherwise the node with the FULLER display text survives
    (ties broken by id for determinism)."""
    import person_graph_render as render

    a, b = graph[a_id], graph[b_id]
    a_std = getattr(a, "standard", False)
    b_std = getattr(b, "standard", False)
    if a_std and not b_std:
        return a_id, b_id
    if b_std and not a_std:
        return b_id, a_id
    la = len(render.node_display_text(a) or "")
    lb = len(render.node_display_text(b) or "")
    if la != lb:
        return (a_id, b_id) if la > lb else (b_id, a_id)
    return (a_id, b_id) if a_id <= b_id else (b_id, a_id)


def apply_merge(db, uid: str, a_id: str, b_id: str, graph) -> Optional[tuple[str, str]]:
    """Merge the duplicate pair ``(a_id, b_id)`` per the founder's rules and return
    ``(survivor, removed)``, or ``None`` if the merge could not be applied (e.g. a
    node already folded earlier in the same run). Fuller text / standard node
    survives; the survivor takes the MORE PRIVATE visibility (never wider)."""
    survivor_id, dup_id = choose_survivor(graph, a_id, b_id)
    target_vis = more_private(_vis_value(graph[a_id]), _vis_value(graph[b_id]))
    surv_vis = _vis_value(graph[survivor_id])
    try:
        store.merge_nodes(db, uid, survivor_id, dup_id)
    except ValueError:
        return None
    # Tighten the survivor's visibility only — target is the minimum rank of the
    # pair, so this can only ever make the fact MORE private, never more public.
    if _VIS_RANK.get(target_vis, 0) < _VIS_RANK.get(surv_vis, 0):
        try:
            store.set_visibility(db, uid, survivor_id, target_vis)
        except ValueError:
            logger.warning("dedupe sweep: could not tighten visibility on %s", survivor_id)
    return survivor_id, dup_id


async def sweep_user(
    db, uid: str, *, dry_run: bool = True, judge: bool = True
) -> SweepReport:
    """Run the Layer-2 dedupe sweep for one user. Finds near-duplicate pairs
    WITHIN each section, has the LiveKit judge label the ambiguous ones, MERGES
    the clear duplicates (fuller/standard survives, both sources kept, more-private
    visibility wins) and RECORDS the uncertain ones for the in-chat raise.
    ``dry_run`` reports without writing. Gated on ``CONFIG.graph_dedupe_sweep`` —
    flag-off returns an empty report. Never raises for one bad pair."""
    from config import CONFIG

    if not getattr(CONFIG, "graph_dedupe_sweep", False):
        return SweepReport(dry_run=dry_run)

    index = index_mod.build_index(db, uid)
    section_of = {e.node_id: e.section for e in index}
    report = crosscheck.candidate_report(db, uid, index)

    # Judge EVERY non-exact candidate (lexical NEAR_DUP included), so a merge is
    # only ever on the judge's "duplicate" verdict — never on lexical/embedding
    # similarity alone. Exact text identity is a duplicate directly.
    exact = [p for p in report.duplicate_pairs if p.relation == crosscheck.EXACT]
    seen = {p.key() for p in exact}
    to_judge = []
    for p in list(report.duplicate_pairs) + list(report.related_pairs):
        if p.relation == crosscheck.EXACT or p.key() in seen:
            continue
        seen.add(p.key())
        to_judge.append(p)
    report.duplicate_pairs = exact
    report.related_pairs = list(to_judge)
    report.ambiguous_pairs = list(to_judge)
    if judge:
        try:
            report = await crosscheck.classify_pairs(report, index, uid=uid)
        except Exception:  # noqa: BLE001 - judge failure keeps the lexical split
            logger.warning("dedupe sweep: judge failed for %s", uid, exc_info=True)

    dismissed = store.dedupe_dismissed(db, uid)

    def _same_section(p) -> bool:
        sa = section_of.get(p.a)
        return sa is not None and sa == section_of.get(p.b)

    def _has_emergent(p) -> bool:
        # A dedupe pair must involve at least one EMERGENT (user-/writer-minted)
        # node — two curated seed/standard template fields are part of the fixed
        # question tree, never duplicates of each other.
        return pg.seed_node(p.a) is None or pg.seed_node(p.b) is None

    def _live(p) -> bool:
        return p.key() not in dismissed and _same_section(p) and _has_emergent(p)

    merge_pairs = [p for p in report.duplicate_pairs if _live(p) and p.relation in _AUTO_MERGE]
    raise_pairs = [p for p in report.related_pairs if _live(p)]

    out = SweepReport(
        found=len(merge_pairs) + len(raise_pairs),
        dry_run=dry_run,
        node_count=report.node_count,
    )

    if not dry_run:
        graph = store.effective(db, uid)
    removed: set[str] = set()
    for p in merge_pairs:
        if p.a in removed or p.b in removed:
            continue
        if dry_run:
            out.merged.append((p.a, p.b))
            continue
        if p.a not in graph or p.b not in graph:
            continue
        res = apply_merge(db, uid, p.a, p.b, graph)
        if res is not None:
            out.merged.append(res)
            removed.add(res[1])
            graph = store.effective(db, uid)

    for p in raise_pairs:
        out.raised.append((p.a, p.b, p.reason))
        if not dry_run:
            try:
                store.record_pending_dedupe(db, uid, p.a, p.b, p.reason)
            except Exception:  # noqa: BLE001 - recording a raise never blocks
                logger.warning("dedupe sweep: record raise failed for %s", uid)

    return out


async def run_sweep(db, user_limit: int | None = None) -> dict:
    """The nightly backstop (``POST /cron/graph-dedupe``). Walks up to
    ``user_limit`` users and runs :func:`sweep_user` (apply mode) for each, so any
    duplicate a session-end pass missed is merged. Gated on
    ``CONFIG.graph_dedupe_sweep``. Never raises for a single user; one bad user
    never stops the sweep."""
    from config import CONFIG

    if not getattr(CONFIG, "graph_dedupe_sweep", False):
        return {"checked": 0, "merged": 0, "raised": 0, "disabled": True}

    limit = user_limit or getattr(CONFIG, "persona_snapshot_sweep_limit", 200)
    try:
        users = [s.id for s in db.collection("users").limit(limit).stream()]
    except Exception:  # noqa: BLE001
        logger.exception("dedupe sweep: user listing failed")
        return {"checked": 0, "merged": 0, "raised": 0}

    checked = merged = raised = 0
    for uid in users:
        checked += 1
        try:
            rep = await sweep_user(db, uid, dry_run=False, judge=True)
            merged += len(rep.merged)
            raised += len(rep.raised)
        except Exception:  # noqa: BLE001 - one bad user never stops the sweep
            logger.exception("dedupe sweep failed for %s", uid)
    return {"checked": checked, "merged": merged, "raised": raised}
