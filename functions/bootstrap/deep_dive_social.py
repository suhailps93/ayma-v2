"""Deep-dive social-media handle extraction + verification.

For a deep dive on a person (self *or* an Explore user), pull the social
profiles the dive surfaced — Instagram, X / Twitter, LinkedIn, Facebook,
TikTok, GitHub, YouTube — and keep only the ones we can actually tie to this
person:

* **name match** — the @handle and/or the profile's display name against the
  person's name (fuzzy);
* **face match** — where the profile picture is fetchable, embed it and
  cosine-compare to the person's own profile-photo face embeddings (reuses
  :mod:`deep_dive_images`);
* **link signal** — the dive already flagged the URL ``is_them: "likely"``.

A candidate is returned only when it clears the bar: a face match, or a
strong name match backed by ≥2 independent sources (a ``likely`` link counts
as one). Nothing clears it → ``[]``. No low-confidence guesses.
"""

from __future__ import annotations

import difflib
import logging
import re
import urllib.parse

logger = logging.getLogger("ayma.deepdive.social")

# Cosine over the profile pic vs the person's own face crops — same bar the
# web-image step uses.
_FACE_THRESHOLD = 0.55
# Fraction-of-name-tokens / sequence ratio at or above which a name is a
# "strong" match (both given names present, essentially).
_NAME_STRONG = 0.85
_MAX_RESULTS = 8
_MAX_PROFILE_FETCHES = 8
_URL_RE = re.compile(r"https?://[^\s<>()\[\]{}\"']+", re.I)

# host (already stripped of a leading www./m./mobile./web. and any country
# sub-domain) -> platform key. ``None`` marks a host we recognise but never
# treat as a profile (bare video / share links).
_HOST_PLATFORM = {
    "instagram.com": "instagram",
    "twitter.com": "x",
    "x.com": "x",
    "linkedin.com": "linkedin",
    "facebook.com": "facebook",
    "fb.com": "facebook",
    "tiktok.com": "tiktok",
    "github.com": "github",
    "youtube.com": "youtube",
    "youtu.be": None,
}

# First path segment values that are site chrome, never a person's handle.
_RESERVED = {
    "instagram": {
        "p", "reel", "reels", "tv", "stories", "explore", "accounts",
        "about", "developer", "legal", "directory", "web", "s", "sitemap",
    },
    "x": {
        "home", "search", "hashtag", "i", "intent", "share", "explore",
        "messages", "notifications", "settings", "login", "signup", "tos",
        "privacy", "about", "compose", "who_to_follow", "account",
    },
    "facebook": {
        "sharer", "sharer.php", "dialog", "events", "groups", "pages",
        "watch", "marketplace", "gaming", "help", "login", "story.php",
        "photo.php", "permalink.php", "media", "bookmarks", "notes", "biz",
        "business", "policies", "legal", "terms", "privacy", "hashtag",
        "public", "search",
    },
    "tiktok": {
        "foryou", "following", "explore", "live", "upload", "tag", "music",
        "effect", "discover", "about", "legal", "search",
    },
    "github": {
        "features", "about", "pricing", "marketplace", "explore", "topics",
        "sponsors", "settings", "notifications", "orgs", "enterprise", "team",
        "login", "join", "new", "pulls", "issues", "codespaces", "dashboard",
        "search", "collections", "trending", "readme", "contact", "site",
        "security", "customer-stories", "apps", "logout", "sessions",
    },
    "youtube": {
        "watch", "results", "feed", "playlist", "shorts", "hashtag",
        "gaming", "premium", "music", "about", "howyoutubeworks", "account",
    },
}

_HANDLE_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,49}$")


def _norm_host(netloc: str) -> str:
    h = (netloc or "").lower().split("@")[-1].split(":")[0]
    h = re.sub(r"^(www|m|mobile|web)\.", "", h)
    # a country / language sub-domain like "uk.linkedin.com" -> "linkedin.com"
    # (only when there's a spare label so "fb.com" survives)
    if h.count(".") >= 2:
        h = re.sub(r"^[a-z]{2,3}\.", "", h)
    return h


