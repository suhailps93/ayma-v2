"""Explore results as tool output / screen context, the accent-colour app
action, and the saved-preferences prompt block + Edit-profile write path."""

from __future__ import annotations

import asyncio

import pytest

import prompt
import session_mode
from skills import app_control, questionnaire
from tests.test_app_control import (
    _ACK,
    _PENDING,
    _AckStore,
    _Db,
    _acking_db,
    _fast_acks,
)


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _store_acking_with(extra: dict):
    class _Store(_AckStore):
        def __setitem__(self, key, value):
            super().__setitem__(key, value)
            if key == _PENDING and isinstance(value, dict):
                super().__setitem__(
                    _ACK, {"id": value["id"], "ok": True, **extra}
                )

    return _Db(_Store())


# --- D: Explore results ---------------------------------------------------


def test_search_explore_returns_what_explore_shows_once_it_loads(monkeypatch):
    _fast_acks(monkeypatch, timeout=0.5, poll=0.01)
    monkeypatch.setattr(app_control, "_RESULT_TIMEOUT_SECONDS", 2.0)
    db = _store_acking_with(
        {"result": 'Search "hiking": 2 people: Ash, 29; Blake, 30'}
    )
    out = _run(app_control._bind_search_explore(db, "me")("hiking"))
    assert 'Explore now shows: Search "hiking": 2 people: Ash, 29; Blake, 30' in out


def test_search_explore_caps_the_reported_results(monkeypatch):
    _fast_acks(monkeypatch, timeout=0.5, poll=0.01)
    monkeypatch.setattr(app_control, "_RESULT_TIMEOUT_SECONDS", 2.0)
    db = _store_acking_with({"result": "x" * 9000})
    out = _run(app_control._bind_search_explore(db, "me")("a"))
    assert len(out) < app_control._RESULT_MAX_CHARS + 200


def test_describe_explore_includes_the_on_screen_detail():
    out = app_control._describe(
        {"screen": "explore", "note": "hiking", "detail": "2 people: Ash, 29"}
    )
    assert "searching for 'hiking'" in out
    assert "On screen now: 2 people: Ash, 29" in out
    assert app_control._describe({"screen": "explore"}) == (
        "The user is browsing the Explore screen."
    )


# --- C: accent colour -----------------------------------------------------


def test_app_action_accent_color_resolves_a_name_to_hex():
    db = _acking_db()
    out = _run(app_control._bind_app_action(db, "me")("accent_color", "Green"))
    assert out == "Changed the app's accent colour to Green."
    cmd = db.store[_PENDING]
    assert cmd["name"] == "accent_color"
    assert cmd["value"] == "#2E9E5B"


def test_app_action_accent_color_accepts_hex_and_rejects_junk():
    db = _acking_db()
    _run(app_control._bind_app_action(db, "me")("accent_color", "#abc123"))
    assert db.store[_PENDING]["value"] == "#ABC123"
    db2 = _Db()
    out = _run(
        app_control._bind_app_action(db2, "me")("accent_color", "plaid")
    )
    assert "accent_color needs `value`" in out
    assert _PENDING not in db2.store


def test_app_action_declaration_mentions_accent_color():
    assert "accent_color" in app_control._APP_ACTION["description"]
    assert "value" in app_control._APP_ACTION["parameters"]["properties"]


# --- A: saved preferences reach the prompt --------------------------------


_PROFILE = {
    "gender": "Man",
    "interested_in": ["Women"],
    "location": "Austin, US",
    "qz_partner_age_min": 26,
    "qz_partner_age_max": 38,
    "distance_pref": "50",
    "qz_relocation_radius": "Within ~50 km",
}


def test_describe_preferences_lists_every_saved_preference():
    out = session_mode.describe_preferences(_PROFILE)
    assert "Man" in out and "Women" in out
    assert "26 to 38" in out
    assert "within 50 miles" in out and "Austin, US" in out


def test_describe_preferences_marks_missing_values_and_empty_profile():
    out = session_mode.describe_preferences({"gender": "Woman"})
    assert "partner age range not set yet" in out
    assert session_mode.describe_preferences({}) == ""
    assert session_mode.describe_preferences(None) == ""


def test_preferences_block_is_in_the_composed_prompt():
    block = session_mode.describe_preferences(_PROFILE)
    with_it = prompt.compose_system_prompt(
        preferences_context=block, variant="voice"
    )
    without = prompt.compose_system_prompt(variant="voice")
    assert block in with_it
    assert "THEIR SAVED PREFERENCES" not in without


# --- B: Edit-profile write path ------------------------------------------


class _FakeDoc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def set(self, data, merge=False):
        self.store[self.key] = {**self.store.get(self.key, {}), **data}

    def collection(self, name):
        return _FakeCol(self.store, (*self.key, name))


class _FakeCol:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _FakeDoc(self.store, (*self.key, doc_id))


class _FakeDb:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _FakeCol(self.store, (name,))


def test_save_partner_preferences_writes_questionnaire_and_mirror():
    db = _FakeDb()
    questionnaire.save_partner_preferences(
        db, "u", age_min=26, age_max=38, distance_pref="50"
    )
    q = ("users", "u", "questionnaire")
    assert db.store[(*q, "partner_age_min")]["value"] == "26"
    assert db.store[(*q, "partner_age_max")]["value"] == "38"
    assert db.store[(*q, "relocation_radius")]["value"] == "Within ~50 km"
    mirror = db.store[("users", "u", "profile", "main")]
    assert mirror["qz_partner_age_min"] == 26
    assert mirror["qz_partner_age_max"] == 38
    assert mirror["qz_relocation_radius"] == "Within ~50 km"


@pytest.mark.parametrize(
    "kwargs",
    [
        {"age_min": 17, "age_max": 30},
        {"age_min": 40, "age_max": 30},
        {"age_min": 30},
        {"distance_pref": "the moon"},
    ],
)
def test_save_partner_preferences_rejects_bad_values(kwargs):
    db = _FakeDb()
    with pytest.raises(ValueError):
        questionnaire.save_partner_preferences(db, "u", **kwargs)
    assert db.store == {}


def test_distance_pref_is_stored_and_mapped_to_relocation_radius():
    db = _FakeDb()
    questionnaire.save_partner_preferences(db, "u", distance_pref="anywhere")
    mirror = db.store[("users", "u", "profile", "main")]
    assert mirror["distance_pref"] == "anywhere"
    assert mirror["qz_relocation_radius"] == "Globally open / digital nomad"
    assert session_mode.describe_preferences(mirror).count("anywhere is fine") == 1


def test_explore_defaults_to_the_saved_age_range_without_overriding():
    import explore

    saved = {"qz_partner_age_min": 26, "qz_partner_age_max": 38}
    assert explore.apply_saved_age_range({}, saved) == {
        "age_min": 26, "age_max": 38,
    }
    assert explore.apply_saved_age_range(
        {"age_min": 30, "location": "Austin"}, saved
    ) == {"age_min": 30, "age_max": 38, "location": "Austin"}
    assert explore.apply_saved_age_range({}, None) == {}


def test_save_partner_preferences_caps_min_at_the_scale_maximum():
    db = _FakeDb()
    questionnaire.save_partner_preferences(db, "u", age_min=95, age_max=99)
    mirror = db.store[("users", "u", "profile", "main")]
    assert mirror["qz_partner_age_min"] == 80
    assert mirror["qz_partner_age_max"] == 99
