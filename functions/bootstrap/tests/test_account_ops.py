"""Unit tests for the soft-delete / recover subtree machinery, including the
2026-09-20 founder-request extensions: identity-mapping severance, shared
(matches/dm_threads) record snapshotting without touching the other party's
copy, and full-fidelity round-tripping of every per-user data category."""

import account_ops
from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb


def _patch_sentinels(monkeypatch):
    monkeypatch.setattr(account_ops.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(account_ops.firestore, "DELETE_FIELD", DELETE_FIELD)


def _seed_account(db, uid):
    db.docs[("users", uid)] = {
        "created_at": 1,
        "marketing_turn_count": 3,
        "trust_flags": ["x"],
    }
    db.docs[("users", uid, "profile", "main")] = {"name": "Jo"}
    db.docs[("users", uid, "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", uid, "wiki_pages", "career", "versions", "v1")] = {
        "created_at_ms": 1
    }
    db.docs[("users", uid, "raw_turns", "s1")] = {"turn_count": 2}
    db.docs[("users", uid, "pending_questions", "q1")] = {"status": "pending"}
    db.docs[("users", uid, "chat_messages", "m1")] = {"role": "user"}
    db.docs[("users", uid, "appearance_reports", "r1")] = {"summary": "x"}
    db.docs[("users", uid, "deep_dives", "uid_other")] = {"digest": "y"}
    db.docs[("users", uid, "skill_runs", "photo_edit")] = {"count": 1}
    db.docs[("users", uid, "user_media", "media1")] = {"path": "uploads/u1/a.jpg"}


def test_soft_delete_then_recover_round_trips(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed_account(db, "u1")

    out = account_ops.soft_delete(db, None, "u1")
    assert out["deleted"] is True
    # live tree gone, including the nested versions sub-subcollection
    assert ("users", "u1") not in db.docs
    assert ("users", "u1", "wiki_pages", "career") not in db.docs
    assert ("users", "u1", "wiki_pages", "career", "versions", "v1") not in db.docs
    assert ("users", "u1", "chat_messages", "m1") not in db.docs
    assert ("users", "u1", "deep_dives", "uid_other") not in db.docs
    # quarantine populated, including the nested level
    assert db.docs[("deleted_accounts", "u1")]["deleted_at"] is SERVER_TIMESTAMP
    assert db.docs[("deleted_accounts", "u1", "wiki_pages", "career")] == {
        "ai_body": "Nurse."
    }
    assert db.docs[
        ("deleted_accounts", "u1", "wiki_pages", "career", "versions", "v1")
    ] == {"created_at_ms": 1}
    assert db.docs[("deleted_accounts", "u1", "chat_messages", "m1")] == {
        "role": "user"
    }
    assert account_ops.is_recovery_required(db, "u1") is True

    rec = account_ops.recover(db, None, "u1")
    assert rec["restored"] is True
    assert db.docs[("users", "u1", "profile", "main")] == {"name": "Jo"}
    assert db.docs[("users", "u1", "raw_turns", "s1")] == {"turn_count": 2}
    assert db.docs[
        ("users", "u1", "wiki_pages", "career", "versions", "v1")
    ] == {"created_at_ms": 1}
    # quarantine cleared, bookkeeping stripped from the restored doc
    assert ("deleted_accounts", "u1") not in db.docs
    assert "deleted_at" not in db.docs[("users", "u1")]
    assert account_ops.is_recovery_required(db, "u1") is False


def test_soft_delete_is_a_noop_without_a_live_account():
    db = FakeDb()
    out = account_ops.soft_delete(db, None, "ghost")
    assert out["deleted"] is False


def test_is_recovery_required_needs_quarantine_and_no_live():
    db = FakeDb()
    assert account_ops.is_recovery_required(db, "u1") is False
    db.docs[("deleted_accounts", "u1")] = {"deleted_at": 1}
    assert account_ops.is_recovery_required(db, "u1") is True
    db.docs[("users", "u1")] = {"x": 1}
    assert account_ops.is_recovery_required(db, "u1") is False


# --- identity-mapping severance (the security-critical part) --------------


def test_soft_delete_clears_instagram_identity_mapping(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed_account(db, "u1")
    db.docs[("instagram_identities", "999")] = {
        "uid": "u1",
        "username": "jo_ig",
    }
    # a mapping for a *different* uid must be left completely alone
    db.docs[("instagram_identities", "888")] = {"uid": "other-uid"}

    out = account_ops.soft_delete(db, None, "u1")
    assert out["identity_mappings_cleared"] == 1

    # live mapping gone -> a fresh Instagram sign-in can never resolve to u1
    assert ("instagram_identities", "999") not in db.docs
    # the unrelated mapping is untouched
    assert db.docs[("instagram_identities", "888")] == {"uid": "other-uid"}
    # archived for admin lookup
    archived = db.docs[
        ("deleted_accounts", "u1", "identity_mappings", "instagram_999")
    ]
    assert archived["uid"] == "u1"
    assert archived["username"] == "jo_ig"
    assert archived["provider"] == "instagram"
    assert archived["external_id"] == "999"


def test_resignup_after_delete_gets_a_new_uid_not_the_old_data(monkeypatch):
    """End-to-end proof of the founder's core security requirement: deleting
    an account and then "signing up again" with the same Instagram identity
    must NOT reconnect to the old uid/data — it must resolve as a brand new
    user."""
    _patch_sentinels(monkeypatch)
    import instagram

    db = FakeDb()
    _seed_account(db, "u1")
    db.docs[("instagram_identities", "999")] = {"uid": "u1", "username": "jo_ig"}

    account_ops.soft_delete(db, None, "u1")
    assert ("instagram_identities", "999") not in db.docs

    created_uids = iter(["u2-fresh"])
    monkeypatch.setattr(
        instagram.firebase_auth,
        "create_user",
        lambda **kw: type("U", (), {"uid": next(created_uids)})(),
    )
    monkeypatch.setattr(
        instagram.firebase_auth, "create_custom_token", lambda uid: b"tok"
    )
    monkeypatch.setattr(
        instagram, "_exchange_code", lambda code: "short-lived-token"
    )
    monkeypatch.setattr(
        instagram,
        "_fetch_profile",
        lambda token: {"id": "999", "username": "jo_ig"},
    )

    result = instagram.signin(db, "some-code")
    assert result["isNewUser"] is True
    # brand new uid, never the old u1
    new_uid = db.docs[("instagram_identities", "999")]["uid"]
    assert new_uid == "u2-fresh"
    assert new_uid != "u1"
    # the new uid has no live profile pulled in from u1's old data
    assert ("users", new_uid) not in db.docs
    assert ("users", new_uid, "profile", "main") not in db.docs


# --- shared records (matches / dm_threads) - point 3 judgment call --------


def test_soft_delete_snapshots_matches_and_dm_threads_without_touching_them(
    monkeypatch,
):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed_account(db, "u1")
    db.docs[("matches", "u1__u2")] = {"uids": ["u1", "u2"], "status": "mutual_interest"}
    db.docs[("dm_threads", "u1__u2")] = {
        "participants": ["u1", "u2"],
        "last_message_at": 5,
    }
    db.docs[("dm_threads", "u1__u2", "messages", "m1")] = {
        "sender": "u1", "text": "hi"
    }
    db.docs[("dm_threads", "u1__u2", "messages", "m2")] = {
        "sender": "u2", "text": "hey"
    }

    account_ops.soft_delete(db, None, "u1")

    # live thread + match + both sides' messages are completely untouched
    assert db.docs[("matches", "u1__u2")] == {
        "uids": ["u1", "u2"], "status": "mutual_interest"
    }
    assert db.docs[("dm_threads", "u1__u2")]["participants"] == ["u1", "u2"]
    assert db.docs[("dm_threads", "u1__u2", "messages", "m1")]["text"] == "hi"
    assert db.docs[("dm_threads", "u1__u2", "messages", "m2")]["text"] == "hey"

    # A's full view captured into the archive for admin lookup
    assert db.docs[("deleted_accounts", "u1", "matches_snapshot", "u1__u2")][
        "status"
    ] == "mutual_interest"
    snap_thread = db.docs[
        ("deleted_accounts", "u1", "dm_threads_snapshot", "u1__u2")
    ]
    assert snap_thread["participants"] == ["u1", "u2"]
    assert db.docs[
        ("deleted_accounts", "u1", "dm_threads_snapshot", "u1__u2", "messages", "m1")
    ]["text"] == "hi"
    assert db.docs[
        ("deleted_accounts", "u1", "dm_threads_snapshot", "u1__u2", "messages", "m2")
    ]["text"] == "hey"

    # tombstone written so B's UI can render "deleted user"
    assert ("deleted_users", "u1") in db.docs


def test_recover_removes_the_deleted_user_tombstone(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed_account(db, "u1")
    account_ops.soft_delete(db, None, "u1")
    assert ("deleted_users", "u1") in db.docs

    account_ops.recover(db, None, "u1")
    assert ("deleted_users", "u1") not in db.docs


# --- blocks / feedback / product_feedback / bug_reports --------------------


def test_soft_delete_archives_and_removes_blocks_and_support_tickets(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    _seed_account(db, "u1")
    db.docs[("blocks", "u1_u2")] = {"reason": "spam"}
    db.docs[("blocks", "u3_u1")] = {"reason": "harassment"}
    db.docs[("blocks", "u2_u3")] = {"reason": "unrelated"}
    db.docs[("feedback", "f1")] = {"uid": "u1", "note": "too pushy"}
    db.docs[("feedback", "f2")] = {"uid": "someone-else", "note": "n/a"}
    db.docs[("product_feedback", "pf1")] = {"uid": "u1", "note": "bug"}
    db.docs[("bug_reports", "b1")] = {"uid": "u1", "note": "crash"}

    out = account_ops.soft_delete(db, None, "u1")

    assert out["blocks_archived"] == 2
    assert out["feedback_archived"] == 1
    assert out["product_feedback_archived"] == 1
    assert out["bug_reports_archived"] == 1

    # u1's blocks are gone; the unrelated block stays live
    assert ("blocks", "u1_u2") not in db.docs
    assert ("blocks", "u3_u1") not in db.docs
    assert db.docs[("blocks", "u2_u3")] == {"reason": "unrelated"}

    # feedback belonging to another uid is untouched
    assert ("feedback", "f1") not in db.docs
    assert db.docs[("feedback", "f2")] == {"uid": "someone-else", "note": "n/a"}
    assert ("product_feedback", "pf1") not in db.docs
    assert ("bug_reports", "b1") not in db.docs

    # everything archived
    assert db.docs[("deleted_accounts", "u1", "blocks", "u1_u2")] == {
        "reason": "spam"
    }
    assert db.docs[("deleted_accounts", "u1", "feedback", "f1")]["note"] == (
        "too pushy"
    )
    assert db.docs[("deleted_accounts", "u1", "product_feedback", "pf1")][
        "note"
    ] == "bug"
    assert db.docs[("deleted_accounts", "u1", "bug_reports", "b1")]["note"] == (
        "crash"
    )
