import wiki_query


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _Coll:
    def __init__(self, snaps):
        self._snaps = snaps

    def stream(self):
        return iter(self._snaps)


class _Db:
    def __init__(self, snaps):
        self._snaps = snaps

    def collection(self, name):
        return self

    def document(self, name):
        return self

    def stream(self):
        return iter(self._snaps)


def test_returns_empty_when_no_pages():
    assert wiki_query.read_wiki_context(_Db([]), "u1") == ""
    assert wiki_query.read_wiki_context(_Db([]), "") == ""


def test_compiles_all_pages_regardless_of_visibility_sorted():
    db = _Db(
        [
            _Snap("pottery", {"page_type": "interests", "ai_body": "Throws pots."}),
            _Snap("mother", {"page_type": "sensitive", "ai_body": "Estranged."}),
            _Snap("blank", {"page_type": "misc", "ai_body": "   "}),
        ]
    )
    out = wiki_query.read_wiki_context(db, "u1")
    assert "Throws pots." in out
    assert "Estranged." in out  # every tier — public/private/ai_only — goes to the AI
    assert "blank" not in out  # empty body skipped
    # sorted by (page_type, page_id): interests before sensitive
    assert out.index("pottery") < out.index("mother")


def test_char_budget_caps_the_block():
    big = "x" * 5000
    db = _Db(
        [_Snap(f"p{i}", {"page_type": "misc", "ai_body": big}) for i in range(5)]
    )
    out = wiki_query.read_wiki_context(db, "u1", max_chars=8000)
    assert out.count(big) == 1  # only the first page fits under 8000


def test_exclude_page_types_drops_matching_pages():
    db = _Db(
        [
            _Snap("career", {"page_type": "career", "ai_body": "Builds robots."}),
            _Snap(
                "interactions",
                {"page_type": "interactions", "ai_body": "Sang at Ayma."},
            ),
            _Snap(
                "steering",
                {"page_type": "steering", "ai_body": "Speak warmly."},
            ),
        ]
    )
    out = wiki_query.read_wiki_context(
        db, "u1", exclude_page_types=frozenset({"interactions", "steering"})
    )
    assert "Builds robots." in out
    assert "Sang at Ayma." not in out
    assert "Speak warmly." not in out


def test_exclude_page_types_default_keeps_every_page():
    db = _Db(
        [_Snap("interactions", {"page_type": "interactions", "ai_body": "Log."})]
    )
    assert "Log." in wiki_query.read_wiki_context(db, "u1")


def test_read_failure_is_swallowed():
    class _Boom:
        def collection(self, *_):
            raise RuntimeError("firestore down")

    assert wiki_query.read_wiki_context(_Boom(), "u1") == ""


# --- include_page_types (context_opt level-2 wiki trim / core card) ----------


def _typed_db():
    return _Db(
        [
            _Snap("who", {"page_type": "identity", "ai_body": "A doctor."}),
            _Snap("job", {"page_type": "career", "ai_body": "Cardiology."}),
            _Snap("pots", {"page_type": "interests", "ai_body": "Throws pots."}),
            _Snap("wants", {"page_type": "dealbreakers", "ai_body": "No smokers."}),
        ]
    )


def test_include_page_types_keeps_only_the_listed_types():
    out = wiki_query.read_wiki_context(
        _typed_db(), "u1", include_page_types=frozenset({"identity", "career"})
    )
    assert "A doctor." in out
    assert "Cardiology." in out
    assert "Throws pots." not in out
    assert "No smokers." not in out


def test_include_page_types_none_keeps_everything():
    out = wiki_query.read_wiki_context(_typed_db(), "u1", include_page_types=None)
    for text in ("A doctor.", "Cardiology.", "Throws pots.", "No smokers."):
        assert text in out


def test_include_and_exclude_compose_with_exclude_winning():
    out = wiki_query.read_wiki_context(
        _typed_db(), "u1",
        include_page_types=frozenset({"identity", "career"}),
        exclude_page_types=frozenset({"career"}),
    )
    assert "A doctor." in out
    assert "Cardiology." not in out
