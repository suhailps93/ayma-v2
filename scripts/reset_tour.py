#!/usr/bin/env python3
"""Inspect or reset feature tour seen-state (users/{uid}/profile/main.seen_tour_features).

Allows QA / Scout to inspect and reset feature tour seen state so the first-run
walkthrough or individual feature spotlights (such as 'async_voice') can be
re-tested on-device.

Usage:
    GOOGLE_CLOUD_PROJECT=ayma-staging python3 scripts/reset_tour.py --uid demo-test1 --inspect
    GOOGLE_CLOUD_PROJECT=ayma-staging python3 scripts/reset_tour.py --uid demo-test1 --unsee async_voice
    GOOGLE_CLOUD_PROJECT=ayma-staging python3 scripts/reset_tour.py --uid demo-test1 --reset-all
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "functions" / "bootstrap"))

from db import get_db  # noqa: E402
from google.cloud import firestore  # noqa: E402


def _profile_ref(db, uid: str):
    return db.collection("users").document(uid).collection("profile").document("main")


def inspect_tour(db, uid: str) -> None:
    snap = _profile_ref(db, uid).get()
    if not snap.exists:
        print(f"User {uid} profile/main does not exist.")
        return
    data = snap.to_dict() or {}
    seen = data.get("seen_tour_features", [])
    print(f"User {uid} seen_tour_features ({len(seen)} items):")
    for f in seen:
        print(f"  - {f}")


def unsee_feature(db, uid: str, feature_id: str) -> None:
    ref = _profile_ref(db, uid)
    ref.update({"seen_tour_features": firestore.ArrayRemove([feature_id])})
    print(f"Removed {feature_id!r} from seen_tour_features for {uid}.")


def reset_all(db, uid: str) -> None:
    ref = _profile_ref(db, uid)
    ref.update({"seen_tour_features": firestore.DELETE_FIELD})
    print(f"Cleared seen_tour_features for {uid} (full first-run walkthrough will re-trigger).")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uid", default="demo-test1", help="User UID (default: demo-test1)")
    parser.add_argument("--inspect", action="store_true", help="Print current seen_tour_features")
    parser.add_argument("--unsee", metavar="FEATURE_ID", help="Remove a specific feature id so its spotlight re-triggers")
    parser.add_argument("--reset-all", action="store_true", help="Clear all seen features so full walkthrough re-triggers")

    args = parser.parse_args()
    if not (args.inspect or args.unsee or args.reset_all):
        parser.print_help()
        sys.exit(1)

    db = get_db()
    if args.inspect:
        inspect_tour(db, args.uid)
    elif args.unsee:
        unsee_feature(db, args.uid, args.unsee)
    elif args.reset_all:
        reset_all(db, args.uid)


if __name__ == "__main__":
    main()
