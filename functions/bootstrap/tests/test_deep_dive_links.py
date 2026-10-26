"""Deep-dive link de-dupe + validation (mocked network)."""
import io
import urllib.error

import pytest

import deep_dive_links as dl
import deep_dive_public_profiles as profiles
import public_url

# conftest's autouse fixture stubs these; keep the real ones for these tests.
REAL_CHECK = dl._check
REAL_RESOLVE = dl.resolve_grounding_url


def _soc(platform, handle, url, conf="medium", by=("name",)):
    return {"platform": platform, "handle": handle, "url": url,
            "confidence": conf, "verified_by": list(by)}


# --- de-dupe ------------------------------------------------------------------


def test_url_key_strips_scheme_www_tracking_slash_and_case():
    a = dl.url_key("HTTPS://www.Example.com/Post/?utm_source=x&fbclid=1#top")
    b = dl.url_key("http://example.com/Post")
    assert a == b == "example.com/Post"
    assert dl.url_key("example.com/a?b=2&a=1") == dl.url_key("https://example.com/a/?a=1&b=2")


def test_socials_one_per_platform_best_wins_and_same_handle_once():
    socials = [
        _soc("instagram", "suhailps93", "https://instagram.com/suhailps93"),
        _soc("instagram", "SuhailPS93", "https://www.instagram.com/suhailps93/?igsh=1",
             conf="high", by=("face", "name")),
        _soc("github", "suhail", "https://github.com/suhail"),
    ]
    _, out = dl.clean_links_and_socials([], socials)
    assert [s["platform"] for s in out] == ["instagram", "github"]
    assert out[0]["confidence"] == "high"


def test_links_drop_profiles_and_duplicates_across_lists():
    links = [
        {"url": "https://github.com/suhail", "title": "GitHub"},
        {"url": "https://www.youtube.com/@suhail/", "title": "YT"},
        {"url": "https://facebook.com/suhail.ps", "title": "FB"},
        {"url": "https://github.com/suhail/repo", "title": "Repo"},
        {"url": "https://Blog.com/post/?utm_medium=x", "title": "Post"},
        {"url": "http://www.blog.com/post", "title": "Post again"},
    ]
    socials = [_soc("github", "suhail", "https://github.com/suhail")]
    out_links, out_socials = dl.clean_links_and_socials(links, socials)
    assert [l["title"] for l in out_links] == ["Repo", "Post"]
    assert len(out_socials) == 1


# --- validation ---------------------------------------------------------------


class _Resp:
    def __init__(self, url, body="<html><title>Hi</title>ok</html>", status=200):
        self._url, self._body, self.status = url, body.encode(), status

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def geturl(self):
        return self._url

    def read(self, n=-1):
        return self._body[:n]


def _http_error(url, code):
    return urllib.error.HTTPError(url, code, "x", {}, io.BytesIO(b""))


@pytest.fixture
def net(monkeypatch):
    """Route: url -> response | exception | callable(method)."""
    routes = {}

    def fake_fetch(url, method):
        r = routes[url]
        if callable(r):
            r = r(method)
        if isinstance(r, Exception):
            raise r
        return r

    monkeypatch.setattr(dl, "_fetch", fake_fetch)
    monkeypatch.setattr(profiles, "_robots_allows", lambda url: True)
    return routes


def test_404_dropped(net):
    u = "https://example.com/gone"
    net[u] = _http_error(u, 404)
    assert REAL_CHECK(u, True) is False


def test_5xx_and_timeout_and_dns_dropped(net):
    a, b, c = "https://e.com/a", "https://e.com/b", "https://e.com/c"
    net[a] = _http_error(a, 503)
    net[b] = TimeoutError()
    net[c] = urllib_url_error()
    assert not REAL_CHECK(a, True) and not REAL_CHECK(b, True) and not REAL_CHECK(c, True)


def urllib_url_error():
    return urllib.error.URLError("dns")


def test_blocked_non_public_host_dropped(net):
    u = "https://internal.test/x"
    net[u] = public_url.BlockedURL("non-public")
    assert REAL_CHECK(u, True) is False


def test_redirect_to_final_page_is_ok(net):
    u = "https://short.example/x"
    net[u] = _Resp("https://example.com/real/article")
    assert REAL_CHECK(u, False) is True


