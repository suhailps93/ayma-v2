#!/usr/bin/env python3
"""Seed the `demo-edge-*` corner-case accounts the E2E harness drives.

These exercise matching/explore edges that the three "complete" demo accounts
(docs/DEMO_ACCOUNTS.md) can't express. They are VIEWED by Daniel (demo-test1,
a man seeking women, 29, San Jose, partner age 24-36, relocation "Within ~50 km"
= stay-put), never signed into, so each only needs a profile + questionnaire +
taste + a scored match doc with Daniel — no auth user, photos or LLM content.

Accounts (all women unless noted; birthdates chosen for "today" ~2026):
  demo-edge-nophoto  30, seeks Men, San Jose, compatible, NO photos   -> APPEARS, score > 0
  demo-edge-agemin   24 (== Daniel's min), seeks Men, San Jose        -> APPEARS, score > 0
  demo-edge-ageover  38 (> Daniel's max 36), seeks Men, San Jose      -> EXCLUDED, 0%
  demo-edge-orient   30, seeks WOMEN (one-sided orientation)          -> EXCLUDED, 0%
  demo-edge-locout   30, seeks Men, New York (outside radius)         -> EXCLUDED, 0%
  demo-edge-mutual   30, seeks Men, San Jose, compatible, MUTUAL like -> APPEARS, "Match"

Idempotent. `--reset` removes the demo-edge-* accounts and their match docs with
Daniel, then re-seeds. Writes go to live Firestore via Application Default
Credentials (same as seed_demo_accounts.py); no secrets are read.
"""
import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # for seed_demo_accounts

import seed_demo_accounts as sda  # noqa: E402

DANIEL_UID = "demo-test1"
SJ = "San Jose, United States"
# The ONLY account in explore_fixture_bypass_uids (config.py). It sees the
# demo-edge-* fixtures; the demo/judge accounts (demo-test1/2/3) do NOT. The
# edge suite signs in as this viewer. Mirrors Daniel (man seeking women, 29,
# San Jose, partner 24-36) so the fixtures score identically.
E2E_VIEWER_UID = "demo-e2e-viewer"


def _persona(uid, name, *, gender="Woman", interested_in=("Men",),
             birthdate, headline, location=SJ, amin=22, amax=40):
    first, last = (name.split(" ", 1) + [""])[:2]
    return {
        "uid": uid,
        "name": name,
        "first_name": first,
        "last_name": last,
        "gender": gender,
        "interested_in": list(interested_in),
        "birthdate": birthdate,
        "headline": headline,
        "partner_age_min": amin,
        "partner_age_max": amax,
        "location": location,
    }


# birthdate month/day fixed mid-year so the integer age is unambiguous.
EDGE = {
    "demo-edge-nophoto": _persona(
        "demo-edge-nophoto", "Nadia Okafor", birthdate="1996-05-15",
        headline="Illustrator, no photos yet"),
    "demo-edge-agemin": _persona(
        "demo-edge-agemin", "Mara Lindqvist", birthdate="2002-05-15",
        headline="Grad student, exactly at the age floor"),
    "demo-edge-ageover": _persona(
        "demo-edge-ageover", "Teresa Alvarez", birthdate="1988-05-15",
        headline="Architect, just past the age ceiling"),
    "demo-edge-orient": _persona(
        "demo-edge-orient", "Robin Shaw", interested_in=("Women",),
        birthdate="1996-05-15", headline="Not seeking men (one-sided)"),
    "demo-edge-locout": _persona(
        "demo-edge-locout", "Elena Rossi", birthdate="1996-05-15",
        headline="Lives in New York, won't relocate",
        location="New York, United States"),
    "demo-edge-mutual": _persona(
        "demo-edge-mutual", "Hana Kim", birthdate="1996-05-15",
        headline="Strong match who already liked you back"),
}

# Which accounts are expected to pass the hard gates (for the --reset log only).
EXPECT_PASS = {"demo-edge-nophoto", "demo-edge-agemin", "demo-edge-mutual"}

# The dedicated BYPASS viewer login — the only uid in
# explore_fixture_bypass_uids, so it (and only it) sees the demo-edge-* fixtures.
# A complete profile mirroring Daniel so the edge matches score identically, with
# a real auth login. Flagged exclude_from_explore so it never pollutes real feeds.
VIEWER_UID = E2E_VIEWER_UID
VIEWER = {
    **_persona(VIEWER_UID, "Evan Carter", gender="Man",
               interested_in=("Women",), birthdate="1997-02-10",
               headline="E2E bypass viewer", amin=24, amax=36),
    "email": "demo-e2e-viewer@gmail.com",
}


# A short, Daniel-compatible life story so a non-gated pair scores > 0
# (score_pair refuses to run without a wiki on both sides). Gated pairs are
# zeroed by the hard dealbreaker regardless of what the wiki says.
_WIKI_BODY = (
    "Warm, creative homebody in San Jose. Secure and gentle in conflict, "
    "processes feelings out loud, values honesty, slowness and craft. Wants a "
    "committed long-term relationship and children in the next few years. "
    "Spends weekends on art, cooking from scratch and small folk shows; reads "
    "a lot of fiction. Looking to build a quiet, intentional life together."
)


def _write_wiki(db, uid: str) -> None:
    db.collection("users").document(uid).collection("wiki_pages").document(
        "identity"
    ).set(
        {
            "page_type": "identity",
            "title": "Identity",
            "ai_body": _WIKI_BODY,
            "visibility": "public",
            "updated_at": sda._now(),
        },
        merge=True,
    )


