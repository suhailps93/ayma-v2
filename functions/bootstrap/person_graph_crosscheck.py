"""Cross-check the node index for duplicates and related-but-not-identical pairs
(node-dedupe step 2, founder Nov 17).

Runs over the flat index from :mod:`person_graph_index` and finds, among nodes
that are NOT in an ancestor/descendant relationship (duplicates across sections,
across branches, or between a report's grounding nodes and story bullets):

* DUPLICATE pairs/groups — exact (same normalized text), near-duplicate (high
  lexical overlap), or (when the semantic pass runs) semantically equivalent;
* RELATED pairs — same entity/topic but NOT identical — surfaced as candidate
  ``related`` links (Contract 4).

Two layers, both inside existing backend patterns (no vector store, no second
index DB):

1. LEXICAL (default, deterministic, no inference): normalized-text equality,
   ``difflib`` ratio, and content-token Jaccard generate every exact/near-dup
   pair and a bounded set of "shared-entity" related/ambiguous candidates.
2. SEMANTIC (opt-in, ``classify_pairs``): the bounded ambiguous set is judged by
   the LiveKit inference gateway (``gemini.generate_json``) into
   duplicate / related / unrelated — the only way to catch a reworded same-fact
   the lexical pass misses, and it stays on LiveKit per ``AGENTS.md``.

Read-only: this module computes a report; it never writes the graph. Resolution
is never silent — the report is raised to the user by Ayma (see
``skills/node_dedupe.py``), who applies merge / link / keep-both.
"""

from __future__ import annotations

import difflib
import json
import logging
from dataclasses import dataclass, field
from typing import Optional

from person_graph_index import NodeIndexEntry

logger = logging.getLogger("ayma.graph_dedupe")

# Lexical thresholds — deliberately high-precision for the auto-"duplicate"
# label; everything softer is a candidate the user confirms, never a silent act.
EXACT = "exact"
NEAR_DUP = "near_dup"
SEMANTIC_DUP = "semantic_dup"
RELATED = "related"

_NEAR_RATIO = 0.86  # difflib SequenceMatcher ratio on normalized text
_NEAR_JACCARD = 0.70  # content-token Jaccard
_RELATED_JACCARD = 0.34  # mid-band overlap → related/ambiguous candidate
_MIN_TOKENS = 2  # ignore ultra-short nodes for fuzzy comparison
_RARE_DF = 3  # a token in <= this many nodes is "entity-ish" (shared → related)
_MIN_SHARED_RARE = 2  # this many shared rare tokens alone flags a related pair

# Hard cap on how many pairs the semantic judge will ever look at in one run —
# keeps a bounded, cheap LiveKit spend on a large graph.
_SEMANTIC_PAIR_CAP = 200


@dataclass(frozen=True)
class CandidatePair:
    """One cross-check finding between two non-ancestor/descendant nodes.
    ``relation`` is one of EXACT / NEAR_DUP / SEMANTIC_DUP / RELATED;
    ``score`` the lexical similarity (0..1); ``reason`` a short human label."""

    a: str
    b: str
    relation: str
    score: float
    reason: str = ""

    @property
    def is_duplicate(self) -> bool:
        return self.relation in (EXACT, NEAR_DUP, SEMANTIC_DUP)

    def key(self) -> tuple[str, str]:
        return (self.a, self.b) if self.a <= self.b else (self.b, self.a)


@dataclass
class CrossCheckReport:
    duplicate_pairs: list[CandidatePair] = field(default_factory=list)
    related_pairs: list[CandidatePair] = field(default_factory=list)
    # ambiguous lexical candidates handed to the semantic judge (only populated
    # before classify_pairs folds them into the lists above).
    ambiguous_pairs: list[CandidatePair] = field(default_factory=list)
    node_count: int = 0

    def duplicate_groups(self) -> list[list[str]]:
        """Connected components over the duplicate pairs — a group is one fact
        said in several places, surfaced to the user as a single decision."""
        return _components([p.key() for p in self.duplicate_pairs])


def _rel_excluded(a: NodeIndexEntry, b: NodeIndexEntry) -> bool:
    """True when the pair must be skipped: same node, or one is an ancestor of
    the other (parent/child chains are the graph's own structure, not a dup)."""
    if a.node_id == b.node_id:
        return True
    return a.node_id in b.ancestors or b.node_id in a.ancestors


def _jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def find_candidates(index: list[NodeIndexEntry]) -> CrossCheckReport:
    """The lexical pass: every exact/near-dup pair, every strongly-related pair,
    and the ambiguous mid-band candidates for the optional semantic judge.

    ``n`` is small (a person graph is hundreds of nodes), so the O(n²) scan is
    trivial; it is bounded by ``len(index)²/2`` comparisons."""
    nodes = [e for e in index if e.indexable]
    report = CrossCheckReport(node_count=len(nodes))

    # document frequency of each content token, for rare-token (entity) overlap.
    df: dict[str, int] = {}
    for e in nodes:
        for t in e.tokens:
            df[t] = df.get(t, 0) + 1

    seen: set[tuple[str, str]] = set()
    for i in range(len(nodes)):
        a = nodes[i]
        for j in range(i + 1, len(nodes)):
            b = nodes[j]
            if _rel_excluded(a, b):
                continue
            key = (a.node_id, b.node_id)
            if key in seen:
                continue
            seen.add(key)

            if a.norm == b.norm:
                report.duplicate_pairs.append(
                    CandidatePair(a.node_id, b.node_id, EXACT, 1.0, "identical text")
                )
                continue

            jac = _jaccard(a.tokens, b.tokens)
            ratio = difflib.SequenceMatcher(None, a.norm, b.norm, autojunk=False).ratio()
            enough = min(len(a.tokens), len(b.tokens)) >= _MIN_TOKENS

            if enough and (ratio >= _NEAR_RATIO or jac >= _NEAR_JACCARD):
                report.duplicate_pairs.append(
                    CandidatePair(
                        a.node_id, b.node_id, NEAR_DUP, max(ratio, jac),
                        _cross_label(a, b, "near-duplicate"),
                    )
                )
                continue

            shared_rare = {t for t in (a.tokens & b.tokens) if df.get(t, 0) <= _RARE_DF}
            if enough and (jac >= _RELATED_JACCARD or len(shared_rare) >= _MIN_SHARED_RARE):
                label = _cross_label(a, b, "same topic") + (
                    f" ({', '.join(sorted(shared_rare)[:3])})" if shared_rare else ""
                )
                pair = CandidatePair(a.node_id, b.node_id, RELATED, max(jac, ratio), label)
                # mid-band overlap is genuinely ambiguous (dup vs merely related):
                # hand it to the semantic judge when that pass runs; otherwise it
                # surfaces as a related link.
                report.ambiguous_pairs.append(pair)
                report.related_pairs.append(pair)

    report.duplicate_pairs.sort(key=lambda p: -p.score)
    report.related_pairs.sort(key=lambda p: -p.score)
    report.ambiguous_pairs.sort(key=lambda p: -p.score)
    return report