def test_redirect_to_homepage_or_login_dropped(net):
    a, b = "https://example.com/people/jane", "https://example.com/people/bob"
    net[a] = _Resp("https://example.com/")
    net[b] = _Resp("https://example.com/login?next=/people/bob")
    assert not REAL_CHECK(a, True)
    assert not REAL_CHECK(b, True)


def test_soft_404_body_dropped(net):
    u = "https://example.com/user/jane"
    net[u] = _Resp(u, "<html><title>Jane</title><h1>This page isn't available</h1></html>")
    assert REAL_CHECK(u, True) is False
    v = "https://example.com/other"
    net[v] = _Resp(v, "<html><title>Page not found</title></html>")
    assert REAL_CHECK(v, True) is False


def test_head_not_allowed_falls_back_to_get(net):
    u = "https://example.com/ok"
    net[u] = lambda m: _http_error(u, 405) if m == "HEAD" else _Resp(u)
    assert REAL_CHECK(u, False) is True


def test_bot_status_kept_only_when_grounded(net):
    u = "https://example.com/members/jane"
    net[u] = _http_error(u, 403)
    assert REAL_CHECK(u, True) is True
    assert REAL_CHECK(u, False) is False


def test_login_walled_platform_needs_grounding_and_profile_path(net):
    prof = "https://www.linkedin.com/in/jane-doe/"
    not_prof = "https://www.linkedin.com/company/acme"
    assert REAL_CHECK(prof, True) is True
    assert REAL_CHECK(prof, False) is False
    assert REAL_CHECK(not_prof, True) is False


def test_robots_disallowed_kept_only_if_grounded(net, monkeypatch):
    monkeypatch.setattr(profiles, "_robots_allows", lambda url: False)
    u = "https://example.com/p"
    assert REAL_CHECK(u, True) is True
    assert REAL_CHECK(u, False) is False


def test_validate_report_urls_filters_and_caches(monkeypatch):
    calls = []

    def fake_check(url, grounded):
        calls.append(url)
        return "dead" not in url

    monkeypatch.setattr(dl, "_check", fake_check)
    dl._reset_cache()
    links = [{"url": "https://a.com/ok"}, {"url": "https://a.com/dead"}]
    socials = [_soc("github", "x", "https://github.com/x")]
    images = [{"url": "i1", "source_page": "https://a.com/dead2"},
              {"url": "i2", "source_page": "https://a.com/ok"}, {"url": "i3"}]
    facts = [{"claim": "c", "source_url": "https://a.com/dead3"},
             {"claim": "d", "source_url": "https://a.com/ok"}]
    kl, ks, ki, kf = dl.validate_report_urls(links, socials, images, facts, set())
    assert [l["url"] for l in kl] == ["https://a.com/ok"]
    assert len(ks) == 1
    assert [i["url"] for i in ki] == ["i2", "i3"]
    assert [f["source_url"] for f in kf] == ["", "https://a.com/ok"]
    n = len(calls)
    dl.validate_report_urls(links, socials, images, facts, set())
    assert len(calls) == n  # 24h cache: no re-fetch


def test_budget_timeout_treated_as_dead(monkeypatch):
    import time

    monkeypatch.setattr(dl, "TOTAL_BUDGET_SECONDS", 0.05)
    monkeypatch.setattr(dl, "_check", lambda u, g: time.sleep(0.5) or True)
    dl._reset_cache()
    assert dl.check_urls({"https://slow.com/x": True}) == {"https://slow.com/x": False}


# --- grounding redirects --------------------------------------------------------


def test_resolve_grounding_follows_to_final(monkeypatch):
    g = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/abc"
    hops = {g: "https://example.com/final?utm_source=g"}

    def fake_open(url, **kw):
        raise urllib.error.HTTPError(url, 302, "found", {"Location": hops[url]}, io.BytesIO(b""))

    monkeypatch.setattr(public_url, "open_public", fake_open)
    assert REAL_RESOLVE(g) == "https://example.com/final?utm_source=g"
    assert REAL_RESOLVE("https://example.com/plain") == "https://example.com/plain"


def test_resolve_grounding_unresolvable_is_empty(monkeypatch):
    g = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/abc"

    def fake_open(url, **kw):
        raise urllib.error.HTTPError(url, 404, "gone", {}, io.BytesIO(b""))

    monkeypatch.setattr(public_url, "open_public", fake_open)
    assert REAL_RESOLVE(g) == ""