def _candidate_from_url(raw_url: str) -> dict | None:
    """``{platform, handle, url}`` for a recognised profile URL, else
    ``None``. ``url`` is a cleaned canonical profile link."""
    raw_url = (raw_url or "").strip().rstrip(".,);]'\"")
    if not raw_url:
        return None
    if "//" not in raw_url:
        raw_url = "https://" + raw_url
    try:
        p = urllib.parse.urlparse(raw_url)
    except ValueError:
        return None
    if p.scheme not in ("http", "https"):
        return None
    host = _norm_host(p.netloc)
    if host not in _HOST_PLATFORM:
        return None
    platform = _HOST_PLATFORM[host]
    if platform is None:
        return None

    segs = [s for s in (p.path or "").split("/") if s]
    reserved = _RESERVED.get(platform, set())

    handle = ""
    if platform in ("instagram", "x", "tiktok"):
        if not segs:
            return None
        seg = segs[0]
        if platform == "tiktok":
            if not seg.startswith("@"):
                return None
            seg = seg[1:]
        seg = seg.lstrip("@")
        if seg.lower() in reserved:
            return None
        handle = seg
    elif platform == "github":
        # a profile is exactly one segment; /user/repo is not a profile
        if len(segs) != 1 or segs[0].lower() in reserved:
            return None
        handle = segs[0]
    elif platform == "linkedin":
        if len(segs) < 2 or segs[0].lower() not in ("in", "pub"):
            return None
        handle = urllib.parse.unquote(segs[1])
    elif platform == "facebook":
        if segs and segs[0] == "profile.php":
            qs = urllib.parse.parse_qs(p.query or "")
            fbid = (qs.get("id") or [""])[0]
            if not fbid.isdigit():
                return None
            handle = fbid
        else:
            if not segs or segs[0].lower() in reserved:
                return None
            if segs[0] == "people" and len(segs) >= 2:
                handle = segs[1]
            else:
                handle = segs[0]
    elif platform == "youtube":
        if not segs:
            return None
        if segs[0].startswith("@"):
            handle = segs[0][1:]
        elif segs[0].lower() in ("c", "user", "channel") and len(segs) >= 2:
            handle = segs[1]
        else:
            return None

    handle = handle.strip()
    if not handle or (platform != "facebook" and not _HANDLE_OK.match(handle)):
        return None

    canon = _canonical_url(platform, handle, p)
    return {"platform": platform, "handle": handle, "url": canon}


def _canonical_url(platform: str, handle: str, parsed) -> str:
    if platform == "instagram":
        return f"https://www.instagram.com/{handle}/"
    if platform == "x":
        return f"https://x.com/{handle}"
    if platform == "tiktok":
        return f"https://www.tiktok.com/@{handle}"
    if platform == "github":
        return f"https://github.com/{handle}"
    if platform == "linkedin":
        return f"https://www.linkedin.com/in/{handle}/"
    if platform == "facebook":
        if handle.isdigit():
            return f"https://www.facebook.com/profile.php?id={handle}"
        return f"https://www.facebook.com/{handle}"
    if platform == "youtube":
        return f"https://www.youtube.com/@{handle}"
    return urllib.parse.urlunparse(parsed)


def _name_tokens(name: str) -> list[str]:
    return [t for t in re.split(r"[^a-z0-9]+", (name or "").lower()) if len(t) >= 2]


def _name_match_score(name: str, *texts: str) -> float:
    """0..1 — how well any of ``texts`` (a handle, a display name) matches
    ``name``. 1.0 when every name token appears in the text."""
    toks = _name_tokens(name)
    if not toks:
        return 0.0
    joined = "".join(toks)
    best = 0.0
    for t in texts:
        t = (t or "").lower()
        if not t:
            continue
        compact = re.sub(r"[^a-z0-9]+", "", t)
        if not compact:
            continue
        present = sum(1 for tok in toks if tok in compact)
        frac = present / len(toks)
        ratio = difflib.SequenceMatcher(None, joined, compact).ratio()
        best = max(best, frac, ratio)
    return round(best, 4)


def _iter_urls(*blobs: str):
    for blob in blobs:
        for m in _URL_RE.finditer(blob or ""):
            yield m.group(0)


def _face_score(db, target_uid, profile_url: str, refs) -> tuple[float | None, str]:
    """``(cosine or None, display_name)`` from a profile page's og:image /
    og:title. Never raises."""
    try:
        import deep_dive_images

        meta = deep_dive_images._page_meta(profile_url)
    except Exception:  # noqa: BLE001
        return None, ""
    display = str(meta.get("title") or "").split("|")[0].split("•")[0].strip()
    img_url = meta.get("image") or ""
    if not (refs and img_url):
        return None, display
    try:
        import media_embed

        raw, mime = deep_dive_images._fetch_image(img_url)
        emb = media_embed.embed_image_bytes(raw, mime)
        sim = max(
            (deep_dive_images._cosine(emb, r) for r in refs), default=0.0
        )
        return float(sim), display
    except Exception:  # noqa: BLE001
        return None, display


