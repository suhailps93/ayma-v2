#!/usr/bin/env python3
"""Seed the Practice Date demo profiles into Firestore (hackathon deliverable B).

Writes the four judge-ready demo profiles defined in
``functions/bootstrap/practice_seed.py`` so the Practice button has something to
simulate during the demo. Each profile carries NEVER-LOAD needles (address,
phone, email, coordinates, other people, private/ai-only notes) so a judge can
verify none of it leaks into the persona.

Usage (from the repo root, with Firestore credentials available — Cloud Run
identity when deployed, GOOGLE_APPLICATION_CREDENTIALS locally):

    python3 scripts/seed_practice_profiles.py

No model names, no secrets. Idempotent.
"""

from __future__ import annotations

import os
import sys

_BOOTSTRAP = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "functions",
    "bootstrap",
)
sys.path.insert(0, _BOOTSTRAP)


def main() -> int:
    from db import get_db  # noqa: E402 - needs the path insert above
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
