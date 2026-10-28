"""`/brain/preference` (§13.10): the unified-Brain catalog and the per-user
``ayma_brain_model`` preference that drives every text surface."""

import dataclasses

import config
import llm_provider
import main
import schema
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


class _ProfileDoc:
    """A stand-in ``profile/main`` doc: returns ``stored`` on get, captures set."""

    def __init__(self, stored=None):
        self.stored = dict(stored or {})
        self.written = {}

    def get(self):
        doc = self

        class _S:
            exists = True

            def to_dict(self_):
                return dict(doc.stored)

        return _S()

    def set(self, payload, merge=False):
        self.written.update(payload)
        self.stored.update(payload)


def _patch_db(monkeypatch, doc):
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: doc)
    monkeypatch.setattr(main, "get_db", lambda: object())


# --- GET /brain/preference -------------------------------------------------
def test_get_lists_both_brains_with_capabilities(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.get("/brain/preference", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    ids = [b["id"] for b in body["brains"]]
    assert ids == ["gemini", "meta"]
    gemini = next(b for b in body["brains"] if b["id"] == "gemini")
    meta = next(b for b in body["brains"] if b["id"] == "meta")
    assert set(gemini["capabilities"]) == {"text", "json", "vision", "web", "tools"}
    assert set(meta["capabilities"]) == {"text", "json", "tools"}
    assert "vision" not in meta["capabilities"] and "web" not in meta["capabilities"]
    for b in body["brains"]:
        assert b["label"] and b["description"] and b["available"] is True


def test_get_reports_unset_current_and_the_default(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())  # nothing saved
    monkeypatch.setattr(
        main, "CONFIG", dataclasses.replace(config.CONFIG, brain_default="meta")
    )
    resp = client.get("/brain/preference", headers=_auth(monkeypatch))
    body = resp.json()
    assert body["current"] == ""           # nothing saved yet
    assert body["default"] == "meta"       # hackathon default pre-selected


def test_get_reflects_a_saved_brain(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_BRAIN_MODEL: "gemini"}))
    resp = client.get("/brain/preference", headers=_auth(monkeypatch))
    assert resp.json()["current"] == "gemini"


def test_get_ignores_a_junk_saved_value(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_BRAIN_MODEL: "banana"}))
    resp = client.get("/brain/preference", headers=_auth(monkeypatch))
    assert resp.json()["current"] == ""


# --- POST /brain/preference ------------------------------------------------
def test_post_persists_a_known_brain(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/brain/preference", json={"brain": "meta"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "current": "meta"}
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "meta"


def test_post_normalises_case(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/brain/preference", json={"brain": "Gemini"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert doc.written[schema.PF_AYMA_BRAIN_MODEL] == "gemini"


def test_post_rejects_an_unknown_brain(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/brain/preference", json={"brain": "banana"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 422
    assert schema.PF_AYMA_BRAIN_MODEL not in doc.written
