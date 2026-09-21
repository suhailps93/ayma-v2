"""Unit + endpoint tests for admin_lookup.py — the admin-only read surface a
future admin-dashboard agent builds on (founder request 2026-09-20). Also
proves point (c) of the task: none of this data is reachable via any
non-admin endpoint."""

import dataclasses

import account_ops
import admin_lookup
import auth
import knowledge_wipe
import main
from config import CONFIG
from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

_PW = "hunter2-admin-pass"


def _pw(monkeypatch, value=_PW):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=value)
    )


def _patch_sentinels(monkeypatch):
    monkeypatch.setattr(account_ops.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(account_ops.firestore, "DELETE_FIELD", DELETE_FIELD)
    monkeypatch.setattr(knowledge_wipe.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(knowledge_wipe.firestore, "DELETE_FIELD", DELETE_FIELD)


# --- live_user_detail --------------------------------------------------


def test_live_user_detail_returns_everything(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1")] = {"trust_flags": ["x"]}
    db.docs[("users", "u1", "profile", "main")] = {"name": "Jo"}
    db.docs[("users", "u1", "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", "u1", "wiki_pages", "career", "versions", "v1")] = {
        "created_at_ms": 1
    }
    db.docs[("users", "u1", "user_media", "m1")] = {"path": "a.jpg"}
    db.docs[("matches", "u1__u2")] = {"uids": ["u1", "u2"]}
    db.docs[("dm_threads", "u1__u2")] = {"participants": ["u1", "u2"]}
    db.docs[("dm_threads", "u1__u2", "messages", "m1")] = {"text": "hi"}
    db.docs[("blocks", "u1_u3")] = {"reason": "spam"}
    db.docs[("feedback", "f1")] = {"uid": "u1", "note": "too pushy"}

    out = admin_lookup.live_user_detail(db, "u1")
    assert out["exists"] is True
    assert out["account"]["trust_flags"] == ["x"]
    wiki = {r["id"]: r for r in out["wiki_pages"]}
    assert wiki["career"]["ai_body"] == "Nurse."
    assert wiki["career"]["versions"][0]["id"] == "v1"
    assert {r["id"] for r in out["user_media"]} == {"m1"}
    assert out["matches"][0]["uids"] == ["u1", "u2"]
    assert out["dm_threads"][0]["messages"][0]["text"] == "hi"
    assert out["blocks"][0]["id"] == "u1_u3"
    assert out["feedback"][0]["note"] == "too pushy"
    assert out["recovery_pending"] is False


def test_live_user_detail_missing_uid(monkeypatch):
    db = FakeDb()
    out = admin_lookup.live_user_detail(db, "ghost")
    assert out == {"uid": "ghost", "exists": False}


# --- archived_account_detail --------------------------------------------


def test_archived_account_detail_finds_permanent_archive_first(monkeypatch):
    db = FakeDb()
    db.docs[("archived_accounts", "u1")] = {"original_uid": "u1"}
    db.docs[("archived_accounts", "u1", "profile", "main")] = {"name": "Jo"}
    db.docs[("archived_accounts", "u1", "identity_mappings", "instagram_9")] = {
        "provider": "instagram"
    }
    # a stray quarantine doc for the same uid should never happen in
    # practice (purge deletes it), but permanent archive still wins if it did
    db.docs[("deleted_accounts", "u1")] = {"deleted_at": 1}

    out = admin_lookup.archived_account_detail(db, "u1")
    assert out["tier"] == "archived"
    assert out["profile"][0]["name"] == "Jo"
    assert out["identity_mappings"][0]["provider"] == "instagram"


def test_archived_account_detail_falls_back_to_quarantine(monkeypatch):
    db = FakeDb()
    db.docs[("deleted_accounts", "u2")] = {"deleted_at": 1}
    db.docs[("deleted_accounts", "u2", "profile", "main")] = {"name": "Sam"}

    out = admin_lookup.archived_account_detail(db, "u2")
    assert out["tier"] == "quarantined"
    assert out["profile"][0]["name"] == "Sam"


def test_archived_account_detail_none_when_never_deleted(monkeypatch):
    db = FakeDb()
    assert admin_lookup.archived_account_detail(db, "never") is None


def test_full_deletion_round_trips_completely_into_the_archive(monkeypatch):
    """(d) Nothing is silently dropped: archive a live account, then verify
    admin_lookup sees every category that was live before deletion."""
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    db.docs[("users", "u1")] = {"trust_flags": ["x"]}
    db.docs[("users", "u1", "profile", "main")] = {"name": "Jo"}
    db.docs[("users", "u1", "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", "u1", "appearance_reports", "r1")] = {"summary": "tall"}
    db.docs[("users", "u1", "user_media", "m1")] = {"path": "a.jpg"}
    db.docs[("instagram_identities", "999")] = {"uid": "u1", "username": "jo"}

    account_ops.soft_delete(db, None, "u1")

    # not reachable live any more
    assert admin_lookup.live_user_detail(db, "u1") == {"uid": "u1", "exists": False}

    archived = admin_lookup.archived_account_detail(db, "u1")
    assert archived["tier"] == "quarantined"
    assert archived["profile"][0]["name"] == "Jo"
    assert archived["wiki_pages"][0]["ai_body"] == "Nurse."
    assert archived["appearance_reports"][0]["summary"] == "tall"
    assert archived["user_media"][0]["path"] == "a.jpg"
    assert archived["identity_mappings"][0]["uid"] == "u1"


# --- knowledge_archive_list / knowledge_archive_detail --------------------


def test_knowledge_archive_round_trips(monkeypatch):
    _patch_sentinels(monkeypatch)
    db = FakeDb()
    db.docs[("users", "u1")] = {}
    db.docs[("users", "u1", "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", "u1", "appearance_reports", "r1")] = {"summary": "tall"}

    result = knowledge_wipe.wipe_knowledge(db, "u1")
    archive_id = result["archive_id"]

    listing = admin_lookup.knowledge_archive_list(db, "u1")
    assert [r["archive_id"] for r in listing] == [archive_id]

    detail = admin_lookup.knowledge_archive_detail(db, "u1", archive_id)
    assert detail["wiki_pages"][0]["ai_body"] == "Nurse."
    assert detail["appearance_reports"][0]["summary"] == "tall"

    assert admin_lookup.knowledge_archive_detail(db, "u1", "no-such-id") is None


# --- (c) admin-only: not reachable via any non-admin endpoint -------------


def test_admin_lookup_endpoints_require_the_admin_password(monkeypatch):
    _pw(monkeypatch)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u1"}
    )
    auth_headers = {"Authorization": "Bearer valid"}
    for path in (
        "/admin/users/u1/full",
        "/admin/archived-accounts/u1",
        "/admin/knowledge-archives/u1",
        "/admin/knowledge-archives/u1/some-archive",
    ):
        # a normal signed-in user's bearer token is not enough
        resp = client.get(path, headers=auth_headers)
        assert resp.status_code == 403, path
        # no credentials at all
        resp = client.get(path)
        assert resp.status_code == 403, path
        # wrong admin password
        resp = client.get(path, headers={"X-Admin-Password": "wrong"})
        assert resp.status_code == 403, path


def test_admin_lookup_endpoints_work_with_the_admin_password(monkeypatch):
    _pw(monkeypatch)
    db = FakeDb()
    db.docs[("users", "u1")] = {}
    db.docs[("users", "u1", "profile", "main")] = {"name": "Jo"}
    monkeypatch.setattr(main, "get_db", lambda: db)

    resp = client.get(
        "/admin/users/u1/full", headers={"X-Admin-Password": _PW}
    )
    assert resp.status_code == 200
    assert resp.json()["profile"][0]["name"] == "Jo"

    resp = client.get(
        "/admin/archived-accounts/never-deleted",
        headers={"X-Admin-Password": _PW},
    )
    assert resp.status_code == 200
    assert resp.json() == {"uid": "never-deleted", "found": False}

    resp = client.get(
        "/admin/knowledge-archives/u1/missing",
        headers={"X-Admin-Password": _PW},
    )
    assert resp.status_code == 404
