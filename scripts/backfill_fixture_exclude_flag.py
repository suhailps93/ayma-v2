#!/usr/bin/env python3
"""Backfill exclude_from_explore flag for demo-edge fixture accounts.

This script performs an idempotent, reversible backfill that tags already-seeded
demo-edge-* corner-case fixture accounts in live Firestore (project ayma-ai) with
`exclude_from_explore: True` on their top-level users/{uid} document so they drop
out of real users' Explore feeds. Running with --revert removes the flag instead.

Key features:
- Idempotent and reversible with --revert flag.
- Writes to live Firestore via Application Default Credentials (ADC).
- Targets project ayma-ai.
- Tags accounts carrying demo_edge==True whose uid starts with "demo-edge-".
"""

import argparse
import os
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "functions" / "bootstrap"))
os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "ayma-ai")

from db import get_db  # noqa: E402
from firebase_admin import firestore  # noqa: E402
from google.cloud.firestore_v1.base_query import FieldFilter  # noqa: E402

KNOWN_EDGE_UIDS = (
    "demo-edge-nophoto",
    "demo-edge-agemin",
    "demo-edge-ageover",
    "demo-edge-orient",
    "demo-edge-locout",
    "demo-edge-mutual",
)


def _target_uids(db) -> list[str]:
    """Return a sorted union of UIDs matching the demo-edge criteria."""
    target_set = set()

    for uid in KNOWN_EDGE_UIDS:
        if uid.startswith("demo-edge-"):
            if db.collection("users").document(uid).get().exists:
                target_set.add(uid)

    query = db.collection("users").where(filter=FieldFilter("demo_edge", "==", True))
    for snap in query.stream():
        if snap.id.startswith("demo-edge-"):
            target_set.add(snap.id)

    return sorted(list(target_set))


def run(revert: bool) -> int:
    """Backfill or revert the exclude_from_explore flag for demo-edge accounts."""
    db = get_db()
    uids = _target_uids(db)

    for uid in uids:
        doc_ref = db.collection("users").document(uid)
        if revert:
            doc_ref.set({"exclude_from_explore": firestore.DELETE_FIELD}, merge=True)
            print(f"[revert] {uid}: removed exclude_from_explore")
        else:
            doc_ref.set({"exclude_from_explore": True}, merge=True)
            print(f"[backfill] {uid}: exclude_from_explore=True")

    action = "reverted" if revert else "tagged"
    print(f"[done] {action} {len(uids)} demo-edge fixture doc(s)")
    return 0


def main() -> int:
    """Parse command line arguments and execute the script."""
    parser = argparse.ArgumentParser(
        description="Backfill or revert exclude_from_explore flag for demo-edge users."
    )
    parser.add_argument(
        "--revert",
        action="store_true",
        help="remove the exclude_from_explore flag instead of setting it",
    )
    args = parser.parse_args()
    return run(args.revert)


if __name__ == "__main__":
    raise SystemExit(main())
