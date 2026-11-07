"""Screen co-pilot (/copilot/locate): normalization + endpoint contract.

The vision model is monkeypatched out — these tests pin the wire shape,
the clamping that keeps a bad coordinate from becoming a bad ring on the
user's screen, and the honest-502 behaviour when the vision pass fails.
"""

import base64

import copilot
import gemini
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

_JPEG = base64.b64encode(b"\xff\xd8fake-frame-bytes").decode()


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    monkeypatch.setattr(main, "_enforce_age", _noop_age)
    # copilot's local gate resolves the uid through age_gate.enforce.
    import age_gate

    monkeypatch.setattr(age_gate, "enforce", lambda *a, **k: None)
    return {"Authorization": "Bearer test-token"}


async def _noop_age(*_a, **_k):
    return None


def _body(**over):
    body = {"image_base64": _JPEG, "mime": "image/jpeg", "goal": "send this"}
    body.update(over)
    return body


# --------------------------------------------------------------------- #
# normalize_locate_result (pure)
# --------------------------------------------------------------------- #


def test_normalize_hit_clamps_into_screen():
    out = copilot.normalize_locate_result(
        {
            "found": True,
            "x": 1.4,
            "y": -0.2,
            "w": 3.0,
            "h": 0.0,
            "label": "Send",
            "kind": "button",
            "confidence": 0.9,
            "say": "Tap Send.",
        }
    )
    assert out["found"] is True
    assert out["x"] == 0.995
    assert out["y"] == 0.005
    assert out["w"] == 0.9
    assert out["h"] == 0.02
    assert out["label"] == "Send"
    assert "draft_text" not in out


def test_normalize_miss_has_no_coordinates():
    out = copilot.normalize_locate_result(
        {"found": False, "say": "Scroll down first."}
    )
    assert out == {"found": False, "say": "Scroll down first."}


def test_normalize_garbage_is_a_clean_miss():
    assert copilot.normalize_locate_result(None)["found"] is False
    assert copilot.normalize_locate_result("junk")["found"] is False
    out = copilot.normalize_locate_result({"found": True, "x": "NaN-ish"})
    assert out["found"] is True
    assert out["x"] == 0.5  # unparseable center falls back, never crashes


def test_normalize_keeps_draft_only_for_text_fields():
    hit = {
        "found": True,
        "x": 0.5,
        "y": 0.8,
        "label": "Message",
        "confidence": 0.8,
        "say": "Tap the message box.",
        "draft_text": "Hi! Loved your profile.",
    }
    field = copilot.normalize_locate_result({**hit, "kind": "text_field"})
    assert field["draft_text"] == "Hi! Loved your profile."
    button = copilot.normalize_locate_result({**hit, "kind": "button"})
    assert "draft_text" not in button


def test_normalize_draft_carries_voice_readback_and_confirmation_gate():
    hit = {
        "found": True,
        "x": 0.5,
        "y": 0.8,
        "label": "Message",
        "kind": "text_field",
        "confidence": 0.8,
        "say": "Tap the message box.",
        "draft_text": "Hi! Loved your profile.",
    }
    field = copilot.normalize_locate_result(hit)
    # The voice flow: Ayma reads the exact draft aloud and asks first.
    assert field["draft_say"] == (
        "I drafted this: 'Hi! Loved your profile.' "
        "Want me to copy it so you can paste it?"
    )
    assert field["copy_requires_confirmation"] is True
    # No draft -> no readback, no gate fields at all.
    button = copilot.normalize_locate_result({**hit, "kind": "button"})
    assert "draft_say" not in button
    assert "copy_requires_confirmation" not in button


def test_draft_say_truncates_long_drafts_but_keeps_full_text():
    long_draft = "x" * 500
    out = copilot.normalize_locate_result(
        {
            "found": True,
            "x": 0.5,
            "y": 0.8,
            "kind": "text_field",
            "say": "Tap the box.",
            "draft_text": long_draft,
        }
    )
    # What gets copied is the full exact draft; only the readback shortens.
    assert out["draft_text"] == long_draft
    assert len(out["draft_say"]) < len(long_draft)
    assert "…" in out["draft_say"]
    assert out["draft_say"].endswith("Want me to copy it so you can paste it?")


def test_normalize_unknown_kind_becomes_other():
    out = copilot.normalize_locate_result(
        {"found": True, "x": 0.5, "y": 0.5, "kind": "widget", "say": "Tap it."}
    )
    assert out["kind"] == "other"


# --------------------------------------------------------------------- #
# Endpoint
# --------------------------------------------------------------------- #


def test_locate_happy_path(monkeypatch):
    seen = {}

    async def _fake_generate_json(contents, system, **kwargs):
        seen["contents"] = contents
        seen["kwargs"] = kwargs
        return {
            "found": True,
            "x": 0.82,
            "y": 0.91,
            "w": 0.14,
            "h": 0.06,
            "label": "Send",
            "kind": "button",
            "confidence": 0.93,
            "say": "Tap the Send button, bottom right.",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_generate_json)
    r = client.post("/copilot/locate", json=_body(), headers=_auth(monkeypatch))
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["found"] is True
    assert data["x"] == 0.82 and data["y"] == 0.91
    assert data["label"] == "Send"
    # The frame went through the shared vision path as an image part,
    # tagged with the copilot feature for the token ledger.
    assert seen["kwargs"]["image"][1] == "image/jpeg"
    assert seen["kwargs"]["feature"] == "copilot_locate"
    assert "send this" in seen["contents"]


def test_locate_rejects_bad_mime(monkeypatch):
    _auth(monkeypatch)
    r = client.post(
        "/copilot/locate", json=_body(mime="image/gif"), headers=_auth(monkeypatch)
    )
    assert r.status_code == 400


def test_locate_rejects_bad_base64(monkeypatch):
    r = client.post(
        "/copilot/locate",
        json=_body(image_base64="!!!not-base64!!!"),
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 400


def test_locate_vision_failure_is_honest_502(monkeypatch):
    async def _boom(*_a, **_k):
        raise RuntimeError("gateway down")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    r = client.post("/copilot/locate", json=_body(), headers=_auth(monkeypatch))
    assert r.status_code == 502


def test_locate_requires_auth():
    r = client.post("/copilot/locate", json=_body())
    assert r.status_code in (401, 403)
