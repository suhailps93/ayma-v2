import voices
from skills import make_session_tool_fns, session_tool_declarations
from skills.set_voice_preference import _closest_preset


def test_closest_preset_keyword_mapping():
    assert _closest_preset("can you sound deeper, more masculine") == "Charon"
    assert _closest_preset("something softer and calmer please") == "Zephyr"
    assert _closest_preset("a younger, brighter voice") == "Leda"
    assert _closest_preset("more playful and energetic") == "Puck"
    assert _closest_preset("just a warm friendly voice") == "Aoede"
    assert _closest_preset("???") == "Aoede"  # default
    assert voices.is_valid_voice(_closest_preset("deeper"))


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
