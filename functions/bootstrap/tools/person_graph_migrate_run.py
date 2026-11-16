"""Run the person-graph migration for one user against the live Firestore.

Operational helper for the staging re-migration (Scout): after a migration-logic
change (e.g. the dedupe fix re-keyed emergent ids), re-run with --replace so the
stored overlay becomes exactly the fresh node set — dropping stale duplicate ids.

Usage (from functions/bootstrap/, against the configured Firestore project):

    PYTHONPATH=. python3 tools/person_graph_migrate_run.py <uid> --replace
    PYTHONPATH=. python3 tools/person_graph_migrate_run.py <uid> --dry-run

- --dry-run : build the overlay and print counts + a public-render audit, write
              nothing.
- --replace : persist as the WHOLE node set (drops stale ids). The safe mode for
              a re-migration while the graph is still migration-only (pre-switch).
- (neither) : merge the fresh output over the existing overlay.

It prints the node count, the per-provenance breakdown, and every PUBLIC bullet
the render would show, so the visibility audit is one glance.
"""

from __future__ import annotations

import sys


def _audit(db, uid: str) -> None:
    import person_graph_render as render
    import person_graph_store as store

    overlay = store.load_overlay(db, uid)
    g = store.effective(db, uid)
    prov: dict[str, int] = {}
    for n in overlay.values():
        p = n.get("provenance", "—")
        prov[p] = prov.get(p, 0) + 1
    print(f"overlay nodes: {len(overlay)}  by provenance: {prov}")

    pub = render.public_sections(g)
    n_pub = sum(len(s["bullets"]) for s in pub)
    print(f"public bullets: {n_pub}")
    for s in pub:
        for b in s["bullets"]:
            print(f"  [{s['page_type']:>14}] {b}")


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(__doc__)
        return 2
    uid = args[0]

    import person_graph_migrate as mig
    from db import get_db

    db = get_db()

    if "--dry-run" in flags:
        overlay = mig.migrate_user(db, uid, write=False)
        print(f"[dry-run] built {len(overlay)} nodes for {uid} (nothing written)")
        # show what the audit WOULD be by temporarily... just report counts:
        import person_graph as pg
        g = pg.effective_graph(overlay, intent=mig._profile_doc(db, uid).get("relationship_intent"))
        import person_graph_render as render
        pub = render.public_sections(g)
        n_pub = sum(len(s["bullets"]) for s in pub)
        print(f"[dry-run] would render {n_pub} public bullets")
        for s in pub:
            for b in s["bullets"]:
                print(f"  [{s['page_type']:>14}] {b}")
        return 0

    replace = "--replace" in flags
    overlay = mig.migrate_user(db, uid, write=True, replace=replace)
    print(f"migrated {uid}: wrote {len(overlay)} nodes (replace={replace})")
    _audit(db, uid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
