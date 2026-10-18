"""Tests for the admin-dashboard "User Lookup" view (founder request
2026-09-20: "pull any user and see everything including photos AI notes
stories chat with other users and also data from these stale keys").

Covers the two small view-layer endpoints added to support it
(``/admin/media-url``, ``/admin/users/{uid}/credits``) and the dashboard
HTML shell itself — that it ships the new lookup UI, wires it to the
existing (already-tested) admin_lookup.py JSON endpoints, and stays behind
the same ``require_admin_password`` gate as the rest of ``/admin``. Follows
the pattern in ``test_admin.py`` / ``test_admin_lookup.py``.
"""

import dataclasses

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


# --- /admin/media-url ---------------------------------------------------


def test_media_url_requires_the_admin_password(monkeypatch):
    _pw(monkeypatch)
    assert client.get("/admin/media-url?path=users/u1/a.jpg").status_code == 403
    assert client.get(
        "/admin/media-url?path=users/u1/a.jpg",
        headers={"X-Admin-Password": "wrong"},
    ).status_code == 403


def test_media_url_resolves_a_storage_path(monkeypatch):
    _pw(monkeypatch)
    import public_profile

    monkeypatch.setattr(
        public_profile, "_photo_url", lambda path: f"https://cdn.example/{path}"
    )
    resp = client.get(
        "/admin/media-url?path=users/u1/a.jpg",
        headers={"X-Admin-Password": _PW},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["path"] == "users/u1/a.jpg"
    assert body["url"] == "https://cdn.example/users/u1/a.jpg"


def test_media_url_requires_a_path(monkeypatch):
    _pw(monkeypatch)
    resp = client.get("/admin/media-url", headers={"X-Admin-Password": _PW})
    assert resp.status_code in (400, 422)


# --- /admin/users/{uid}/credits ------------------------------------------


def test_user_credits_requires_the_admin_password(monkeypatch):
    _pw(monkeypatch)
    assert client.get("/admin/users/u1/credits").status_code == 403
    assert client.get(
        "/admin/users/u1/credits", headers={"X-Admin-Password": "wrong"}
    ).status_code == 403


def test_user_credits_returns_token_ledger_usage(monkeypatch):
    _pw(monkeypatch)
    monkeypatch.setattr(
        main.token_ledger,
        "usage",
        lambda uid, **kw: {
            "total": 1234,
            "cost_usd": 0.05,
            "features": {"chat": 1234},
            "credits": {"grant": 100, "added": 0, "used": 5, "remaining": 95},
        },
    )
    resp = client.get(
        "/admin/users/u1/credits", headers={"X-Admin-Password": _PW}
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1234
    assert body["credits"]["remaining"] == 95


# --- dashboard HTML shell -------------------------------------------------


def test_admin_dashboard_ships_the_user_lookup_ui(monkeypatch):
    """The /admin shell (still public/inert on its own — see test_admin.py)
    now also ships the user-lookup search box and wires it to the
    admin_lookup.py JSON endpoints, all sent with the same
    X-Admin-Password header discipline as the finance panel."""
    r = client.get("/admin")
    assert r.status_code == 200
    text = r.text

    # the lookup UI itself
    assert 'id="lookupUid"' in text
    assert 'id="lookupBtn"' in text
    assert 'id="lookupResults"' in text

    # wired to the existing admin_lookup.py endpoints, not a new/weaker path
    assert "/admin/users?q=" in text
    assert "/admin/users/" in text and "/full" in text
    assert "/admin/archived-accounts/" in text
    assert "/admin/knowledge-archives/" in text
    assert "/admin/media-url" in text
    assert "/admin/users/" in text and "/credits" in text

    # every fetch in the lookup flow carries the password header, never a
    # hardcoded password or an alternate auth path
    assert text.count("X-Admin-Password") >= 2
    assert _PW not in text


def test_admin_dashboard_user_lookup_data_endpoints_stay_gated(monkeypatch):
    """Sanity check that every endpoint the new UI calls is still behind
    require_admin_password (the underlying admin_lookup.py endpoints
    already have their own thorough coverage in test_admin_lookup.py; this
    just re-confirms the two new ones added for this UI)."""
    _pw(monkeypatch)
    for path in (
        "/admin/media-url?path=x",
        "/admin/users/u1/credits",
    ):
        assert client.get(path).status_code == 403
        assert client.get(
            path, headers={"X-Admin-Password": "wrong"}
        ).status_code == 403
