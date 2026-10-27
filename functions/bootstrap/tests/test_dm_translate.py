import asyncio

import dm_translate
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    monkeypatch.setattr(main, "_enforce_age", _noop_age)
    return {"Authorization": "Bearer valid"}


async def _noop_age(*_a, **_k):
    return None


def _run(coro):
    return asyncio.run(coro)


class _FakeProvider:
    """Stands in for the ``translate`` LLM provider."""

    def __init__(self, result=None, boom=False):
        self._result = result
        self._boom = boom
        self.calls = []

    async def generate_json(self, contents, **kwargs):
        self.calls.append((contents, kwargs))
        if self._boom:
            raise RuntimeError("model down")
        return self._result


def _patch_provider(monkeypatch, provider):
    monkeypatch.setattr(
        dm_translate.llm_provider, "get_llm_provider", lambda surface: provider
    )
    return provider


# --- translate() --------------------------------------------------------- #


def test_translate_returns_translation_and_detected_lang(monkeypatch):
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider(
            {"translated": "  Hello, how are you?  ", "detected_source_lang": "es"}
        ),
    )
    out = _run(dm_translate.translate("Hola, ¿cómo estás?", "en", uid="me"))
    assert out == {"translated": "Hello, how are you?", "detected_source_lang": "es"}
    # The target language and the text both reach the model.
    sent, kwargs = provider.calls[0]
    assert "TARGET LANGUAGE: en" in sent
    assert "Hola, ¿cómo estás?" in sent
    # Translation is metered but cap-exempt (never blocks a thread on credits).
    assert kwargs["enforce_cap"] is False
    assert kwargs["feature"] == "dm_translate"


def test_translate_skips_when_already_target_language(monkeypatch):
    # A message already in the target: the model returns it unchanged with the
    # detected source equal to the target. translate() passes that straight
    # through — no fake "translation" of same-language text.
    _patch_provider(
        monkeypatch,
        _FakeProvider(
            {"translated": "Hey there!", "detected_source_lang": "en"}
        ),
    )
    out = _run(dm_translate.translate("Hey there!", "en", uid="me"))
    assert out == {"translated": "Hey there!", "detected_source_lang": "en"}


def test_translate_is_graceful_on_provider_failure(monkeypatch):
    # The model blows up -> the original text comes back, no exception, empty
    # detected language, so the client simply shows the original.
    _patch_provider(monkeypatch, _FakeProvider(boom=True))
    out = _run(dm_translate.translate("Bonjour", "en", uid="me"))
    assert out == {"translated": "Bonjour", "detected_source_lang": ""}


def test_translate_degrades_to_original_on_empty_model_output(monkeypatch):
    _patch_provider(
        monkeypatch,
        _FakeProvider({"translated": "   ", "detected_source_lang": "fr"}),
    )
    out = _run(dm_translate.translate("Bonjour", "en", uid="me"))
    assert out == {"translated": "Bonjour", "detected_source_lang": "fr"}


def test_translate_no_op_without_text_or_target(monkeypatch):
    provider = _patch_provider(monkeypatch, _FakeProvider({"translated": "x"}))
    assert _run(dm_translate.translate("   ", "en")) == {
        "translated": "", "detected_source_lang": "",
    }
    assert _run(dm_translate.translate("hi", "  ")) == {
        "translated": "hi", "detected_source_lang": "",
    }
    assert provider.calls == []  # the model is never called with nothing to do


def test_translate_surface_defaults_to_meta():
    from config import CONFIG

    assert CONFIG.llm_provider_translate == "meta"


# --- endpoint ------------------------------------------------------------ #


def test_endpoint_translates_for_a_participant(monkeypatch):
    async def _fake_translate(text, target_lang, source_lang=None, *, uid=None):
        assert (text, target_lang, uid) == ("Hola", "en", "aaa")
        return {"translated": "Hello", "detected_source_lang": "es"}

    monkeypatch.setattr(main.dm_translate, "translate", _fake_translate)
    resp = client.post(
        "/dm/translate",
        json={"thread_id": "aaa__bbb", "text": "Hola", "target_lang": "en"},
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 200
    assert resp.json() == {"translated": "Hello", "detected_source_lang": "es"}


def test_endpoint_rejects_non_participant(monkeypatch):
    resp = client.post(
        "/dm/translate",
        json={"thread_id": "aaa__bbb", "text": "Hola", "target_lang": "en"},
        headers=_auth(monkeypatch, uid="ccc"),
    )
    assert resp.status_code == 403