def _reset(db):
    from pair_key import sorted_pair_key

    # "demo-edge-viewer" is a legacy name for the viewer (now demo-e2e-viewer).
    for uid in list(EDGE) + [VIEWER_UID, "demo-edge-viewer"]:
        # delete the viewer×uid match + the account's subcollections + doc. Also
        # clear any legacy Daniel×edge match from an earlier seed.
        for other in (E2E_VIEWER_UID, DANIEL_UID):
            if other != uid:
                db.collection("matches").document(
                    sorted_pair_key(other, uid)).delete()
        user = db.collection("users").document(uid)
        for sub in ("profile", "questionnaire", "wiki_pages", "user_media"):
            for d in user.collection(sub).stream():
                d.reference.delete()
        user.delete()
        sda._log(f"[edge:reset] removed {uid}")
    # The viewer has a real auth login; remove it too.
    from firebase_admin import auth as fb_auth
    for vuid in (VIEWER_UID, "demo-edge-viewer"):
        try:
            fb_auth.delete_user(vuid)
            sda._log(f"[edge:reset] removed auth user {vuid}")
        except Exception:  # noqa: BLE001 - absent is fine
            pass


def _set_mutual(db, uid):
    """Flip the viewer x uid match to a mutual like so the report reflects a
    mutual match (report_adapters / MatchReport read matches/{id}.status)."""
    from pair_key import sorted_pair_key

    db.collection("matches").document(
        sorted_pair_key(E2E_VIEWER_UID, uid)
    ).set({"status": "mutual_interest", "updated_at": sda._now()}, merge=True)
    sda._log(f"[edge:mutual] {uid} -> status=mutual_interest")


async def run(reset: bool) -> int:
    from db import get_db

    db = get_db()
    personas = sda._load_personas()
    qz = dict(personas["qz_shared_good"])  # Daniel-identical answers -> no soft gate

    if reset:
        _reset(db)

    sda._log("\n=== EDGE PHASE 1: profiles + questionnaire + wiki ===")
    for uid, p in EDGE.items():
        # Materialise the top-level users/{uid} doc. A document with only
        # subcollections is a "phantom" in Firestore and never appears in a
        # `collection("users").stream()`, so Explore (which streams users) would
        # silently skip the account.
        db.collection("users").document(uid).set(
            {
                "demo_edge": True,
                # Hides this fixture from real users' Explore (filtered in
                # functions/bootstrap/explore.py); a designated e2e/demo viewer
                # still sees it.
                "exclude_from_explore": True,
                "updated_at": sda._now(),
            },
            merge=True,
        )
        sda.write_profile_and_questionnaire(db, p, qz, p["location"])
        _write_wiki(db, uid)

    sda._log("\n=== EDGE PHASE 2: dedicated bypass viewer (demo-e2e-viewer) ===")
    db.collection("users").document(VIEWER_UID).set(
        {"demo_edge": True, "exclude_from_explore": True,
         "updated_at": sda._now()},
        merge=True,
    )
    sda.ensure_auth_user(VIEWER)
    sda.record_consent(db, VIEWER_UID)
    sda.write_profile_and_questionnaire(db, VIEWER, qz, VIEWER["location"])
    _write_wiki(db, VIEWER_UID)
    await sda.recompute_completeness(db, VIEWER_UID)
    sda.grant_credits(VIEWER_UID)
    sda._log(f"[edge:viewer] {VIEWER_UID} ({VIEWER['email']}) ready")

    sda._log("\n=== EDGE PHASE 3: matches (viewer x each edge) ===")
    for uid in EDGE:
        score = await sda.persist_match(db, E2E_VIEWER_UID, uid)
        expect = "pass>0" if uid in EXPECT_PASS else "gate->0"
        sda._log(f"[edge:match] {uid}: score={score} (expected {expect})")
    _set_mutual(db, "demo-edge-mutual")

    sda._log("\n=== EDGE PHASE 4: DM GIF fixture (Daniel↔Sofia thread) ===")
    _seed_dm_gif(db)

    sda._log("\n=== EDGE DONE ===")
    return 0


# A recognisable GIF URL so the e2e DM-gif test can find the inline gif bubble
# (Image.network) by its url, distinct from avatar photos (.jpg/.png).
_GIF_URL = "https://media.giphy.com/media/l0MYGb1LuZ3n7dRnO/giphy.gif"


def _seed_dm_gif(db):
    """Seed a GIF message in the Daniel↔Sofia DM thread so the e2e harness can
    assert the inline gif bubble on the real path (DM GIF feature §6.6). Fixed
    doc id → idempotent. Shape mirrors dm_ops.add_message for a 'gif' type."""
    from dm_schema import thread_id

    tid = thread_id("demo-test1", "demo-test2")
    db.collection("dm_threads").document(tid).set(
        {"uids": ["demo-test1", "demo-test2"], "updated_at": sda._now()},
        merge=True,
    )
    db.collection("dm_threads").document(tid).collection("messages").document(
        "e2e-gif-fixture"
    ).set(
        {
            "sender_uid": "demo-test1",
            "type": "gif",
            "body": "",
            "attachment_url": _GIF_URL,
            "attachment_path": "",
            "mime": "image/gif",
            "file_name": "e2e-test.gif",
            "size": 1024,
            "created_at": sda._now(),
        },
        merge=True,
    )
    sda._log(f"[edge:dm-gif] seeded gif message in thread {tid}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed demo-edge-* corner cases.")
    ap.add_argument("--reset", action="store_true",
                    help="remove demo-edge-* accounts + their match docs first")
    args = ap.parse_args()
    return asyncio.run(run(args.reset))


if __name__ == "__main__":
    raise SystemExit(main())
