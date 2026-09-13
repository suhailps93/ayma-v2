"""One-off backfill: flip legacy `ai_only` skill/steering wiki pages to
`private` (the founder's visibility-defaults correction — see the commit that
added this file).

`wiki_schema.json`'s `default_visibility` for `web_findings`, `face_analysis`,
`body_analysis`, `physical_profile`, `interactions`, `steering`, and
`sensitive` moved from `ai_only` to `private`: content the user themselves
shared, or a skill output they can run themselves, should be at least visible
to them — `ai_only` (never shown to any client, ever) is reserved for content
Ayma infers about the user on her own. New writes already land as `private`
(skill_memory.py, steering_ops.py); this script fixes up pages written before
that change, which are still sitting at `visibility: "ai_only"` in Firestore.

Iterates every `users/{uid}/wiki_pages/{pageId}` doc across every user. For
any doc whose `page_type` is one of the seven above AND whose current
`visibility` is exactly `"ai_only"`, merge-writes `visibility: "private"`.
Anything else (a different page_type, or a page already `private`/`public`/
some other explicit value) is left untouched.

Usage: ``python3 _backfill_skill_visibility.py`` — this is a real, one-shot
write (no dry-run flag; the founder wants it live now). Run once. Safe to
re-run (idempotent — a second pass finds nothing left at `ai_only` among the
targeted types and does nothing).
"""

from __future__ import annotations

import google.auth
from google.cloud import firestore

PROJECT = "ayma-ai"

TARGET_PAGE_TYPES = frozenset(
    {
        "web_findings",
        "face_analysis",
        "body_analysis",
        "physical_profile",
        "interactions",
        "steering",
        "sensitive",
    }
)

OLD_VISIBILITY = "ai_only"
NEW_VISIBILITY = "private"


def main() -> None:
    credentials, _project = google.auth.default()
    db = firestore.Client(project=PROJECT, credentials=credentials)

    total_checked = 0
    total_updated = 0
    per_type: dict[str, int] = {}

    for user_snap in db.collection("users").stream():
        uid = user_snap.id
        pages_col = db.collection("users").document(uid).collection("wiki_pages")
        for page_snap in pages_col.stream():
            total_checked += 1
            data = page_snap.to_dict() or {}
            page_type = data.get("page_type")
            visibility = data.get("visibility")
            if page_type not in TARGET_PAGE_TYPES:
                continue
            if visibility != OLD_VISIBILITY:
                continue

            page_snap.reference.set({"visibility": NEW_VISIBILITY}, merge=True)
            total_updated += 1
            per_type[page_type] = per_type.get(page_type, 0) + 1
            print(
                f"uid={uid} page={page_snap.id} page_type={page_type} "
                f"visibility: {OLD_VISIBILITY!r} -> {NEW_VISIBILITY!r}"
            )

    print("\n--- backfill summary ---")
    print(f"wiki pages checked: {total_checked}")
    print(f"wiki pages updated: {total_updated}")
    for page_type in sorted(TARGET_PAGE_TYPES):
        print(f"  {page_type}: {per_type.get(page_type, 0)}")


if __name__ == "__main__":
    main()
