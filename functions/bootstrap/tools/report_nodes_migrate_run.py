"""Run the report-to-nodes migration for one user against the live Firestore.

Converts a user's legacy REPORT LUMPS into per-element, source-tagged graph
nodes (the Nov 18 ruling: "reports … should be as notes"):

  * ``skill_memory.migrate_web_findings``   — the web-search lump
    (``emergent.skill.web_findings``) → per-element ``emergent.webfind.*`` notes
    re-split from the stored dive digest, each carrying its source link.
  * ``skill_memory.migrate_appearance_findings`` — the face/body lumps
    (``emergent.skill.{face,body}_analysis``) → per-finding
    ``emergent.skill.{face,body}_analysis.*`` notes, each tagged with its source
    photo.

Both are lossless + idempotent and only re-split from already-stored structured
sources. This does NOT touch the ``appearance_reports`` doc store (that founder
call stands) — it converts GRAPH data only.

Usage (from functions/bootstrap/, with the Firestore project configured via
GOOGLE_CLOUD_PROJECT + credentials):

    GOOGLE_CLOUD_PROJECT=ayma-staging PERSON_GRAPH_READS=true \
        PYTHONPATH=. python3 tools/report_nodes_migrate_run.py <uid> [--dry-run]

--dry-run : report the current lumps + what WOULD be written, change nothing.
(default) : run both migrations, then print the before/after lump + node counts.
"""

from __future__ import annotations

import sys

_LUMPS = (
    "emergent.skill.web_findings",
    "emergent.skill.face_analysis",
    "emergent.skill.body_analysis",
)


def _snapshot(store, db, uid: str) -> dict:
    overlay = store.load_overlay(db, uid)
    return {
        "total": len(overlay),
        "lumps": [nid for nid in _LUMPS if nid in overlay],
        "webfind_elements": sorted(
            n for n in overlay
            if n.startswith("emergent.webfind.") and not n.startswith("emergent.webfind.report.")
        ),
        "face_elements": sorted(n for n in overlay if n.startswith("emergent.skill.face_analysis.")),
        "body_elements": sorted(n for n in overlay if n.startswith("emergent.skill.body_analysis.")),
    }


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    if len(args) != 1:
        print(__doc__)
        return 2
    uid = args[0]

    import skill_memory as sm
    import person_graph_store as store
    from db import get_db

    db = get_db()
    before = _snapshot(store, db, uid)
    print(f"BEFORE {uid}: {before['total']} nodes; lumps present: {before['lumps']}")

    if "--dry-run" in flags:
        print("[dry-run] nothing written.")
        return 0

    web_n = sm.migrate_web_findings(db, uid)
    app_n = sm.migrate_appearance_findings(db, uid)
    after = _snapshot(store, db, uid)
    print(f"migrate_web_findings wrote {web_n} per-element nodes")
    print(f"migrate_appearance_findings wrote {app_n} per-element nodes")
    print(f"AFTER  {uid}: {after['total']} nodes; lumps remaining: {after['lumps']}")
    print(f"  webfind element nodes: {len(after['webfind_elements'])}")
    print(f"  face element nodes:    {len(after['face_elements'])}")
    print(f"  body element nodes:    {len(after['body_elements'])}")
    if after["lumps"]:
        print(f"!! WARNING: lumps still present after migration: {after['lumps']}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
