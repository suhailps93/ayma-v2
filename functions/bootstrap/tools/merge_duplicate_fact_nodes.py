"""Merge standard-vs-emergent DUPLICATE fact nodes for one user (founder build
2488, "make sure there are NO duplicates").

The founder's About Me showed facts twice because the same fact lived in a
STANDARD node (``ethnic_cultural_origin`` = South Asian, ``date_of_birth`` →
Age, ``target_match_genders`` → Interested in) AND in an emergent node that only
restated it (``emergent.editor.identity.11`` = "Ethnic and cultural origin:
South Asian", ``emergent.editor.identity.4`` = "Age: 33", prose
``emergent.story`` bullets). Layers 1 (render suppression) and 2 (write-time
merge-not-mint) stop NEW duplicates and hide existing ones; this tool is the
one-off DATA cleanup that actually folds each existing emergent restatement into
the standard node it duplicates and removes it.

For a given uid it:
  * builds the effective graph and finds every emergent node whose text restates
    a STANDARD fact (the shared matcher ``person_graph_render``);
  * MERGES each such emergent duplicate INTO the standard node with the existing
    ``person_graph_store.merge_nodes`` (= the ``pg_resolve_duplicate`` 'merge'
    logic): the STANDARD node survives, the duplicate's live answer retires to
    the survivor's Ayma-only history, its children are rehomed and its links
    carried over, then the duplicate is deleted;
  * where the pair conflicts on VISIBILITY, keeps the STANDARD node's visibility
    (merge_nodes never changes the survivor's visibility) and records the
    conflict in the report.

``--dry-run`` (the default stance for the founder) REPORTS the pairs + counts
and writes nothing. The project is pinned to **ayma-staging** and the tool
ABORTS if the active project is not exactly ``ayma-staging`` — it must never run
against prod, and the main thread runs it (dry-run first) for the founder's uid
only; other staging users are governed by the in-chat raise flow, not a silent
sweep.

Usage (from functions/bootstrap/):

    PYTHONPATH=. python3 tools/merge_duplicate_fact_nodes.py <uid> --project=ayma-staging              # dry-run (default)
    PYTHONPATH=. python3 tools/merge_duplicate_fact_nodes.py <uid> --project=ayma-staging --apply       # applies the merges

The reusable :func:`merge_duplicate_fact_nodes` takes a db and a ``dry_run`` flag
so it is unit-tested with a Firestore fake and never needs a live project.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from typing import Optional

_STAGING_PROJECT = "ayma-staging"


@dataclass
class DuplicatePair:
    """One standard-vs-emergent duplicate: the emergent ``dup_id`` restates the
    standard ``standard_id``'s fact. ``vis_conflict`` is True when the two carry
    different visibilities (the standard node's visibility is kept on merge)."""

    standard_id: str
    standard_label: str
    standard_vis: str
    dup_id: str
    dup_text: str
    dup_vis: str

    @property
    def vis_conflict(self) -> bool:
        return self.standard_vis != self.dup_vis


@dataclass
class MergeReport:
    pairs: list[DuplicatePair] = field(default_factory=list)
    merged: list[str] = field(default_factory=list)  # dup ids actually merged
    dry_run: bool = True
    node_count: int = 0

    @property
    def vis_conflicts(self) -> list[DuplicatePair]:
        return [p for p in self.pairs if p.vis_conflict]


def _standard_sections(graph) -> set[str]:
    return {n.section for n in graph.values() if getattr(n, "standard", False)}


def restatement_standard_id(graph, node) -> Optional[str]:
    """The id of the STANDARD node whose fact ``node`` restates (searching the
    node's own section first, then every standard section so a loose node homed
    in ``misc`` is caught), or ``None``. ``node`` itself is never returned."""
    import person_graph_render as render

    text = render.node_display_text(node)
    if not text:
        return None
    sections = [node.section] + [s for s in _standard_sections(graph) if s != node.section]
    for sec in sections:
        hit = render.standard_restatement_id(graph, text, sec)
        if hit is not None and hit != node.id:
            return hit
    return None


def find_standard_duplicate_pairs(graph) -> list[DuplicatePair]:
    """Every emergent node that only restates a STANDARD fact, paired with the
    standard node it duplicates. Standard nodes are never duplicates of each
    other; an emergent node that restates no standard fact is left alone."""
    import person_graph_render as render

    pairs: list[DuplicatePair] = []
    for nid in sorted(graph):
        node = graph[nid]
        if not getattr(node, "emergent", False):
            continue
        std_id = restatement_standard_id(graph, node)
        if std_id is None:
            continue
        std = graph[std_id]
        pairs.append(
            DuplicatePair(
                standard_id=std_id,
                standard_label=std.standard_field_label or std.prompt or std_id,
                standard_vis=_vis(std),
                dup_id=nid,
                dup_text=render.node_display_text(node),
                dup_vis=_vis(node),
            )
        )
    return pairs


def _vis(node) -> str:
    v = getattr(node, "visibility", None)
    return v.value if hasattr(v, "value") else str(v)


def merge_duplicate_fact_nodes(db, uid: str, *, dry_run: bool = True) -> MergeReport:
    """Find and (unless ``dry_run``) merge every standard-vs-emergent duplicate
    fact node for ``uid``. The standard node always survives; each emergent
    duplicate is folded in with ``person_graph_store.merge_nodes`` and deleted.
    Returns a :class:`MergeReport`. Never raises on a single bad pair — a merge
    that fails is skipped and the rest proceed."""
    import person_graph_store as store

    graph = store.effective(db, uid)
    pairs = find_standard_duplicate_pairs(graph)
    report = MergeReport(pairs=pairs, dry_run=dry_run, node_count=len(graph))
    if dry_run:
        return report
    for p in pairs:
        try:
            store.merge_nodes(db, uid, p.standard_id, p.dup_id)
            report.merged.append(p.dup_id)
        except ValueError:
            # a pair that can't be merged (e.g. the duplicate was already folded
            # by an earlier pair that rehomed it) is skipped, never fatal.
            continue
    return report


# --- CLI -------------------------------------------------------------------


def _flag_value(flags: set[str], name: str, default: str = "") -> str:
    for f in flags:
        if f.startswith(f"--{name}="):
            return f.split("=", 1)[1]
    return default


def require_staging_project(project: str) -> None:
    """ABORT unless the active project is exactly ``ayma-staging`` — this tool
    writes, and must never touch prod (or any other project)."""
    if project != _STAGING_PROJECT:
        raise SystemExit(
            f"refusing to run: project must be exactly {_STAGING_PROJECT!r}, "
            f"got {project!r}. Pass --project=ayma-staging."
        )


def _print_report(report: MergeReport) -> None:
    print(f"\nindexed {report.node_count} nodes")
    print(f"=== STANDARD-vs-EMERGENT DUPLICATE PAIRS ({len(report.pairs)}) ===")
    for p in report.pairs:
        flag = "  [VIS CONFLICT — keeping standard's visibility]" if p.vis_conflict else ""
        print(
            f"  standard {p.standard_id} ({p.standard_label}, {p.standard_vis})"
            f"  <=  dup {p.dup_id} ({p.dup_vis}): {p.dup_text!r}{flag}"
        )
    if report.vis_conflicts:
        print(f"\n({len(report.vis_conflicts)} pair(s) had a visibility conflict; "
              f"the standard node's visibility is kept.)")
    if report.dry_run:
        print("\n(dry-run: nothing was written)")
    else:
        print(f"\nmerged {len(report.merged)} duplicate node(s) into their standard node")


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(__doc__)
        return 2
    uid = args[0]

    project = _flag_value(flags, "project") or os.getenv("GOOGLE_CLOUD_PROJECT", "")
    require_staging_project(project)
    os.environ["GOOGLE_CLOUD_PROJECT"] = project

    dry_run = "--dry-run" in flags or "--apply" not in flags

    from db import get_db

    db = get_db()
    report = merge_duplicate_fact_nodes(db, uid, dry_run=dry_run)
    _print_report(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
