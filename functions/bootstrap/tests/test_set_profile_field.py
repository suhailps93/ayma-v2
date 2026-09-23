import datetime

import skills
from skills import set_profile_field as spf


class _Doc:
    def __init__(self):
        self.written = None
        self.merge = None

    def set(self, payload, merge=False):
        self.written = payload
        self.merge = merge


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


# --- birthdate: the Admin-SDK-bypasses-firestore.rules safety check --------
#
# set_profile_field writes with Admin SDK credentials, so
# firestore.rules' isAdultBirthdate() never runs against this path — this
# is the only enforcement of the 18+ floor here, and it must hold whether
# the call happens during preboarding or in an ordinary later chat/voice
# turn (the tool itself is not gated to preboarding in code either way).

def _today():
    return datetime.datetime.now(datetime.timezone.utc).date()


def _iso_years_ago(years: int, day_offset: int = 0) -> str:
    d = _today()
    try:
        bd = d.replace(year=d.year - years)
    except ValueError:  # Feb 29 on a non-leap birth year
        bd = d.replace(year=d.year - years, day=28)
    bd += datetime.timedelta(days=day_offset)
    return bd.isoformat()


def test_birthdate_normal_case_is_accepted():
    """A comfortably-adult birthdate (30 years ago) is written as-is — the
    baseline success case, exercised outside any preboarding context."""
    db = _Db()
    value = _iso_years_ago(30)
    assert _tool(db)("birthdate", value) == "set birthdate"
    assert db.doc.written["birthdate"] == value


def test_birthdate_exactly_18_today_is_accepted():
    """Turns 18 today — the rule's own boundary condition ('>= 18')."""
    db = _Db()
    value = _iso_years_ago(18)
    assert _tool(db)("birthdate", value) == "set birthdate"
    assert db.doc.written["birthdate"] == value


def test_birthdate_under_18_is_rejected_outside_preboarding():
    """Called exactly the way general/active-mode chat or voice would call
    it (no preboarding context at all) — a birthdate that makes the user
    under 18 (17 years old, and one that turns 18 tomorrow) must be
    refused, and nothing gets written."""
    db = _Db()
    result = _tool(db)("birthdate", _iso_years_ago(17))
    assert "18" in result
    assert db.doc.written is None

    db2 = _Db()
    result2 = _tool(db2)("birthdate", _iso_years_ago(18, day_offset=1))
    assert "18" in result2
    assert db2.doc.written is None


def test_birthdate_bad_format_rejected():
    db = _Db()
    assert _tool(db)("birthdate", "not-a-date").startswith("could not use")
    assert db.doc.written is None


# --- provenance (§ fact-source-of-truth, 2026-09-21) ------------------------
#
# `set_profile_field` stores the verbatim user turn a field came from, when
# it's called with a session_ctx (turns) — so `find_fact_source` can later
# quote it. No session_ctx (voice, or an older call site) means no quote is
# available and none is fabricated.


def test_provenance_is_stored_with_the_current_user_turn_as_the_quote():
    from transcript import ROLE_AYMA, ROLE_USER, Turn

    db = _Db()
    fn = skills.make_session_tool_fns(
        db, "u1",
        session_ctx={
            "session_id": "sess-1",
            "turn_index": 3,
            "turns": [
                Turn(ROLE_AYMA, "what should I call you?"),
                Turn(ROLE_USER, "call me Sam"),
            ],
        },
    )["set_profile_field"]

    assert fn("name", "Sam") == "set name"
    prov = db.doc.written["provenance"]["name"]
    assert prov["source_type"] == "chat"
    assert prov["quote"] == "call me Sam"
    assert prov["session_id"] == "sess-1"
    assert prov["turn_index"] == 3
    # only that one field's provenance sub-path is merged — never the whole
    # nested `provenance` map — so an earlier field's entry is never wiped.
    assert "provenance.name" in db.doc.merge
    assert "name" in db.doc.merge


def test_no_session_ctx_writes_no_provenance():
    db = _Db()
    assert _tool(db)("name", "Sam") == "set name"
    assert "provenance" not in db.doc.written


def test_session_ctx_with_no_user_turn_writes_no_provenance():
    from transcript import ROLE_AYMA, Turn

    db = _Db()
    fn = skills.make_session_tool_fns(
        db, "u1",
        session_ctx={
            "session_id": "sess-1",
            "turn_index": 0,
            "turns": [Turn(ROLE_AYMA, "hi there")],
        },
    )["set_profile_field"]
    fn("name", "Sam")
    assert "provenance" not in db.doc.written
