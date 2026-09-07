import voices
from skills import make_session_tool_fns, session_tool_declarations
from skills.set_voice_preference import _closest_preset


def test_closest_preset_keyword_mapping():
    assert _closest_preset("can you sound deeper, more masculine") == "Charon"
    assert _closest_preset("something softer and calmer please") == "Zephyr"
    assert _closest_preset("a younger, brighter voice") == "Leda"
    assert _closest_preset("more playful and energetic") == "Puck"
    assert _closest_preset("just a warm friendly voice") == "Aoede"
    assert _closest_preset("???") is None  # not a voice-character request
    assert _closest_preset("let's speak French") is None  # language, not voice
    assert voices.is_valid_voice(_closest_preset("deeper"))


def test_closest_language_keyword_mapping():
    assert voices.closest_language("talk with an Irish accent") == "en-IE"
    assert voices.closest_language("can we speak Spanish") == "es-ES"
    assert voices.closest_language("switch to hindi please") == "hi-IN"
    assert voices.closest_language("use a british accent") == "en-GB"
    assert voices.closest_language("sound deeper") is None  # voice, not language


def test_skill_sets_language_only_for_a_pure_language_request():
    written = {}

    class _Chain:
        def collection(self, _):
            return self

        def document(self, _):
            return self

        def set(self, payload, merge=False):
            written.update(payload)

    fn = make_session_tool_fns(_Chain(), "u1")["set_voice_preference"]
    msg = fn(request="let's talk in French from now on")

    assert written.get("ayma_voice_language") == "fr-FR"
    assert "ayma_voice_name" not in written  # voice character untouched
    assert "French" in msg


def test_skill_can_set_both_voice_and_language_at_once():
    written = {}

    class _Chain:
        def collection(self, _):
            return self

        def document(self, _):
            return self

        def set(self, payload, merge=False):
            written.update(payload)

    fn = make_session_tool_fns(_Chain(), "u1")["set_voice_preference"]
    fn(request="a deeper voice with a british accent")

    assert written["ayma_voice_name"] == "Charon"
    assert written["ayma_voice_language"] == "en-GB"


def test_skill_declines_when_it_is_neither():
    class _Chain:
        def collection(self, _):
            return self

        def document(self, _):
            return self

        def set(self, *a, **k):
            raise AssertionError("should not write")

    fn = make_session_tool_fns(_Chain(), "u1")["set_voice_preference"]
    assert "couldn't tell" in fn(request="the weather is nice")


class _Doc:
    def __init__(self, sink):
        self._sink = sink

    def set(self, payload, merge=False):
        self._sink.update(payload)


class _Db:
    def __init__(self):
        self.written = {}

    def collection(self, _):
        return self

    def document(self, _):
        return self

    def set(self, *a, **k):  # pragma: no cover - not used
        pass

    # collection().document().collection().document() chain -> _Doc
    def __getattr__(self, name):  # pragma: no cover
        raise AttributeError(name)


def test_skill_is_registered_and_writes_the_preference():
    assert any(
        d["name"] == "set_voice_preference" for d in session_tool_declarations()
    )

    written = {}

    class _Chain:
        def collection(self, _):
            return self

        def document(self, _):
            return self

        def set(self, payload, merge=False):
            written.update(payload)

    fn = make_session_tool_fns(_Chain(), "u1")["set_voice_preference"]
    msg = fn(request="please sound deeper and more masculine")

    assert written["ayma_voice_name"] == "Charon"
    assert "next voice session" in msg


def test_skill_ignores_an_empty_request():
    class _Chain:
        def collection(self, _):
            return self

        def document(self, _):
            return self

        def set(self, *a, **k):
            raise AssertionError("should not write")

    fn = make_session_tool_fns(_Chain(), "u1")["set_voice_preference"]
    assert fn(request="   ") == "no voice request given"