def find_social_handles(
    digest_links: list[dict] | None,
    facts: list[dict] | None,
    name: str,
    *,
    summary_text: str = "",
    digest_socials: list[dict] | None = None,
    db=None,
    target_uid: str | None = None,
) -> list[dict]:
    """Return the social profiles that clear the confidence bar, as
    ``[{platform, handle, url, display_name, confidence, verified_by}]``.
    Empty when nothing qualifies. Never raises."""
    name = (name or "").strip()
    digest_links = digest_links or []
    facts = facts or []
    digest_socials = digest_socials or []

    # (platform, handle.lower()) -> aggregated evidence
    groups: dict[tuple[str, str], dict] = {}

    def _add(url: str, *, source: str, is_them: str = "", text: str = ""):
        cand = _candidate_from_url(url)
        if not cand:
            return
        key = (cand["platform"], cand["handle"].lower())
        g = groups.setdefault(
            key,
            {
                "platform": cand["platform"],
                "handle": cand["handle"],
                "url": cand["url"],
                "sources": set(),
                "link_them": False,
                "texts": set(),
            },
        )
        g["sources"].add((source, url))
        if str(is_them).strip().lower() == "likely":
            g["link_them"] = True
        if text:
            g["texts"].add(text)

    for ln in digest_links:
        if isinstance(ln, dict):
            _add(
                str(ln.get("url") or ""),
                source="link",
                is_them=str(ln.get("is_them") or ""),
                text=str(ln.get("title") or ""),
            )
    for f in facts:
        if not isinstance(f, dict):
            continue
        claim = str(f.get("claim") or "")
        _add(str(f.get("source_url") or ""), source="fact", text=claim)
        for u in _iter_urls(claim):
            _add(u, source="fact", text=claim)
    for s in digest_socials:
        if not isinstance(s, dict):
            continue
        url = str(s.get("url") or "").strip()
        handle = str(s.get("handle") or "").strip().lstrip("@")
        plat = str(s.get("platform") or "").strip().lower()
        if not url and handle and plat:
            stub = {
                "instagram": f"https://instagram.com/{handle}",
                "x": f"https://x.com/{handle}",
                "twitter": f"https://x.com/{handle}",
                "linkedin": f"https://linkedin.com/in/{handle}",
                "facebook": f"https://facebook.com/{handle}",
                "tiktok": f"https://tiktok.com/@{handle}",
                "github": f"https://github.com/{handle}",
                "youtube": f"https://youtube.com/@{handle}",
            }.get(plat, "")
            url = stub
        _add(url, source="digest_social", text=str(s.get("tie_signal") or ""))
    for u in _iter_urls(summary_text):
        _add(u, source="summary", text="")

    if not groups:
        return []

    refs = []
    if db is not None and target_uid:
        try:
            import biometric_consent
            import deep_dive_images

            # No biometric consent -> no face match (name evidence only).
            if biometric_consent.has_consent_fresh(db, target_uid):
                refs = deep_dive_images._reference_embeddings(db, target_uid)
        except Exception:  # noqa: BLE001
            refs = []

    out: list[dict] = []
    fetches = 0
    # Most-evidenced first, so the fetch budget goes to the best candidates.
    ordered = sorted(
        groups.values(),
        key=lambda g: (g["link_them"], len(g["sources"])),
        reverse=True,
    )
    for g in ordered:
        handle = g["handle"]
        # An "independent source" is a distinct (origin, url) mention — a dive
        # link, a fact's citation, the structured extractor, the summary text.
        independent = len(g["sources"])
        display_name = ""
        face = None
        if (db is not None and target_uid) and fetches < _MAX_PROFILE_FETCHES:
            fetches += 1
            face, display_name = _face_score(db, target_uid, g["url"], refs)

        name_score = _name_match_score(
            name, handle, display_name, *g["texts"]
        )
        strong_name = name_score >= _NAME_STRONG
        face_ok = face is not None and face >= _FACE_THRESHOLD

        verified_by: list[str] = []
        if face_ok:
            verified_by.append("face")
        if strong_name:
            verified_by.append("name")
        if g["link_them"]:
            verified_by.append("link")

        if face_ok:
            confidence = "high"
        elif strong_name and (independent >= 2 or g["link_them"]):
            confidence = "medium"
        else:
            continue

        out.append(
            {
                "platform": g["platform"],
                "handle": handle,
                "url": g["url"],
                "display_name": display_name,
                "confidence": confidence,
                "verified_by": verified_by,
            }
        )
        if len(out) >= _MAX_RESULTS:
            break

    order = {"high": 0, "medium": 1}
    out.sort(key=lambda s: (order.get(s["confidence"], 9), s["platform"]))
    return out
