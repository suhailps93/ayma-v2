"""Rendering for the public page-share route (``GET /p/{token}``): the
landing page a shared justabot.info link opens in a browser.

Whoever taps the link in a chat app either has Ayma installed — the OS
app-link / universal-link machinery opens the app straight to the target
and this page is never seen — or they don't, in which case this page is
the fallback: it shows the target's public teaser, then routes by
platform (Android → Google Play, iOS → the App Store / TestFlight,
anything else stays and shows both store buttons). The Android attempt
goes through an ``intent://`` URL for this very link (the app, if
present after all, opens at the target; otherwise the browser falls
back to Play). The Play URL carries the share token as the
``ayma_page`` install referrer so the target can be picked up after
install where a reader exists.

No external assets: one inline stylesheet and one inline script. Every
snapshot string is HTML-escaped; only ``https`` URLs are ever emitted as
``href``/``src``. The script half is exposed as ``window.aymaPageShare``
(pure functions) so it can be unit-tested headlessly, the same shape as
``public/get.html``'s smart link.
"""

from __future__ import annotations

import json
from html import escape
from typing import Any
from urllib.parse import quote

import page_share
from config import CONFIG

# iOS ships as a public TestFlight beta until the App Store listing is
# live; SHARE_IOS_STORE_URL overrides this wherever it is set (the /r/
# and /s/ pages read the same config).
TESTFLIGHT_URL = "https://testflight.apple.com/join/uceuSRkh"

# Play install-referrer key carrying the share token across install.
REFERRER_KEY = "ayma_page"

_CSS = """
:root{color-scheme:light dark;--bg:#faf8f4;--fg:#1c1916;--mute:#70665c;--card:#fff;
--line:#e8e0d6;--accent:#da4b65}
@media(prefers-color-scheme:dark){:root{--bg:#131210;--fg:#f2ede6;--mute:#a39a8f;
--card:#1c1a17;--line:#2d2a26}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:640px;margin:0 auto;padding:20px 16px 48px}
h1{font:600 26px/1.25 Georgia,serif;margin:12px 0 4px}
h2{font:600 11px/1.4 ui-monospace,Menlo,monospace;letter-spacing:.12em;
text-transform:uppercase;color:var(--mute);margin:28px 0 8px}
p{margin:8px 0}
.sub{color:var(--mute)}
img.hero{width:100%;border-radius:14px;display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:12px 14px;margin:8px 0}
.cta{margin-top:36px;text-align:center}
.cta a{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;
font-weight:600;padding:12px 22px;border-radius:999px;margin:4px}
.status{color:var(--mute);font-size:14px;text-align:center;min-height:1.4em}
"""


def _https(url: Any) -> str:
    u = str(url or "").strip()
    return u if u.startswith("https://") else ""


def ios_store_url() -> str:
    return _https(CONFIG.share_ios_store_url) or TESTFLIGHT_URL


def play_url(token: str) -> str:
    """Play listing URL carrying the share token as the install referrer,
    so the shared target can be picked up after a fresh install."""
    base = _https(CONFIG.share_android_store_url)
    if not base or not token:
        return base
    sep = "&" if "?" in base else "?"
    return f"{base}{sep}referrer={quote(f'{REFERRER_KEY}={token}', safe='')}"


def _script(token: str, link: str) -> str:
    cfg = {
        "token": token,
        "link": link,
        "package": CONFIG.share_android_package,
        "playUrl": play_url(token),
        "iosUrl": ios_store_url(),
    }
    return (
        "<script>\n"
        "(function () {\n"
        "  var cfg = " + json.dumps(cfg) + ";\n"
        "  function detectOS(ua, touch) {\n"
        "    ua = ua || '';\n"
        "    if (/Android/i.test(ua)) return 'android';\n"
        "    if (/iPhone|iPad|iPod/i.test(ua)) return 'ios';\n"
        "    if (/Macintosh/i.test(ua) && (touch || 0) > 1) return 'ios';\n"
        "    return 'other';\n"
        "  }\n"
        "  function intentUrl() {\n"
        "    var rest = cfg.link.replace(/^https:\\/\\//, '');\n"
        "    return 'intent://' + rest + '#Intent;scheme=https;package=' +\n"
        "      cfg.package + ';S.browser_fallback_url=' +\n"
        "      encodeURIComponent(cfg.playUrl) + ';end';\n"
        "  }\n"
        "  window.aymaPageShare = { detectOS: detectOS, intentUrl: intentUrl,\n"
        "    playUrl: cfg.playUrl, iosUrl: cfg.iosUrl };\n"
        "  if (typeof document === 'undefined') return;\n"
        "  var os = detectOS(navigator.userAgent, navigator.maxTouchPoints);\n"
        "  var status = document.getElementById('status');\n"
        "  if (os === 'android') {\n"
        "    if (status) status.textContent = 'Opening Ayma…';\n"
        "    window.location.href = intentUrl();\n"
        "    setTimeout(function () { window.location.href = cfg.playUrl; }, 1600);\n"
        "  } else if (os === 'ios') {\n"
        "    if (status) status.textContent = 'Opening the App Store…';\n"
        "    setTimeout(function () { window.location.replace(cfg.iosUrl); }, 500);\n"
        "  }\n"
        "})();\n"
        "</script>"
    )


def render_page(token: str, pub: dict) -> str:
    snap = pub.get("snapshot") or {}
    title = str(pub.get("title") or "Ayma")
    summary = str(pub.get("summary") or "")
    link = page_share.link_url(token)
    photo = _https(snap.get("photo_url"))
    name = str(snap.get("name") or "").strip() or title

    meta = [
        f'<meta property="og:title" content="{escape(title, quote=True)}">',
        f'<meta property="og:description" content="{escape(summary, quote=True)}">',
        f'<meta property="og:url" content="{escape(link, quote=True)}">',
        '<meta property="og:type" content="profile">',
        '<meta name="twitter:card" content="summary_large_image">',
    ]
    if photo:
        meta.append(f'<meta property="og:image" content="{escape(photo, quote=True)}">')

    body = []
    if photo:
        body.append(f'<img class="hero" src="{escape(photo, quote=True)}" alt="">')
    body.append(f"<h1>{escape(name)}</h1>")
    if summary and summary != name:
        body.append(f'<p class="sub">{escape(summary)}</p>')
    for section in snap.get("sections") or []:
        stitle = str(section.get("title") or "").strip()
        sbody = str(section.get("body") or "").strip()
        if not sbody:
            continue
        if stitle:
            body.append(f"<h2>{escape(stitle)}</h2>")
        paras = "".join(
            f"<p>{escape(p.strip())}</p>" for p in sbody.split("\n") if p.strip()
        )
        body.append(f'<div class="card">{paras}</div>')

    android = play_url(token)
    ios = ios_store_url()
    cta = ['<div class="cta">']
    if android:
        cta.append(
            f'<a href="{escape(android, quote=True)}">Get Ayma on Google Play</a>'
        )
    if ios:
        cta.append(f'<a href="{escape(ios, quote=True)}">Get Ayma on the App Store</a>')
    cta.append("</div>")

    return (
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        f"<title>{escape(title)}</title>\n"
        + "\n".join(meta)
        + f"\n<style>{_CSS}</style>\n</head>\n<body>\n<main>\n"
        + "\n".join(body)
        + '\n<p class="status" id="status"></p>\n'
        + "\n".join(cta)
        + "\n</main>\n"
        + _script(token, link)
        + "\n</body>\n</html>"
    )
