"""Write-time RELATED-LINK proposer (founder Nov 18).

Alongside the dedupe check — NOT changing it — this proposes MUTUAL ``related``
links between graph nodes that are the same entity/topic but a DIFFERENT fact
(the dog that came up talking about family, linked to the other dog notes; an
assessment node and a story node about the same thing). It runs the SAME
candidate finder the dedupe cross-check uses (lexical, or embedding NN when that
flag is on), then has the LiveKit judge label each candidate:

* CONFIDENT "related"  → a ``related`` link is written with the node
  (``store.link_related`` — mutual, a reference never a copy);
* "duplicate" (same fact) → left to the dedupe path, NEVER linked here;
* UNCERTAIN            → RAISED in chat via the settled ``record_pending_dedupe``
  flow (``pg_find_duplicates`` surfaces it), never linked silently;
* "unrelated"         → dropped.

LEVEL RULE (founder Nov 18): a related link only connects nodes level 3 or
deeper — a candidate touching a level-0/1/2 node on either end is DROPPED before
it is written or counted.

Gated behind ``CONFIG.node_related_propose`` (off by default). It runs at session
end (``post_turn``) over the session's freshly-ingested graph, and a DRY-RUN mode
(``dry_run=True``) reports what it WOULD link/raise without writing — the backfill
entry point. The judge stays on the LiveKit gateway (``AGENTS.md``); the prompt
lives in ``prompts/related_link_judge.md``.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import person_graph as pg
import person_graph_crosscheck as crosscheck
import person_graph_index as index_mod
import person_graph_store as store

logger = logging.getLogger("ayma.graph_related")

_JUDGE_PROMPT_PATH = Path(__file__).parent / "prompts" / "related_link_judge.md"

# Hard cap on pairs sent to the judge in one run — a bounded, cheap LiveKit spend.
_JUDGE_CAP = 200


@dataclass
class RelatedReport:
    """What one user's related-link pass found. ``linked`` = ``(a, b, reason)``
    pairs a confident link was (or would be) written for; ``raised`` =
    ``(a, b, reason)`` uncertain pairs recorded for the in-chat raise;
    ``dropped_by_level`` = candidates discarded by the level-3 rule; ``found`` =
    candidate pairs the finder produced."""

    found: int = 0
    linked: list[tuple[str, str, str]] = field(default_factory=list)
    raised: list[tuple[str, str, str]] = field(default_factory=list)
    dropped_by_level: int = 0
    dry_run: bool = True
    node_count: int = 0

    def summary(self) -> dict:
        return {
            "found": self.found,
            "linked": len(self.linked),
            "raised": len(self.raised),
            "dropped_by_level": self.dropped_by_level,
            "dry_run": self.dry_run,
            "nodes": self.node_count,
        }


def eligible_pairs(
    pairs: list[crosscheck.CandidatePair], level_of: dict[str, int]
) -> tuple[list[crosscheck.CandidatePair], int]:
    """Split candidate ``pairs`` into (kept, dropped_count) by the level-3 rule —
    a pair is kept only when BOTH ends are level 3 or deeper (founder Nov 18)."""
    kept = [
        p for p in pairs
        if pg.eligible_for_related_link(level_of.get(p.a, 0), level_of.get(p.b, 0))
    ]
    return kept, len(pairs) - len(kept)


async def _judge(items: list[dict], *, uid: str | None) -> Optional[dict]:
    """Ask the LiveKit gateway to label each pair related/duplicate/unrelated/
    uncertain. Returns ``{i: verdict}`` or ``None`` on failure."""
    import gemini
    from prompt import load_prompt_file

    try:
        result = await gemini.generate_json(
            json.dumps(items, ensure_ascii=False),
            load_prompt_file(_JUDGE_PROMPT_PATH),
            uid=uid,
            feature="graph_related",
            enforce_cap=False,
            temperature=0.0,
            max_tokens=1024,
        )
    except Exception:  # noqa: BLE001 - best-effort; a judge failure never blocks
        logger.warning("graph_related: judge failed", exc_info=True)
        return None

    rows = result if isinstance(result, list) else (result or {}).get("pairs")
    if not isinstance(rows, list):
        return None
    out: dict = {}
    for row in rows:
        if isinstance(row, dict) and "i" in row:
            try:
                out[int(row["i"])] = str(row.get("verdict", "")).strip().lower()
            except (TypeError, ValueError):
                continue
    return out


async def sweep_user(
    db, uid: str, *, dry_run: bool = True, judge: bool = True
) -> RelatedReport:
    """Run the related-link proposer for one user. Finds same-topic-but-different
    candidate pairs (reusing the dedupe cross-check finder), drops any touching a
    level-0/1/2 node, has the LiveKit judge label the rest, then LINKS the
    confident "related" pairs and RAISES the uncertain ones (never silent). Pairs
    the judge calls a duplicate are left to the dedupe path (never linked). Pairs
    already linked or dismissed are skipped. ``dry_run`` reports without writing.
    Gated on ``CONFIG.node_related_propose`` — flag-off returns an empty report.
    Never raises for one bad pair."""
    from config import CONFIG

    if not getattr(CONFIG, "node_related_propose", False):
        return RelatedReport(dry_run=dry_run)

    graph = store.effective(db, uid)
    index = index_mod.index_from_graph(graph)
    level_of = {e.node_id: e.level for e in index}
    report = crosscheck.candidate_report(db, uid, index)

    # Skip pairs already linked as related, or the user dismissed ("keep both").
    already = {p.key() for p in crosscheck.related_link_pairs(graph)}
    try:
        dismissed = store.dedupe_dismissed(db, uid)
    except Exception:  # noqa: BLE001
        dismissed = set()
    candidates = [
        p for p in report.related_pairs
        if p.key() not in already and p.key() not in dismissed
    ]

    # LEVEL RULE — both ends must be level 3+.
    candidates, dropped = eligible_pairs(candidates, level_of)

    out = RelatedReport(
        found=len(candidates) + dropped,
        dropped_by_level=dropped,
        dry_run=dry_run,
        node_count=report.node_count,
    )
    if not candidates:
        return out

    # Judge each candidate (batched). A dry run without a judge (or a judge
    # failure) reports every candidate as an UNCERTAIN raise — never a silent link.
    verdicts: dict = {}
    if judge:
        by_id = {e.node_id: e for e in index}
        items = []
        pos_pair: dict[int, crosscheck.CandidatePair] = {}
        for n, p in enumerate(candidates[:_JUDGE_CAP]):
            a, b = by_id.get(p.a), by_id.get(p.b)
            if not a or not b:
                continue
            pos_pair[n] = p
            items.append({"i": n, "a": (a.text or "")[:280], "b": (b.text or "")[:280]})
        if items:
            got = await _judge(items, uid=uid)
            if got is not None:
                for pos, p in pos_pair.items():
                    verdicts[p.key()] = got.get(pos, "uncertain")

    for p in candidates:
        verdict = verdicts.get(p.key(), "uncertain")
        reason = p.reason or "same topic"
        if verdict == "related":
            out.linked.append((p.a, p.b, reason))
            if not dry_run:
                try:
                    store.link_related(db, uid, p.a, p.b, label=reason)
                except Exception:  # noqa: BLE001 - linking never blocks the sweep
                    logger.warning("graph_related: link failed for %s", uid)
        elif verdict == "duplicate":
            # Same fact — the dedupe path's job, never linked here (do NOT touch
            # dedupe_pending / trigger a merge).
            continue
        elif verdict == "unrelated":
            continue
        else:  # uncertain, or no verdict — raise in chat, never link silently.
            out.raised.append((p.a, p.b, reason))
            if not dry_run:
                try:
                    store.record_pending_dedupe(db, uid, p.a, p.b, reason)
                except Exception:  # noqa: BLE001 - recording a raise never blocks
                    logger.warning("graph_related: raise failed for %s", uid)
    return out
