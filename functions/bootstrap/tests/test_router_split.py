"""Tests verifying Tier-2 sweep monolith split #1 (modular prefix routers)."""

import pytest
from starlette.routing import Route

import main
from routes import (
    appearance_router,
    cron_router,
    media_router,
    profile_router,
    story_router,
)


def _app_route_map():
    routes = {}
    for r in main.app.routes:
        if isinstance(r, Route):
            for m in r.methods:
                routes[(m, r.path)] = r.endpoint
    return routes


def test_story_routes_registered():
    route_map = _app_route_map()
    expected = [
        ("GET", "/story"),
        ("GET", "/story/ai-notes"),
        ("PUT", "/story/section"),
        ("POST", "/story/section/visibility"),
        ("POST", "/story/edit"),
        ("POST", "/story/section/remove"),
        ("GET", "/story/section/{page_id}/versions"),
        ("GET", "/story/section/{page_id}/versions/{version_id}"),
        ("POST", "/story/section/revert"),
        ("GET", "/story/section/{page_id}/provenance"),
        ("GET", "/story/career-timeline"),
        ("POST", "/story/career-timeline/refresh"),
        ("POST", "/story/linkedin"),
    ]
    for method, path in expected:
        assert (method, path) in route_map, f"Missing route {method} {path}"


def test_profile_routes_registered():
    route_map = _app_route_map()
    expected = [
        ("POST", "/profile/share"),
        ("PUT", "/profile/preferences"),
        ("GET", "/profile/public-text"),
        ("PUT", "/profile/public-text"),
        ("GET", "/profile/proposals"),
        ("POST", "/profile/proposals/{page_id}/changes/{change_id}/apply"),
        ("POST", "/profile/proposals/{page_id}/changes/{change_id}/dismiss"),
        ("POST", "/profile/proposals/{page_id}/apply"),
        ("POST", "/profile/proposals/{page_id}/dismiss"),
    ]
    for method, path in expected:
        assert (method, path) in route_map, f"Missing route {method} {path}"


def test_cron_routes_registered():
    route_map = _app_route_map()
    expected = [
        ("POST", "/cron/purge-deleted"),
        ("POST", "/cron/match"),
        ("POST", "/cron/ingest-backfill"),
        ("POST", "/cron/google-sync"),
        ("POST", "/cron/physical-attributes-backfill"),
        ("POST", "/cron/photo-tags-backfill"),
        ("POST", "/cron/usable-for-body-resync"),
        ("POST", "/cron/skill-backfill"),
        ("POST", "/cron/completeness-backfill"),
        ("POST", "/cron/reengage"),
        ("POST", "/cron/lint"),
        ("POST", "/cron/persona-evolution"),
        ("POST", "/cron/persona-snapshot"),
        ("POST", "/cron/image-variants-backfill"),
    ]
    for method, path in expected:
        assert (method, path) in route_map, f"Missing route {method} {path}"


def test_media_routes_registered():
    route_map = _app_route_map()
    expected = [
        ("POST", "/media"),
        ("GET", "/media/photos"),
        ("POST", "/media/photos"),
        ("POST", "/media/photos/batch"),
        ("POST", "/media/photos/{media_id}/remove"),
        ("POST", "/media/photos/{media_id}/primary"),
        ("POST", "/media/photos/{media_id}/delete"),
        ("PUT", "/media/photos/order"),
    ]
    for method, path in expected:
        assert (method, path) in route_map, f"Missing route {method} {path}"


def test_appearance_routes_registered():
    route_map = _app_route_map()
    expected = [
        ("POST", "/appearance/report"),
        ("GET", "/appearance/report/{report_id}"),
        ("GET", "/appearance/history"),
        ("GET", "/appearance/coverage"),
        ("GET", "/appearance/eligibility"),
        ("POST", "/appearance/finding/correct"),
        ("POST", "/appearance/card/hidden"),
    ]
    for method, path in expected:
        assert (method, path) in route_map, f"Missing route {method} {path}"


def test_backward_compatibility_reexports():
    # Verify main re-exports essential request models and functions
    assert hasattr(main, "StorySaveSectionRequest")
    assert hasattr(main, "StoryVisibilityRequest")
    assert hasattr(main, "StoryEditRequest")
    assert hasattr(main, "ProfileShareRequest")
    assert hasattr(main, "ProfileTextSaveRequest")
    assert hasattr(main, "PartnerPreferencesRequest")
    assert hasattr(main, "MediaRequest")
    assert hasattr(main, "PhotoRef")
    assert hasattr(main, "PhotoBatchRef")
    assert hasattr(main, "PhotoOrder")
    assert hasattr(main, "_media_record")
    assert hasattr(main, "AppearanceReportRequest")
    assert hasattr(main, "AppearanceFindingCorrectRequest")
    assert hasattr(main, "AppearanceCardHiddenRequest")
    assert hasattr(main, "cron_purge_deleted")
    assert hasattr(main, "cron_match")
