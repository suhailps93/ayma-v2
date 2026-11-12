"""Google Places client: mapping + fail-closed (no key / errors -> None)."""
from types import SimpleNamespace

import pytest

import places_client


@pytest.fixture
def with_key(monkeypatch):
    monkeypatch.setattr(
        places_client, "CONFIG", SimpleNamespace(places_api_key="test-key"))


@pytest.fixture
def without_key(monkeypatch):
    monkeypatch.setattr(
        places_client, "CONFIG", SimpleNamespace(places_api_key=""))


def test_place_kind_mapping_is_deterministic():
    assert places_client.place_kind_for_types(["cafe", "food"]) == "cafe"
    assert places_client.place_kind_for_types(["bar", "point_of_interest"]) \
        == "bar"
    assert places_client.place_kind_for_types(["hiking_area"]) == "trailhead"
    assert places_client.place_kind_for_types([], "park") == "park"
    assert places_client.place_kind_for_types(["something_unmapped"]) \
        == "unknown"


def test_resolve_place_maps_text_search(with_key):
    def transport(url, payload, api_key):
        assert url.endswith("searchText")
        assert payload == {"textQuery": "Sakura Sushi"}
        assert api_key == "test-key"
        return {"places": [{
            "displayName": {"text": "Sakura Sushi"},
            "location": {"latitude": 37.3382, "longitude": -121.8863},
            "types": ["restaurant", "food"],
        }]}

    out = places_client.resolve_place("Sakura Sushi", transport=transport)
    assert out == {
        "place_name": "Sakura Sushi",
        "place_kind": "restaurant",
        "lat": 37.3382,
        "lng": -121.8863,
    }


def test_resolve_place_fails_closed_without_key(without_key):
    called = {"n": 0}

    def transport(url, payload, api_key):  # pragma: no cover - must not run
        called["n"] += 1
        return {}

    assert places_client.resolve_place("anywhere", transport=transport) is None
    assert called["n"] == 0  # no network attempted without a key


def test_resolve_place_fails_closed_on_transport_error(with_key):
    def transport(url, payload, api_key):
        raise OSError("network down")

    assert places_client.resolve_place("x", transport=transport) is None


def test_resolve_place_none_on_empty_results(with_key):
    assert places_client.resolve_place(
        "x", transport=lambda *a: {"places": []}) is None


def test_classify_point_maps_nearest(with_key):
    def transport(url, payload, api_key):
        assert url.endswith("searchNearby")
        assert payload["rankPreference"] == "DISTANCE"
        return {"places": [{
            "displayName": {"text": "Alum Rock Park"},
            "types": ["park", "tourist_attraction"],
        }]}

    out = places_client.classify_point(37.4, -121.8, transport=transport)
    assert out == {"place_name": "Alum Rock Park", "place_kind": "park"}


def test_classify_point_fails_closed_without_key(without_key):
    assert places_client.classify_point(
        37.4, -121.8, transport=lambda *a: {}) is None


def test_classify_point_fails_closed_on_error(with_key):
    def transport(url, payload, api_key):
        raise ValueError("bad json")

    assert places_client.classify_point(
        37.4, -121.8, transport=transport) is None
