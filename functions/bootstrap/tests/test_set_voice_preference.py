import voices
from skills import make_session_tool_fns, session_tool_declarations
from skills.set_voice_preference import _closest_preset


class _Chain:
    """collection().document().collection().document().set() -> captures."""

    def __init__(self):
        self.written = {}

    def collection(self, _):
        return self

    def document(self, _):
        return self

    def set(self, payload, merge=False):
        self.written.update(payload)


def _fn(db):
    return make_session_tool_fns(db, "u1")["set_voice_preference"]


def test_closest_preset_keyword_mapping():
    assert _closest_preset("can you sound deeper, more masculine") == "Charon"
    assert _closest_preset("something softer and calmer please") == "Zephyr"
    assert _closest_preset("a younger, brighter voice") == "Leda"
    assert _closest_preset("more playful and energetic") == "Puck"
    assert _closest_preset("just a warm friendly voice") == "Aoede"
    assert _closest_preset("???") is None
    assert voices.is_valid_voice(_closest_preset("deeper"))


def test_skill_is_registered_and_sets_the_voice_character():
    assert any(
        d["name"] == "set_voice_preference" for d in session_tool_declarations()
    )
    db = _Chain()
    msg = _fn(db)(request="please sound deeper and more masculine")
    assert db.written["ayma_voice_name"] == "Charon"
    assert "ayma_voice_language" not in db.written
    assert "next voice session" in msg


def test_skill_stores_the_accent_language_verbatim():
    db = _Chain()
    _fn(db)(accent_language="Malayalam mixed with English")
    assert db.written["ayma_voice_language"] == "Malayalam mixed with English"
    assert "ayma_voice_name" not in db.written


def test_skill_can_set_both_at_once():
    db = _Chain()
    _fn(db)(request="a deeper voice", accent_language="a soft Southern US accent")
    assert db.written["ayma_voice_name"] == "Charon"
    assert db.written["ayma_voice_language"] == "a soft Southern US accent"


def test_skill_declines_when_given_neither():
    class _NoWrite(_Chain):
        def set(self, *a, **k):
            raise AssertionError("should not write")

    assert "couldn't tell" in _fn(_NoWrite())(request="the weather is nice")
    assert "couldn't tell" in _fn(_NoWrite())()


def test_looks_like_bcp47():
    assert voices.looks_like_bcp47("en-GB")
    assert voices.looks_like_bcp47("cmn-CN")
    assert not voices.looks_like_bcp47("a Southern US accent")
    assert not voices.looks_like_bcp47("")
