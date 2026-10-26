import socket
import urllib.error

import pytest

import deep_dive_images
import deep_dive_public_profiles as pp
import public_url


def _resolve_to(monkeypatch, *ips):
    def _fake(host, port, proto=0):
        return [(socket.AF_INET, socket.SOCK_STREAM, proto, "", (ip, port)) for ip in ips]

    monkeypatch.setattr(public_url.socket, "getaddrinfo", _fake)


@pytest.mark.parametrize(
    "ip", ["127.0.0.1", "10.0.0.5", "169.254.169.254", "192.168.1.1", "::1", "fd00::1"]
)
def test_private_and_metadata_addresses_are_blocked(monkeypatch, ip):
    _resolve_to(monkeypatch, ip)
    with pytest.raises(public_url.BlockedURL):
        public_url.check_public_url("https://looks-public.example/a.jpg")


def test_one_private_address_among_public_ones_is_blocked(monkeypatch):
    _resolve_to(monkeypatch, "93.184.216.34", "10.1.2.3")
    with pytest.raises(public_url.BlockedURL):
        public_url.check_public_url("http://mixed.example/")


@pytest.mark.parametrize(
    "url", ["file:///etc/passwd", "ftp://example.com/x", "gopher://x", "https://", "http://[::1"]
)
def test_non_http_or_malformed_urls_are_blocked(url):
    with pytest.raises(public_url.BlockedURL):
        public_url.check_public_url(url)


def test_unresolvable_host_is_blocked(monkeypatch):
    def _fail(*a, **k):
        raise socket.gaierror("nope")

    monkeypatch.setattr(public_url.socket, "getaddrinfo", _fail)
    with pytest.raises(public_url.BlockedURL):
        public_url.check_public_url("https://no-such-host.invalid/")


def test_public_address_passes(monkeypatch):
    _resolve_to(monkeypatch, "93.184.216.34")
    public_url.check_public_url("https://example.com/photo.jpg")


def test_redirect_to_a_private_address_is_refused(monkeypatch):
    _resolve_to(monkeypatch, "127.0.0.1")
    handler = public_url.PublicOnlyRedirectHandler()
    with pytest.raises(urllib.error.HTTPError) as err:
        handler.redirect_request(None, None, 302, "Found", {}, "http://internal/")
    assert err.value.code == 403


def test_fetch_image_never_opens_a_private_url(monkeypatch):
    _resolve_to(monkeypatch, "169.254.169.254")

    def _no_network(*a, **k):
        raise AssertionError("opened a blocked url")

    monkeypatch.setattr(public_url.urllib.request.OpenerDirector, "open", _no_network)
    with pytest.raises(public_url.BlockedURL):
        deep_dive_images._fetch_image("http://metadata.google.internal/computeMetadata/v1/")
    with pytest.raises(public_url.BlockedURL):
        deep_dive_images._fetch_page_html("http://10.0.0.7/")


def test_public_profile_fetch_fails_closed_on_a_private_host(monkeypatch):
    _resolve_to(monkeypatch, "10.0.0.7")
    # robots.txt on a private host: refused, so the page is never fetched.
    assert pp._robots_allows("https://my-portfolio.example/") is False
    assert pp.profile_image(
        {"platform": pp.PERSONAL_SITE, "url": "https://my-portfolio.example/"}
    ) == ""
