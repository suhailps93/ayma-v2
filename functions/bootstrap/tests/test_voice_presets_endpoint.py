import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_voice_presets_lists_the_fixed_set_and_current_choice(monkeypatch):
    class _Doc:
        def get(self):
            class _S:
                exists = True

                def to_dict(self_):
                    return {"ayma_voice_name": "Charon"}

            return _S()

        def collection(self, _):
            return self

        def document(self, _):
            return self

    monkeypatch.setattr(main, "get_db", lambda: _Doc())
    resp = client.get("/voice/presets", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    names = [p["name"] for p in body["presets"]]
    assert "Aoede" in names and "Charon" in names
    assert all(p["description"] for p in body["presets"])
    assert body["current"] == "Charon"
    assert body["default"] == main.CONFIG.gemini_live_voice


def test_voice_presets_requires_auth():
    assert client.get("/voice/presets").status_code in (401, 403)
