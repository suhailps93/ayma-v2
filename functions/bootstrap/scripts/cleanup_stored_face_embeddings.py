"""One-time cleanup script (ops, run once at merge):

Delete stored embedding/dim on user_media + photo_notes and
face_verification.embedding across all users in Firestore, and report counts.
"""

from __future__ import annotations

import argparse
import sys
from firebase_admin import firestore


def cleanup_embeddings(db, *, dry_run: bool = True) -> dict[str, int]:
    """Scrub face vector fields across all user records and subcollections."""
    users_scanned = 0
    fv_deleted = 0
    media_deleted = 0
    notes_deleted = 0

    users_stream = db.collection("users").stream()
    for user_snap in users_stream:
        users_scanned += 1
        user_ref = user_snap.reference
        data = user_snap.to_dict() or {}

        # 1. users/{uid}.face_verification.embedding
        fv = data.get("face_verification")
        if isinstance(fv, dict) and "embedding" in fv:
            fv_deleted += 1
            if not dry_run:
                user_ref.update({"face_verification.embedding": firestore.DELETE_FIELD})

        # 2. users/{uid}/user_media
        for media_snap in user_ref.collection("user_media").stream():
            m_data = media_snap.to_dict() or {}
            updates = {}
            if "embedding" in m_data:
                updates["embedding"] = firestore.DELETE_FIELD
            if "dim" in m_data:
                updates["dim"] = firestore.DELETE_FIELD
            if updates:
                media_deleted += 1
                if not dry_run:
                    media_snap.reference.update(updates)

        # 3. users/{uid}/photo_notes
        for note_snap in user_ref.collection("photo_notes").stream():
            n_data = note_snap.to_dict() or {}
            if "embedding" in n_data:
                notes_deleted += 1
                if not dry_run:
                    note_snap.reference.update({"embedding": firestore.DELETE_FIELD})

    report = {
        "users_scanned": users_scanned,
        "face_verification_embeddings_deleted": fv_deleted,
        "user_media_embeddings_deleted": media_deleted,
        "photo_notes_embeddings_deleted": notes_deleted,
        "dry_run": 1 if dry_run else 0,
    }
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Scrub stored face embeddings from Firestore.")
    parser.add_argument("--apply", action="store_true", help="Apply updates (default is dry-run)")
    args = parser.parse_args()

    import firebase_admin
    try:
        firebase_admin.get_app()
    except ValueError:
        firebase_admin.initialize_app()

    db = firestore.client()
    dry_run = not args.apply

    print(f"Running face embedding cleanup (dry_run={dry_run})...")
    counts = cleanup_embeddings(db, dry_run=dry_run)
    print("Cleanup summary:")
    for k, v in counts.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
