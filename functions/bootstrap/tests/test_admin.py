import dataclasses

import admin
import auth
import main
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)

_PW = "hunter2-admin-pass"


def _pw(monkeypatch, value=_PW):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=value)
    )


# ---- fake db ----------------------------------------------------------------
class _Snap:
    def __init__(self, sid, data):
        self.id = sid
        self._d = data

    @property
    def exists(self):
        return self._d is not None

    def to_dict(self):
        return dict(self._d) if self._d is not None else None


class _Q:
    def __init__(self, docs):
        self._docs = docs

    def where(self, *a, **k):
        field, _, value = a
        return _Q([d for d in self._docs
                   if value in (d.to_dict() or {}).get(field, [])])

    def limit(self, n):
        return _Q(self._docs[:n])

    def stream(self):
        return list(self._docs)


class _Col(_Q):
    def __init__(self, store, path):
        self._store = store
        self._path = path
        super().__init__([
            _Snap(k[-1], v) for k, v in store.items()
            if len(k) == len(path) + 1 and k[:len(path)] == path
        ])

    def document(self, doc_id):
        return _Doc(self._store, self._path + (doc_id,))


class _Doc:
    def __init__(self, store, path):
        self._store = store
        self._path = path

    def get(self):
        return _Snap(self._path[-1], self._store.get(self._path))

    def collection(self, name):
        return _Col(self._store, self._path + (name,))


class _Db:
    def __init__(self, store):
        self._store = store

    def collection(self, name):
        return _Col(self._store, (name,))


def _seed():
    return {
        ("users", "alice"): {"community": "lx", "session_mode": "active",
                             "trust_flags": [{"type": "face_mismatch"}]},
        ("users", "alice", "profile", "main"): {"name": "Alice Wonder",
                                                "paused": True},
        ("users", "alice", "wiki_pages", "career"): {
            "page_type": "career", "visibility": "private",
            "ai_body": "engineer"},
        ("users", "alice", "wiki_pages", "secret"): {
            "page_type": "sensitive", "visibility": "ai_only",
            "ai_body": "hidden"},
        ("users", "bob"): {"community": "lx", "session_mode": "marketing"},
        ("users", "bob", "profile", "main"): {"name": "Bob"},
        ("matches", "alice__zed"): {"uids": ["alice", "zed"],
                                    "status": "scored", "score": 0.7},
        ("dm_threads", "alice__bob"): {"participants": ["alice", "bob"],
                                       "hidden_for": []},
        ("deleted_accounts", "ghost"): {"deleted_at": "2026-01-01"},
    }


def test_admin_requires_the_password(monkeypatch):
    _pw(monkeypatch)
    assert client.get("/admin/users?q=alice").status_code == 403
    assert client.get(
        "/admin/users?q=alice", headers={"X-Admin-Password": "wrong"}
    ).status_code == 403


def test_admin_fails_closed_when_unset(monkeypatch):
    _pw(monkeypatch, value="")
    assert client.get(
        "/admin/users?q=alice", headers={"X-Admin-Password": "anything"}
    ).status_code == 403


def test_search_users_by_uid_and_name(monkeypatch):
    db = _Db(_seed())
    assert [u["uid"] for u in admin.search_users(db, "alice")] == ["alice"]
    hit = admin.search_users(db, "wonder")
    assert hit and hit[0]["uid"] == "alice"
    assert hit[0]["paused"] is True and hit[0]["trust_flags"] == 1
    assert admin.search_users(db, "") == []


def test_user_detail_covers_the_model(monkeypatch):
    db = _Db(_seed())
    d = admin.user_detail(db, "alice")
    assert d["exists"] is True
    assert d["profile"]["name"] == "Alice Wonder"
    assert {w["page_id"] for w in d["wiki_pages"]} == {"career", "secret"}
    # admin sees the ai_only page
    assert any(w["visibility"] == "ai_only" for w in d["wiki_pages"])
    assert d["matches"][0]["match_id"] == "alice__zed"
    assert d["dm_threads"][0]["thread_id"] == "alice__bob"
    assert d["trust_flags"] == [{"type": "face_mismatch"}]
    assert d["deleted_account"] is None


