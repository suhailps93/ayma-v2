import skills
from skills import set_profile_field as spf


class _Doc:
    def __init__(self):
        self.written = None

    def set(self, payload, merge=False):
        self.written = payload


class _Db:
    def __init__(self):
        self.doc = _Doc()
        self.path = []

    def collection(self, n):
        self.path.append(n)
        return self

    def document(self, n):
        self.path.append(n)
        return self

    def set(self, *a, **k):
        return self.doc.set(*a, **k)


def _tool(db=None):
    return skills.make_session_tool_fns(db or _Db(), "u1")["set_profile_field"]


def test_registered_in_the_shared_registry():
    assert "set_profile_field" in {s.name for s in skills.all_skills()}


def test_writes_a_plain_field():
    db = _Db()
    assert _tool(db)("name", "  Sam ") == "set name"
    assert db.path[-4:] == ["users", "u1", "profile", "main"]
    assert db.doc.written["name"] == "Sam"


def test_gender_and_interested_in_are_normalised():
    db = _Db()
    _tool(db)("gender", "woman")
    assert db.doc.written["gender"] == "Woman"

    db2 = _Db()
    _tool(db2)("interested_in", "men and women")
    assert sorted(db2.doc.written["interested_in"]) == ["Men", "Women"]


def test_identity_fields_are_accepted():
    db = _Db()
    assert _tool(db)("first_name", "  Sam ") == "set first_name"
    assert db.doc.written["first_name"] == "Sam"

    db2 = _Db()
    assert _tool(db2)("last_name", "O'Brien") == "set last_name"
    assert db2.doc.written["last_name"] == "O'Brien"


def test_phone_keeps_digits_and_leading_plus_and_caps_length():
    db = _Db()
    _tool(db)("phone", " +1 (555) 123-4567 ")
    assert db.doc.written["phone"] == "+15551234567"

    db2 = _Db()
    _tool(db2)("phone", "0" * 50)
    assert db2.doc.written["phone"] == "0" * 32

    db3 = _Db()
    assert _tool(db3)("phone", "  ").startswith("could not use")


def test_rejects_unknown_field_or_unusable_value():
    db = _Db()
    assert _tool(db)("shoe_size", "10").startswith("unknown field")
    assert _tool(db)("gender", "spaceship").startswith("could not use")
    assert db.doc.written is None
