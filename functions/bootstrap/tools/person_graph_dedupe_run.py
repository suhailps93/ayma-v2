"""Run the node-dedupe cross-check for one user against the live Firestore.

READ-ONLY. Builds the per-user index (:mod:`person_graph_index`) over every
graph node and runs the cross-check (:mod:`person_graph_crosscheck`) to find
duplicate groups and related-but-not-identical pairs. It NEVER writes — there is
no resolution here; resolution is the user-confirmed in-chat flow
(``skills/node_dedupe.py``). The founder's staging graph is the test corpus.

Usage (from functions/bootstrap/):

    PYTHONPATH=. python3 tools/person_graph_dedupe_run.py <uid> --project=ayma-staging
    PYTHONPATH=. python3 tools/person_graph_dedupe_run.py <uid> --project=ayma-staging --semantic
    PYTHONPATH=. python3 tools/person_graph_dedupe_run.py <uid> --dry-run   # explicit no-op guard

- --project=<id> : pins the Firestore project (sets GOOGLE_CLOUD_PROJECT before
                   the db client is built) — use ``ayma-staging``, NEVER prod.
- --semantic     : also run the bounded LiveKit semantic judge over the
                   ambiguous lexical candidates (costs a small LiveKit spend).
- --dry-run      : explicit read-only marker (the default — this tool never
                   writes regardless).
- --limit=<n>    : cap how many findings of each kind are printed (default 50).

Prints the candidate duplicate groups and related pairs with each node's id,
kind, section, visibility and a text snippet — the hunting grounds are career
facts and photo reads vs facts.
"""

from __future__ import annotations

import asyncio
import os
import sys


def _flag_value(flags: set[str], name: str, default: str = "") -> str:
    for f in flags:
        if f.startswith(f"--{name}="):
            return f.split("=", 1)[1]
    return default


def _print_report(index, report) -> None:
    by_id = {e.node_id: e for e in index}

    def line(nid: str) -> str:
        e = by_id.get(nid)
        if not e:
            return f"    {nid} (missing)"
        return f"    {nid}  [{e.kind}/{e.section}/{e.visibility}]  {(e.text or '')[:100]!r}"

    groups = report.duplicate_groups()
    print(f"\n=== DUPLICATE GROUPS ({len(groups)}) ===")
    for g in groups:
        print("  group:")
        for nid in g:
            print(line(nid))

    print(f"\n=== DUPLICATE PAIRS ({len(report.duplicate_pairs)}) ===")
    for p in report.duplicate_pairs:
        print(f"  [{p.relation} {p.score:.2f}] {p.a} <-> {p.b}  — {p.reason}")
        print(line(p.a))
        print(line(p.b))

    print(f"\n=== RELATED PAIRS ({len(report.related_pairs)}) ===")
    for p in report.related_pairs:
        print(f"  [{p.relation} {p.score:.2f}] {p.a} ~ {p.b}  — {p.reason}")
        print(line(p.a))
        print(line(p.b))


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(__doc__)
        return 2
    uid = args[0]

    project = _flag_value(flags, "project")
    if project:
        os.environ["GOOGLE_CLOUD_PROJECT"] = project
    if project and "prod" in project.lower():
        print(f"refusing to run against a prod-looking project: {project!r}")
        return 2

    limit = int(_flag_value(flags, "limit", "50") or "50")
    semantic = "--semantic" in flags

    import person_graph_crosscheck as crosscheck
    import person_graph_index as index_mod
    from db import get_db

    db = get_db()
    index = index_mod.build_index(db, uid)
    indexable = [e for e in index if e.indexable]
    print(
        f"indexed {len(index)} nodes ({len(indexable)} with content) for {uid} "
        f"[project={project or os.getenv('GOOGLE_CLOUD_PROJECT') or 'default'}]"
    )

    report = crosscheck.candidate_report(db, uid, index)
    if semantic:
        print(f"semantic judge over {len(report.ambiguous_pairs)} ambiguous pairs (LiveKit)...")
        report = asyncio.run(
            crosscheck.classify_pairs(report, index, uid=uid)
        )

    # apply the print cap
    report.duplicate_pairs = report.duplicate_pairs[:limit]
    report.related_pairs = report.related_pairs[:limit]
    _print_report(index, report)
    print("\n(read-only: nothing was written)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
