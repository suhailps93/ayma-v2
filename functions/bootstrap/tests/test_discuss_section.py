""""Talk to Ayma about this" on a Complete-your-profile section (founder
feedback, build 2536): the seeded /chat turn carries the section's
``discuss_section`` and the prompt the model receives names that section's
live pending items, so Ayma opens on the first one — never a generic "what's
on your mind". Turns without the field are unchanged."""

import completeness
import gemini
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

_NODES = [
    {"id": "marital_status", "page_type": "identity",
     "label": "Marital status", "status": "missing", "value": "",
     "unlocked": True, "ayma_prompt": "whether they've been married before"},
    {"id": "height", "page_type": "identity", "label": "Height",
     "status": "missing", "value": "", "unlocked": True,
     "ayma_prompt": "how tall they are"},
]


def _setup(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    seen = {}

    async def _fake(_message, **kw):
        seen.update(kw)
        return gemini.Reply(text="So — ever been married before?")

    async def _view(db, uid):
        return {"nodes": _NODES}

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    monkeypatch.setattr(completeness, "questionnaire_view", _view)
    return seen, {"Authorization": "Bearer <redacted>"}


def test_section_kickoff_prompt_lists_the_sections_pending_items(monkeypatch):
    seen, headers = _setup(monkeypatch)
    resp = client.post(
        "/chat",
        json={"message": "Let's talk about About Me.",
              "discuss_section": "identity"},
        headers=headers,
    )
    assert resp.status_code == 200
    prompt = seen["system_prompt"]
    assert "SECTION KICKOFF" in prompt
    assert prompt.index("Marital status") < prompt.index("- Height")


def test_turn_without_section_has_no_kickoff_note(monkeypatch):
    seen, headers = _setup(monkeypatch)
    resp = client.post(
        "/chat", json={"message": "Let's talk about About Me."},
        headers=headers,
    )
    assert resp.status_code == 200
    assert "SECTION KICKOFF" not in seen["system_prompt"]