def _cross_label(a: NodeIndexEntry, b: NodeIndexEntry, base: str) -> str:
    if a.kind != b.kind:
        return f"{base}: {a.kind} vs {b.kind}"
    if a.section != b.section:
        return f"{base}: {a.section} vs {b.section}"
    return base


async def classify_pairs(
    report: CrossCheckReport,
    index: list[NodeIndexEntry],
    *,
    uid: str | None = None,
    cap: int = _SEMANTIC_PAIR_CAP,
) -> CrossCheckReport:
    """Promote the ambiguous lexical candidates with a semantic judgment from the
    LiveKit inference gateway. A pair the model calls a duplicate moves to
    ``duplicate_pairs`` (relation SEMANTIC_DUP); one it calls unrelated is
    dropped from ``related_pairs``; "related" stays a related link. Bounded by
    ``cap`` pairs. On any inference failure the lexical result is returned
    unchanged (best-effort, never blocks the read-only report)."""
    pairs = report.ambiguous_pairs[:cap]
    if not pairs:
        return report
    by_id = {e.node_id: e for e in index}

    items = []
    pos_to_pair: dict[int, CandidatePair] = {}
    for n, p in enumerate(pairs):
        a, b = by_id.get(p.a), by_id.get(p.b)
        if not a or not b:
            continue
        pos_to_pair[n] = p
        items.append(
            {"i": n, "a": (a.text or "")[:280], "b": (b.text or "")[:280]}
        )
    if not items:
        return report

    verdicts = await _judge(items, uid=uid)
    if verdicts is None:
        return report  # inference failed — keep the lexical report as-is

    judged_keys = {p.key() for p in pos_to_pair.values()}
    related_keep: list[CandidatePair] = [
        p for p in report.related_pairs if p.key() not in judged_keys
    ]
    dup_keys = {p.key() for p in report.duplicate_pairs}
    for pos, p in pos_to_pair.items():
        verdict = (verdicts.get(pos) or "").strip().lower()
        if verdict == "duplicate":
            if p.key() not in dup_keys:
                report.duplicate_pairs.append(
                    CandidatePair(p.a, p.b, SEMANTIC_DUP, p.score, "same fact, reworded")
                )
                dup_keys.add(p.key())
        elif verdict == "related":
            related_keep.append(p)
        else:
            # unrelated, or no verdict returned → keep as a related link rather
            # than silently discarding a lexical signal.
            related_keep.append(p)
    report.related_pairs = related_keep
    report.duplicate_pairs.sort(key=lambda p: -p.score)
    return report


async def _judge(items: list[dict], *, uid: str | None) -> Optional[dict]:
    """Ask the LiveKit gateway to label each pair duplicate/related/unrelated.
    Returns ``{pair_key_tuple: verdict}`` or ``None`` on failure."""
    import gemini

    system = (
        "You compare pairs of short facts from one person's profile. For each "
        "pair, answer whether the two statements assert THE SAME underlying fact "
        "(reworded) = 'duplicate'; are about the same topic/entity but assert "
        "different things = 'related'; or are unrelated = 'unrelated'. Reply "
        "with ONLY a JSON array of {\"i\": <int>, \"verdict\": <string>}."
    )
    payload = json.dumps(items, ensure_ascii=False)
    try:
        result = await gemini.generate_json(
            payload, system,
            uid=uid, feature="graph_dedupe", enforce_cap=False,
            temperature=0.0, max_tokens=1024,
        )
    except Exception:  # noqa: BLE001 - best-effort, never blocks the report
        logger.warning("graph_dedupe: semantic judge failed", exc_info=True)
        return None

    rows = result if isinstance(result, list) else (result or {}).get("pairs")
    if not isinstance(rows, list):
        return None
    out: dict = {}
    for row in rows:
        if isinstance(row, dict) and "i" in row:
            try:
                out[int(row["i"])] = str(row.get("verdict", ""))
            except (TypeError, ValueError):
                continue
    # keyed by the positional index classify_pairs assigned each pair.
    return out


def _components(pairs: list[tuple[str, str]]) -> list[list[str]]:
    """Union-find connected components over undirected ``pairs``."""
    parent: dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x: str, y: str) -> None:
        parent[find(x)] = find(y)

    for a, b in pairs:
        union(a, b)
    groups: dict[str, list[str]] = {}
    for node in parent:
        groups.setdefault(find(node), []).append(node)
    return [sorted(g) for g in groups.values() if len(g) > 1]
