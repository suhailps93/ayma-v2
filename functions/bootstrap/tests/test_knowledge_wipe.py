"""Unit tests for "delete everything Ayma knows" (knowledge_wipe.py) — the
2026-09-20 founder request: archive the learned/derived data into a
timestamped ``archived_knowledge/{uid}/snapshots/{archive_id}`` snapshot,
then reset the live copies, while the account/profile/photos/credits/login
stay untouched."""

import knowledge_wipe
import schema
from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb


def _patch_sentinels(monkeypatch):
    monkeypatch.setattr(knowledge_wipe.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(knowledge_wipe.firestore, "DELETE_FIELD", DELETE_FIELD)


def _seed(db, uid):
    db.docs[("users", uid)] = {
        "created_at": 1,
        "trust_flags": ["self_contradiction"],
        "face_verification": {"embedding": [0.1, 0.2]},
        "token_usage": {"total": 500},
        "instagram_access_token": "secret-token",
    }
    db.docs[("users", uid, "profile", "main")] = {"name": "Jo", "photos": ["m1"]}
    db.docs[("users", uid, "user_media", "m1")] = {"path": "uploads/u/m1.jpg"}
    db.docs[("users", uid, "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", uid, "wiki_pages", "career", "versions", "v1")] = {
        "created_at_ms": 1
    }
    db.docs[("users", uid, "raw_turns", "s1")] = {"turn_count": 2}
    db.docs[("users", uid, "chat_messages", "m1")] = {"role": "user"}
    db.docs[("users", uid, "appearance_reports", "r1")] = {"summary": "x"}
    db.docs[("users", uid, "deep_dives", "uid_other")] = {"digest": "y"}
    db.docs[("users", uid, "skill_runs", "photo_edit")] = {"count": 1}
    db.docs[("users", uid, "oauth_tokens", "google")] = {"token": "g-secret"}
    db.docs[("users", uid, "match_candidates", "c1")] = {"score": 0.9}
    db.docs[("feedback", "f1")] = {"uid": uid, "note": "too pushy"}
    db.docs[("feedback", "f2")] = {"uid": "someone-else", "note": "n/a"}


def test_wipe_knowledge_archives_and_resets_only_the_learned_data(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed(db, "u1")

    out = knowledge_wipe.wipe_knowledge(db, "u1")
    assert out["ok"] is True
    archive_id = out["archive_id"]

    # --- wiped live ---------------------------------------------------
    assert ("users", "u1", "wiki_pages", "career") not in db.docs
    assert ("users", "u1", "wiki_pages", "career", "versions", "v1") not in db.docs
    assert ("users", "u1", "raw_turns", "s1") not in db.docs
    assert ("users", "u1", "chat_messages", "m1") not in db.docs
    assert ("users", "u1", "appearance_reports", "r1") not in db.docs
    assert ("users", "u1", "deep_dives", "uid_other") not in db.docs
    assert ("users", "u1", "skill_runs", "photo_edit") not in db.docs
    assert "trust_flags" not in db.docs[("users", "u1")]
    assert "face_verification" not in db.docs[("users", "u1")]
    assert ("feedback", "f1") not in db.docs

    # --- NOT wiped: account/identity plumbing, photos, profile --------
    assert db.docs[("users", "u1", "profile", "main")] == {
        "name": "Jo", "photos": ["m1"]
    }
    assert db.docs[("users", "u1", "user_media", "m1")] == {
        "path": "uploads/u/m1.jpg"
    }
    assert db.docs[("users", "u1", "oauth_tokens", "google")] == {
        "token": "g-secret"
    }
    assert db.docs[("users", "u1", "match_candidates", "c1")] == {"score": 0.9}
    assert db.docs[("users", "u1")]["token_usage"] == {"total": 500}
    assert db.docs[("users", "u1")]["instagram_access_token"] == "secret-token"
    assert db.docs[("feedback", "f2")] == {"uid": "someone-else", "note": "n/a"}

    # --- archived, admin-only, fully round-trips what was live --------
    base = ("archived_knowledge", "u1", "snapshots", archive_id)
    assert db.docs[base]["original_uid"] == "u1"
    assert db.docs[base]["archived_at"] is SERVER_TIMESTAMP
    assert db.docs[base]["fields"] == {
        "trust_flags": ["self_contradiction"],
        "face_verification": {"embedding": [0.1, 0.2]},
    }
    assert db.docs[base + ("wiki_pages", "career")] == {"ai_body": "Nurse."}
    assert db.docs[base + ("wiki_pages", "career", "versions", "v1")] == {
        "created_at_ms": 1
    }
    assert db.docs[base + ("raw_turns", "s1")] == {"turn_count": 2}
    assert db.docs[base + ("chat_messages", "m1")] == {"role": "user"}
    assert db.docs[base + ("appearance_reports", "r1")] == {"summary": "x"}
    assert db.docs[base + ("deep_dives", "uid_other")] == {"digest": "y"}
    assert db.docs[base + ("skill_runs", "photo_edit")] == {"count": 1}
    assert db.docs[base + ("feedback", "f1")] == {"uid": "u1", "note": "too pushy"}


def test_wipe_knowledge_can_run_more_than_once_with_distinct_snapshots(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed(db, "u1")

    first = knowledge_wipe.wipe_knowledge(db, "u1")
    # re-seed a bit of new "knowledge" as if the user kept using the app
    db.docs[("users", "u1", "wiki_pages", "hobbies")] = {"ai_body": "Cycling."}
    second = knowledge_wipe.wipe_knowledge(db, "u1")

    assert first["archive_id"] != second["archive_id"]
    assert (
        "archived_knowledge", "u1", "snapshots", first["archive_id"],
        "wiki_pages", "career",
    ) in db.docs
    assert (
        "archived_knowledge", "u1", "snapshots", second["archive_id"],
        "wiki_pages", "hobbies",
    ) in db.docs


def test_wipe_knowledge_does_not_touch_shared_matches_or_dm_threads(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed(db, "u1")
    db.docs[("matches", "u1__u2")] = {"uids": ["u1", "u2"]}
    db.docs[("dm_threads", "u1__u2")] = {"participants": ["u1", "u2"]}

    knowledge_wipe.wipe_knowledge(db, "u1")

    assert db.docs[("matches", "u1__u2")] == {"uids": ["u1", "u2"]}
    assert db.docs[("dm_threads", "u1__u2")] == {"participants": ["u1", "u2"]}


def test_knowledge_subcollections_manifest_excludes_account_plumbing():
    """Locks in the line-drawing documented in knowledge_wipe.py: profile and
    user_media (content), oauth_tokens/notification_prefs (plumbing), and
    match_candidates/likes/explore_passed (matching mechanics) are all
    ACCOUNT_SUBCOLLECTIONS but must NOT be part of the knowledge-wipe set."""
    excluded = {
        schema.PROFILE, schema.USER_MEDIA, schema.OAUTH_TOKENS,
        schema.NOTIFICATION_PREFS, schema.MATCH_CANDIDATES, schema.LIKES,
        schema.EXPLORE_PASSED, schema.NOTIFICATIONS,
    }
    assert excluded.isdisjoint(set(schema.KNOWLEDGE_SUBCOLLECTIONS))
    assert set(schema.KNOWLEDGE_SUBCOLLECTIONS) <= set(schema.ACCOUNT_SUBCOLLECTIONS)
