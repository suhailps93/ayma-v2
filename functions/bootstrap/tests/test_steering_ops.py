import steering_ops


class _Doc:
    def __init__(self, store):
        self._s = store

    def get(self):
        s = self._s

        class _S:
            exists = "ai_body" in s

            def to_dict(self_):
                return dict(s)

        return _S()

    def set(self, payload, merge=False):
        self._s.update(payload)


class _Db:
    """Fluent stub — every collection()/document() hop returns self; get()/set()
    act on the one backing store (there's only the steering page)."""

    def __init__(self, store):
        self._doc = _Doc(store)

    def collection(self, _):
        return self

    def document(self, _):
        return self

    def get(self):
        return self._doc.get()

    def set(self, payload, merge=False):
        return self._doc.set(payload, merge=merge)


def _db(store=None):
    return _Db(store if store is not None else {})


def test_add_rule_creates_the_ai_only_steering_page():
    store = {}
    saved = steering_ops.add_rule(_db(store), "u1", "Don't ask about my dog")
    assert saved == "Don't ask about my dog"
    assert store["visibility"] == "ai_only"
    assert store["page_type"] == "steering"
    assert "- Don't ask about my dog" in store["ai_body"]


def test_add_rule_appends_and_dedupes_case_insensitively():
    store = {"ai_body": "instructions:\n- Keep questions short"}
    steering_ops.add_rule(_db(store), "u1", "Don't mention my ex")
    body = store["ai_body"]
    assert "- Keep questions short" in body
    assert "- Don't mention my ex" in body

    steering_ops.add_rule(_db(store), "u1", "keep questions SHORT")
    # still only one "short" rule
    assert store["ai_body"].lower().count("keep questions short") == 1


def test_add_rule_is_noop_on_empty():
    store = {}
    assert steering_ops.add_rule(_db(store), "u1", "   ") is None
    assert steering_ops.add_rule(_db(store), "", "something") is None
    assert store == {}
