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
    # Translation now resolves through the unified-brain resolver (§13.10).
    monkeypatch.setattr(
        dm_translate.llm_provider,
        "get_user_brain_provider",
        lambda uid, surface, *, needs=None: provider
    )
    return provider


# --- translate() --------------------------------------------------------- #


def test_translate_returns_translation_and_detected_lang(monkeypatch):
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "translated": "  Hello, how are you?  ",
                "detected_source_lang": "es",
                "confidence": 0.97,
            }
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


def test_translate_surface_defaults_to_gemini(monkeypatch):
    # Routing-audit H2: translation defaults to the LiveKit-routed gemini brain
    # when the env is unset (was Meta-direct, and live on staging).
    import config

    monkeypatch.delenv("LLM_PROVIDER_TRANSLATE", raising=False)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    assert config._load().llm_provider_translate == "gemini"


# --- confidence / script decision (§6.12) -------------------------------- #


def test_low_confidence_short_latin_falls_back_to_original(monkeypatch):
    # "hey sexy" is ambiguous short Latin-script text. Even if the model guesses
    # a foreign language and "translates" it, a low confidence means we assume
    # it is already in the reader's language and hand back the original — no
    # spurious Translate on noise.
    _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "translated": "oye sexy",
                "detected_source_lang": "es",
                "confidence": 0.3,
            }
        ),
    )
    out = _run(dm_translate.translate("hey sexy", "en", uid="me"))
    assert out == {"translated": "hey sexy", "detected_source_lang": "es"}


def test_high_confidence_latin_foreign_is_translated(monkeypatch):
    # A confidently-detected Latin-script foreign language (French) still
    # translates even though it shares the Latin script with English.
    _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "translated": "Hello my friend",
                "detected_source_lang": "fr",
                "confidence": 0.95,
            }
        ),
    )
    out = _run(dm_translate.translate("Bonjour mon ami", "en", uid="me"))
    assert out == {"translated": "Hello my friend", "detected_source_lang": "fr"}


def test_different_script_short_translates_even_at_low_confidence(monkeypatch):
    # A non-Latin script (Malayalam) is reliably foreign on script alone, so a
    # short message translates regardless of the model's reported confidence.
    _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "translated": "hello",
                "detected_source_lang": "ml",
                "confidence": 0.2,
            }
        ),
    )
    out = _run(dm_translate.translate("ഹായ്", "en", uid="me"))
    assert out == {"translated": "hello", "detected_source_lang": "ml"}


# --- _should_surface_translation (the pure decision) --------------------- #


def test_decision_same_language_short_and_long():
    # Same language (the model returns the text unchanged, detected == target).
    assert not dm_translate._should_surface_translation(
        "hi", "hi", "en", 0.99, "en"
    )
    long = "Sorry for the spam, I'll pause here and let you catch up."
    assert not dm_translate._should_surface_translation(
        long, long, "en", 0.99, "en"
    )
    # Even if the model hands back a reworded "translation", a detected source
    # equal to the target is never surfaced.
    assert not dm_translate._should_surface_translation(
        "hello", "hello!", "en", 0.9, "en"
    )


def test_decision_different_script_translates_regardless_of_confidence():
    assert dm_translate._should_surface_translation(
        "ഹായ്", "hi", "ml", 0.1, "en"
    )


def test_decision_high_confidence_latin_foreign_translates():
    assert dm_translate._should_surface_translation(
        "Bonjour", "Hello", "fr", 0.9, "en"
    )


def test_decision_low_confidence_same_script_does_not_translate():
    assert not dm_translate._should_surface_translation(
        "hey", "oye", "es", 0.3, "en"
    )


def test_decision_empty_or_unchanged_translation_is_not_surfaced():
    assert not dm_translate._should_surface_translation("hi", "", "fr", 0.9, "en")
    assert not dm_translate._should_surface_translation("hi", "hi", "fr", 0.9, "en")


def test_dominant_script_detection():
    assert dm_translate._dominant_script("hello") == "latin"
    assert dm_translate._dominant_script("¿Cómo estás?") == "latin"
    assert dm_translate._dominant_script("ഹായ് സുഖമാണോ") == "malayalam"
    assert dm_translate._dominant_script("123 👍 !!!") == "none"
    assert dm_translate._script_of_lang("en") == "latin"
    assert dm_translate._script_of_lang("ml") == "malayalam"
    assert dm_translate._script_of_lang("en-US") == "latin"


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
