"""Run the Layer-2 DATA-LEVEL node dedupe sweep for one user against live
Firestore (founder Nov 17: "merge duplicate nodes on the server").

Wraps :func:`person_graph_dedupe_sweep.sweep_user` with the same project guard as
the build-2490 merge tool: pinned to **ayma-staging**, and it ABORTS unless the
active project is exactly ``ayma-staging`` — it writes, and must never touch prod.
``--dry-run`` (the DEFAULT) reports the pairs it WOULD merge / raise and writes
nothing; ``--apply`` performs the merges and records the uncertain pairs.

The sweep is gated behind ``GRAPH_DEDUPE_SWEEP`` — set it on for the run.

Usage (from functions/bootstrap/):

    GRAPH_DEDUPE_SWEEP=true GRAPH_EMBEDDING_DEDUPE=true \
      PYTHONPATH=. python3 tools/dedupe_sweep_run.py <uid> --project=ayma-staging            # dry-run
    GRAPH_DEDUPE_SWEEP=true GRAPH_EMBEDDING_DEDUPE=true \
      PYTHONPATH=. python3 tools/dedupe_sweep_run.py <uid> --project=ayma-staging --apply     # applies
"""

from __future__ import annotations

import asyncio
import os
import sys

_STAGING_PROJECT = "ayma-staging"


def _flag_value(flags: set[str], name: str, default: str = "") -> str:
    for f in flags:
        if f.startswith(f"--{name}="):
            return f.split("=", 1)[1]
    return default


def require_staging_project(project: str) -> None:
    """ABORT unless the active project is exactly ``ayma-staging`` — this sweep
    writes and must never run against prod (or any other project)."""
    if project != _STAGING_PROJECT:
        raise SystemExit(
            f"refusing to run: project must be exactly {_STAGING_PROJECT!r}, "
            f"got {project!r}. Pass --project=ayma-staging."
        )


def _print_report(report) -> None:
    print(f"\nindexed {report.node_count} nodes")
    print(f"=== PAIRS FOUND: {report.found} ===")
    print(f"--- WOULD MERGE ({len(report.merged)}) ---" if report.dry_run
          else f"--- MERGED ({len(report.merged)}) ---")
    for a, b in report.merged:
        print(f"  {a}  <=  {b}")
    print(f"--- RAISED for the user to decide ({len(report.raised)}) ---")
    for a, b, reason in report.raised:
        print(f"  {a}  ?  {b}  ({reason})")
    if report.dry_run:
        print("\n(dry-run: nothing was written)")


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

    dry_run = "--apply" not in flags

    import person_graph_dedupe_sweep as sweep
    from db import get_db

    db = get_db()
    report = asyncio.run(sweep.sweep_user(db, uid, dry_run=dry_run, judge=True))
    _print_report(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