def test_user_detail_endpoint(monkeypatch):
    _pw(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: _Db(_seed()))
    r = client.get(
        "/admin/users/alice", headers={"X-Admin-Password": _PW}
    )
    assert r.status_code == 200
    assert r.json()["profile"]["name"] == "Alice Wonder"


# ---- finance-summary ---------------------------------------------------------

def _finance_seed():
    return {
        ("users", "alice"): {
            "token_usage": {"total": 1000, "cost_usd": 0.01, "features": {}},
        },
        ("users", "alice", "profile", "main"): {"name": "Alice Wonder"},
        ("users", "bob"): {
            "token_usage": {"total": 2500, "cost_usd": 0.025, "features": {}},
        },
        ("users", "bob", "profile", "main"): {"name": "Bob"},
        ("users", "carol"): {
            "token_usage": {"total": 500, "cost_usd": 0.005, "features": {}},
        },
        ("users", "carol", "profile", "main"): {"name": "Carol"},
    }


def test_finance_summary_requires_the_password(monkeypatch):
    _pw(monkeypatch)
    assert client.get("/admin/finance-summary").status_code == 403
    assert client.get(
        "/admin/finance-summary", headers={"X-Admin-Password": "wrong"}
    ).status_code == 403


def test_finance_summary_fails_closed_when_unset(monkeypatch):
    _pw(monkeypatch, value="")
    assert client.get(
        "/admin/finance-summary", headers={"X-Admin-Password": "anything"}
    ).status_code == 403


def test_finance_summary_aggregates_across_users(monkeypatch):
    db = _Db(_finance_seed())
    result = admin.finance_summary(db)

    assert result["user_count"] == 3
    assert round(result["total_cost_usd"], 6) == round(0.01 + 0.025 + 0.005, 6)
    assert result["total_tokens"] == 1000 + 2500 + 500
    assert result["revenue_usd"] == 0
    assert "beta" in result["revenue_note"].lower()

    by_uid = {u["uid"]: u for u in result["users"]}
    assert by_uid["alice"]["total_tokens"] == 1000
    assert by_uid["alice"]["cost_usd"] == 0.01
    assert by_uid["alice"]["name"] == "Alice Wonder"
    assert by_uid["bob"]["total_tokens"] == 2500
    assert by_uid["carol"]["cost_usd"] == 0.005

    ratio = max(1, CONFIG.tokens_per_credit)
    import math

    assert by_uid["alice"]["credits_used"] == math.ceil(1000 / ratio)
    assert by_uid["bob"]["credits_used"] == math.ceil(2500 / ratio)

    # sorted by cost_usd, descending
    assert [u["uid"] for u in result["users"]] == ["bob", "alice", "carol"]


def test_finance_summary_endpoint(monkeypatch):
    _pw(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: _Db(_finance_seed()))
    r = client.get(
        "/admin/finance-summary", headers={"X-Admin-Password": _PW}
    )
    assert r.status_code == 200
    body = r.json()
    assert body["revenue_usd"] == 0
    assert body["user_count"] == 3
    assert len(body["users"]) == 3


def test_admin_dashboard_html_is_public_and_data_endpoints_stay_gated(monkeypatch):
    """The /admin shell renders with no password (inert on its own), but the
    real data endpoints it calls stay behind require_admin_password."""
    r = client.get("/admin")
    assert r.status_code == 200
    assert "text/html" in r.headers["content-type"]
    assert "X-Admin-Password" in r.text  # page sends the header itself
    # no hardcoded password anywhere in the shipped page source
    assert _PW not in r.text

    _pw(monkeypatch)
    assert client.get("/admin/finance-summary").status_code == 403
    assert client.get("/admin/users?q=alice").status_code == 403
