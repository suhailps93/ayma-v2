import asyncio
import json

import pytest

import deep_dive_images
import deep_dive_public_profiles as pp
import gemini
import media_embed


def _run(coro):
    return asyncio.run(coro)


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    pp._cache.clear()
    monkeypatch.delenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", raising=False)
    monkeypatch.delenv("FLAG_DEEPDIVE_BLOCKED_REGIONS", raising=False)


def _reply(*profiles):
    return json.dumps({"profiles": list(profiles)})


def _stub_research(monkeypatch, text, calls=None):
    async def _r(prompt, system_prompt=None, **kw):
        if calls is not None:
            calls.append(prompt)
        return text, []

    monkeypatch.setattr(gemini, "research", _r)


def test_flag_off_by_default_makes_no_calls(monkeypatch):
    calls = []
    _stub_research(monkeypatch, _reply(), calls)
    assert _run(pp.find_public_profile_images("Dana Reyes")) == []
    assert calls == []


def test_parse_profiles_filters_dedupes_and_caps():
    text = "noise " + _reply(
        {"platform": "github", "url": "https://github.com/dana"},
        {"platform": "github", "url": "https://github.com/dana2"},
        {"platform": "x", "url": "https://twitter.com/dana"},
        {"platform": "instagram", "url": "javascript:alert(1)"},
        {"platform": "other", "url": "https://evil.example/dana"},
        {"platform": "personal_site", "url": "https://dana.example"},
    )
    out = pp.parse_profiles(text)
    assert [p["platform"] for p in out] == ["github", "x", "personal_site"]
    assert pp.parse_profiles("not json") == []
    assert pp.parse_profiles('{"profiles": "x"}') == []


def test_extract_profile_image_resolves_relative():
    html = '<meta property="og:image" content="/a.png">'
    assert pp.extract_profile_image("https://x.example/u", html) == "https://x.example/a.png"
    assert pp.extract_profile_image("https://x.example/u", "<html></html>") == ""


def test_returns_candidates_with_platform_and_caches(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "true")
    calls = []
    _stub_research(
        monkeypatch,
        _reply(
            {"platform": "github", "url": "https://github.com/dana"},
            {"platform": "linkedin", "url": "https://linkedin.com/in/dana"},
        ),
        calls,
    )
    monkeypatch.setattr(pp, "_robots_allows", lambda u: True)

    def _html(url):
        if "linkedin" in url:
            raise ValueError("login wall")
        return '<meta property="og:image" content="https://avatars.example/d.png">'

    monkeypatch.setattr(pp, "_fetch_public_html", _html)
    out = _run(pp.find_public_profile_images("Dana Reyes", extra_terms="Denver"))
    assert out == [
        {
            "url": "https://avatars.example/d.png",
            "source_page": "https://github.com/dana",
            "platform": "github",
        }
    ]
    assert _run(pp.find_public_profile_images("dana reyes", extra_terms="denver")) == out
    assert len(calls) == 1


def test_robots_disallow_skips_fetch(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "1")
    _stub_research(
        monkeypatch, _reply({"platform": "github", "url": "https://github.com/d"})
    )
    monkeypatch.setattr(pp, "_robots_allows", lambda u: False)

    def _boom(url):
        raise AssertionError("must not fetch")

    monkeypatch.setattr(pp, "_fetch_public_html", _boom)
    assert _run(pp.find_public_profile_images("Dana Reyes")) == []


def test_discovery_failure_falls_back_to_empty(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "1")

    async def _r(*a, **k):
        raise RuntimeError("vertex down")

    monkeypatch.setattr(gemini, "research", _r)
    assert _run(pp.find_public_profile_images("Dana Reyes")) == []


def test_region_blocked(monkeypatch):
    # Branch default: illinois, texas, eu are blocked.
    assert pp.region_blocked("Chicago, Illinois") is True
    assert pp.region_blocked("Austin, Texas") is True
    assert pp.region_blocked("Denver, CO") is False
    monkeypatch.setenv("FLAG_DEEPDIVE_BLOCKED_REGIONS", "texas, eu")
    assert pp.region_blocked("Chicago, Illinois") is False
    assert pp.region_blocked("Austin, Texas") is True


def test_find_web_images_uses_flagged_source_and_skips_blocked_region(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "1")
    monkeypatch.setattr(deep_dive_images, "_search_image_urls", lambda q, n: [])
    seen = []

    async def _pp(name, **kw):
        seen.append(name)
        return [
            {
                "url": "https://avatars.example/d.png",
                "source_page": "https://github.com/dana",
                "platform": "github",
            }
        ]

    monkeypatch.setattr(pp, "find_public_profile_images", _pp)
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda u: (b"x", "image/png")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda i, m="image/jpeg": [1.0, 0.0]
    )

    async def _face(_i, _m, uid=None):
        return True

    monkeypatch.setattr(deep_dive_images, "_has_detectable_face", _face)
    monkeypatch.setattr(
        deep_dive_images, "reference_embeddings_for", lambda db, uid: [[1.0, 0.0]]
    )
    out = _run(deep_dive_images.find_web_images(object(), "u1", "Dana Reyes"))
    assert len(out) == 1 and out[0]["platform"] == "github" and out[0]["verified"]

    monkeypatch.setenv("FLAG_DEEPDIVE_BLOCKED_REGIONS", "illinois")
    seen.clear()
    out = _run(
        deep_dive_images.find_web_images(
            object(), "u1", "Dana Reyes", location="Chicago, Illinois"
        )
    )
    assert out == [] and seen == []
