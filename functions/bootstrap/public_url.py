"""Outbound-fetch guard for URLs that come from the open web or a model.

Deep dives fetch pages and images whose URLs come from search results, a
model's reply, a page's ``og:image`` or a member's own links. Any of those can
name an internal address (``localhost``, ``169.254.169.254``, a VPC host), so
every such fetch goes through :func:`open_public`: http(s) only, and the host
must resolve to public (globally routable) addresses only, re-checked on every
redirect hop.
"""

from __future__ import annotations

import ipaddress
import socket
import urllib.error
import urllib.parse
import urllib.request


class BlockedURL(ValueError):
    """The URL is not a public http(s) address."""


def check_public_url(url: str) -> None:
    """Raise :class:`BlockedURL` unless ``url`` is http(s) and its host
    resolves only to globally routable addresses."""
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError as exc:
        raise BlockedURL(f"malformed url: {exc}") from exc
    if parts.scheme not in ("http", "https"):
        raise BlockedURL(f"scheme not allowed: {parts.scheme!r}")
    host = parts.hostname
    if not host:
        raise BlockedURL("no host")
    try:
        infos = socket.getaddrinfo(
            host, port or (443 if parts.scheme == "https" else 80),
            proto=socket.IPPROTO_TCP,
        )
    except (socket.gaierror, UnicodeError) as exc:
        raise BlockedURL(f"unresolvable host: {host}") from exc
    if not infos:
        raise BlockedURL(f"unresolvable host: {host}")
    for info in infos:
        addr = ipaddress.ip_address(str(info[4][0]).split("%", 1)[0])
        if not addr.is_global:
            raise BlockedURL(f"non-public address for {host}")


class PublicOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to another public http(s) URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            check_public_url(newurl)
        except BlockedURL as exc:
            raise urllib.error.HTTPError(
                newurl, 403, f"redirect blocked: {exc}", headers, fp
            ) from exc
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def open_public(
    url: str,
    *,
    headers: dict[str, str] | None = None,
    timeout: float = 15,
    redirect_handler: PublicOnlyRedirectHandler | None = None,
):
    """``urlopen`` for an untrusted URL: :func:`check_public_url` first, and
    every redirect hop re-checked (``redirect_handler`` must be a
    :class:`PublicOnlyRedirectHandler`). Raises :class:`BlockedURL` or the
    usual ``urllib`` errors."""
    check_public_url(url)
    opener = urllib.request.build_opener(
        redirect_handler or PublicOnlyRedirectHandler()
    )
    req = urllib.request.Request(url, headers=headers or {})
    return opener.open(req, timeout=timeout)
