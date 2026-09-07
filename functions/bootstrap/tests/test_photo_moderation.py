import asyncio

import gemini
import photo_moderation


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_profile_and_chat_use_different_policies(monkeypatch):
    seen = {}

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        seen["prompt"] = system_prompt
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    _run(photo_moderation.moderate(b"x", "image/jpeg"))  # default = profile
    profile_prompt = seen["prompt"]
    _run(photo_moderation.moderate(b"x", "image/jpeg", context="chat"))
    chat_prompt = seen["prompt"]

    assert profile_prompt != chat_prompt
    # the profile policy blocks text screenshots as spam; the chat one allows
    # resumes / web-page screenshots and says it is not a profile photo
    assert "spam" in profile_prompt.lower()
    assert "resume" in chat_prompt.lower()
    assert "NOT posted to a profile" in chat_prompt


def test_chat_policy_still_holds_on_a_model_error(monkeypatch):
    async def _boom(*a, **k):
        raise RuntimeError("vision down")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    verdict = _run(
        photo_moderation.moderate(b"x", "image/jpeg", context="chat")
    )
    assert verdict["allowed"] is False
    assert verdict["reason"] == "moderation_error"
