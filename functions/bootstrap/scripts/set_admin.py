#!/usr/bin/env python3
"""Grant / revoke the ``admin: true`` Firebase custom claim (ARCHITECTURE.md
§3.5). Manual / script-based only — there is no self-serve admin signup.

Usage (from functions/bootstrap/, with GOOGLE_APPLICATION_CREDENTIALS set):

    python scripts/set_admin.py <uid|email>            # grant
    python scripts/set_admin.py <uid|email> --revoke   # revoke
"""

from __future__ import annotations

import sys

import firebase_admin
from firebase_admin import auth


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 1
    target, revoke = argv[0], "--revoke" in argv[1:]

    if not firebase_admin._apps:
        firebase_admin.initialize_app()

    user = (
        auth.get_user_by_email(target)
        if "@" in target
        else auth.get_user(target)
    )
    claims = dict(user.custom_claims or {})
    if revoke:
        claims.pop("admin", None)
    else:
        claims["admin"] = True
    auth.set_custom_user_claims(user.uid, claims or None)
    print(
        f"{'revoked' if revoke else 'granted'} admin for {user.uid} "
        f"({user.email or 'no email'})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
