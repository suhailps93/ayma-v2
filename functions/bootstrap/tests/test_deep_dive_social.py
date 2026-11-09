import deep_dive_images
import deep_dive_social


# --- handle extraction from URLs ----------------------------------------


def test_extracts_handles_from_profile_urls():
    c = deep_dive_social._candidate_from_url("https://instagram.com/jane.doe/")
    assert c == {
        "platform": "instagram",
        "handle": "jane.doe",
        "url": "https://www.instagram.com/jane.doe/",
    }
    assert deep_dive_social._candidate_from_url(
        "https://twitter.com/JaneDoe"
    ) == {"platform": "x", "handle": "JaneDoe", "url": "https://x.com/JaneDoe"}
    assert deep_dive_social._candidate_from_url(
        "https://uk.linkedin.com/in/jane-doe-123/"
    )["handle"] == "jane-doe-123"
    assert deep_dive_social._candidate_from_url(
        "https://www.tiktok.com/@janedoe"
    )["handle"] == "janedoe"
    assert deep_dive_social._candidate_from_url(
        "https://github.com/janedoe"
    )["handle"] == "janedoe"
    assert deep_dive_social._candidate_from_url(
        "https://www.youtube.com/@janedoe"
    )["handle"] == "janedoe"
    assert deep_dive_social._candidate_from_url(
        "https://www.facebook.com/jane.doe.9"
    )["platform"] == "facebook"


def test_ignores_non_profiles_and_site_chrome():
    for u in (
        "https://example.com/janedoe",
        "https://instagram.com/p/abc123/",
        "https://instagram.com/explore/tags/x/",
        "https://github.com/janedoe/some-repo",
        "https://twitter.com/home",
        "https://www.youtube.com/watch?v=abc",
        "https://www.linkedin.com/company/acme/",
        "not a url",
    ):
        assert deep_dive_social._candidate_from_url(u) is None, u


# --- the confidence gate ----------------------------------------------


def test_strong_name_match_on_two_sources_passes_as_medium():
    links = [
        {"url": "https://www.instagram.com/janedoe/", "is_them": "maybe",
         "title": "Jane Doe (@janedoe) • Instagram"},
    ]
    facts = [
        {"claim": "Her bio links to https://instagram.com/janedoe",
         "source_url": "https://janedoe.com/about"},
    ]
    out = deep_dive_social.find_social_handles(links, facts, "Jane Doe")
    assert len(out) == 1
    assert out[0]["platform"] == "instagram"
    assert out[0]["handle"] == "janedoe"
    assert out[0]["confidence"] == "medium"
    assert "name" in out[0]["verified_by"]


def test_weak_name_only_single_source_fails():
    links = [
        {"url": "https://instagram.com/jd_streetphotos", "is_them": "maybe",
         "title": "street photos"},
    ]
    assert deep_dive_social.find_social_handles(links, [], "Jane Doe") == []


def test_likely_link_with_strong_name_passes():
    links = [
        {"url": "https://github.com/janedoe", "is_them": "likely",
         "title": "janedoe (Jane Doe)"},
    ]
    out = deep_dive_social.find_social_handles(links, [], "Jane Doe")
    assert out and out[0]["confidence"] == "medium"
    assert "link" in out[0]["verified_by"]


def test_face_match_passes_even_with_a_weak_name(monkeypatch):
    import face_match

    monkeypatch.setattr(
        face_match, "get_reference_photos",
        lambda db, uid: ["users/u1/photo.jpg"],
    )
    monkeypatch.setattr(
        deep_dive_images, "_page_meta",
        lambda url: {"image": "https://p.example/pfp.jpg", "title": "xyz"},
    )
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda url: (b"i", "image/jpeg")
    )
    async def _check(ref, cand, uid=None, feature=None):
        return {"verdict": "self", "confidence": "high", "face_visible": True, "reason": "match"}

    monkeypatch.setattr(face_match, "check_same_person", _check)
    links = [{"url": "https://instagram.com/xyz_99", "is_them": "maybe"}]
    out = deep_dive_social.find_social_handles(
        links, [], "Jane Doe", db=object(), target_uid="u1"
    )
    assert len(out) == 1
    assert out[0]["confidence"] == "high"
    assert "face" in out[0]["verified_by"]


def test_returns_empty_when_nothing_clears_the_bar():
    links = [
        {"url": "https://instagram.com/some_brand", "is_them": "unclear"},
        {"url": "https://twitter.com/news_site", "is_them": "maybe"},
    ]
    assert deep_dive_social.find_social_handles(links, [], "Jane Doe") == []


def test_reads_structured_digest_socials():
    out = deep_dive_social.find_social_handles(
        [], [], "Jane Doe",
        digest_socials=[
            {"platform": "instagram", "handle": "janedoe",
             "tie_signal": "display name Jane Doe + city match"},
        ],
        summary_text="Jane's Instagram is https://instagram.com/janedoe",
    )
    assert len(out) == 1
    assert out[0]["handle"] == "janedoe"
    assert out[0]["confidence"] == "medium"
