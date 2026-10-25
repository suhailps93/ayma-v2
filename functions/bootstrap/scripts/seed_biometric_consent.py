#!/usr/bin/env python3
"""Record the mandatory biometric consent for one account server-side, so the
Google Play reviewer account opens straight on the main screen instead of the
consent screen (docs/PLAY_REVIEWER_ACCESS.md). Uses the same validation and
record shape as ``POST /biometric-consent`` (``biometric_consent.record``),
tagged ``source: admin_seed``. Manual only; re-run after a consent-version
bump.

Usage (from functions/bootstrap/, with GOOGLE_APPLICATION_CREDENTIALS set):

    python scripts/seed_biometric_consent.py <uid|email> [--region US]
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import firebase_admin  # noqa: E402
from firebase_admin import auth, firestore  # noqa: E402


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 1
    target = argv[0]
    region = ""
    if "--region" in argv[1:]:
        idx = argv.index("--region")
        if idx + 1 >= len(argv):
            print("--region needs a two-letter country code")
            return 1
        region = argv[idx + 1]

    if not firebase_admin._apps:
        firebase_admin.initialize_app()

    import biometric_consent

    user = auth.get_user_by_email(target) if "@" in target else auth.get_user(target)
    try:
        biometric_consent.record(
            firestore.client(), user.uid,
            agreed=True,
            version=biometric_consent.CONSENT_VERSION,
            region=region,
            source=biometric_consent.SOURCE_ADMIN_SEED,
        )
    except biometric_consent.ConsentError as exc:
        print(f"refused: {exc}")
        return 1
    print(
        f"biometric consent {biometric_consent.CONSENT_VERSION} recorded for "
        f"{user.uid} ({user.email or 'no email'})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
