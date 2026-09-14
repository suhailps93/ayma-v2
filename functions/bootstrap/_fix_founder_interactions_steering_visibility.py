"""One-off: correct the founder's own `interactions` and `steering` wiki
pages, which predate the server-side `ai_only` enforcement added alongside
this script (see `wiki_ingest.py::_force_ai_only_page_types`,
`skill_memory.py::note_interaction`, `steering_ops.py::add_rule`).

Both page types default to `ai_only` now — `interactions` is Ayma's own
behavioural inference about the user, `steering` is a standing instruction
about the user, neither is meant to be user-visible by default (the
founder's own complaint: "Let's keep interactions ai only by default. It's
too much sensitive information about the user", later extended explicitly to
`steering` too). New writes to either page are already forced to `ai_only`;
this fixes the founder's own two pages, written before that change, which
were still sitting at `visibility: "private"` in Firestore (and were showing
up in the normal Story tab as a result).

Scope: exactly one user (the founder), exactly the `interactions` and
`steering` page ids. Not a general backfill across every user — the founder
asked to have their own account corrected now; a broader backfill across
every user's existing pages is a separate call the founder can make later if
wanted (existing users' pages would otherwise self-correct at their next
wiki re-ingest, since the write path itself is now fixed).

Usage: ``python3 _fix_founder_interactions_steering_visibility.py`` — a real,
one-shot write. Safe to re-run (idempotent — a second pass finds both pages
already `ai_only` and does nothing).
"""

from __future__ import annotations

import google.auth
from google.cloud import firestore

PROJECT = "ayma-ai"
UID = "iWhWjiWhEpU7iyu9B9vy7GlT0PD2"
PAGE_IDS = ("interactions", "steering")
NEW_VISIBILITY = "ai_only"


def main() -> None:
    credentials, _project = google.auth.default()
    db = firestore.Client(project=PROJECT, credentials=credentials)

    for page_id in PAGE_IDS:
        ref = (
            db.collection("users")
            .document(UID)
            .collection("wiki_pages")
            .document(page_id)
        )
        snap = ref.get()
        if not snap.exists:
            print(f"{page_id}: no such page, skipping")
            continue
        before = (snap.to_dict() or {}).get("visibility")
        if before == NEW_VISIBILITY:
            print(f"{page_id}: already {NEW_VISIBILITY}, no-op")
            continue
        ref.set({"visibility": NEW_VISIBILITY}, merge=True)
        print(f"{page_id}: visibility {before!r} -> {NEW_VISIBILITY!r}")


if __name__ == "__main__":
    main()
