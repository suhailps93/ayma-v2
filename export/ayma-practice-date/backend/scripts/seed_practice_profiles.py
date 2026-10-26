#!/usr/bin/env python3
"""Seed the Practice Date demo profiles into Firestore (hackathon deliverable B).

Writes the four judge-ready demo profiles defined in ``practice_seed.py`` so the
Practice button has something to simulate during the demo. Each profile carries
NEVER-LOAD needles (fabricated address, phone, email, coordinates, other people,
private/ai-only notes — nobody real) so a judge can verify none of it leaks into
the persona.

Requires a Firestore handle. In this public subset the ``db`` module (Ayma's
Firestore client / app bootstrap) is **private core and NOT included** — see the
repo README. To run the seed you supply your own Firestore client; this script
imports ``db.get_db`` exactly as it does in Ayma's backend. The reusable,
testable part is ``practice_seed.seed(db)``, which is included and is exercised
offline by the test suite against the in-memory ``FakeDb``.

Usage (with a Firestore-backed ``db`` module on the path and credentials set):

    python3 scripts/seed_practice_profiles.py

No model names, no secrets. Idempotent.
"""

from __future__ import annotations

import os
import sys

# backend/ (parent of scripts/) holds practice_seed.py.
_BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _BACKEND)


def main() -> int:
    from db import get_db  # noqa: E402 - Ayma private core (not included here)
    import practice_seed  # noqa: E402

    uids = practice_seed.seed(get_db())
    print(f"Seeded {len(uids)} Practice Date demo profiles:")
    for uid in uids:
        print(f"  - {uid}")
    print(
        "\nOpen any of these profiles in the app and tap Practice to start a "
        "simulated conversation."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
