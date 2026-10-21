"""Public referral landing page (``GET /r/{code}``) and its link-preview card
(``GET /r/{code}/card.png``, 1200x630).

Firebase Hosting rewrites ``/r/**`` to this service (firebase.json), so the
link a friend shares keeps the hosting domain. Store URLs come from config
(``SHARE_ANDROID_STORE_URL`` / ``SHARE_IOS_STORE_URL``); an unset store shows
a disabled "coming soon" button. The page body is a template file
(``templates/referral_page.html``); nothing here depends on the database.
"""

from __future__ import annotations

import io
from html import escape
from pathlib import Path
from urllib.parse import quote

import segno
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import referrals
from config import CONFIG

_TEMPLATE = Path(__file__).parent / "templates" / "referral_page.html"

TITLE = "Join me on Ayma"
DESCRIPTION = (
    "She finds your person. Chat with Ayma, and she introduces you to people "
    "who actually fit."
)
# Play Store install-referrer key the app can read after install.
REFERRER_KEY = "ayma_ref"

_CARD_SIZE = (1200, 630)
_BG = (19, 18, 16)
_FG = (237, 233, 222)
_DIM = (186, 179, 163)
_ACCENT = (218, 75, 101)


def clean_code(raw: str) -> str:
    """The normalised code, or ``""`` when it is not a plausible one."""
    code = referrals.normalize(raw)
    return code if referrals._VALID_CODE.match(code) else ""


def _https(url: str) -> str:
    u = (url or "").strip()
    return u if u.startswith("https://") else ""


def play_url(base: str, code: str) -> str:
    """Play listing URL carrying the install referrer (read by the app after
    install). Unchanged when there is no code."""
    if not code:
        return base
    sep = "&" if "?" in base else "?"
    return f"{base}{sep}referrer={quote(f'{REFERRER_KEY}={code}', safe='')}"


def _stores(code: str) -> str:
    android = _https(CONFIG.share_android_store_url)
    ios = _https(CONFIG.share_ios_store_url)
    parts = []
    for cls, label, sub, url in (
        ("android", "Get Ayma on Google Play", "Android", play_url(android, code) if android else ""),
        ("ios", "Get Ayma on the App Store", "iPhone", ios),
    ):
        if url:
            parts.append(
                f'<a class="store {cls}" href="{escape(url, quote=True)}">{label}'
                f"<small>{sub}</small></a>"
            )
        else:
            parts.append(
                f'<span class="store soon {cls}">Coming soon on {sub}'
                "<small>We are almost there</small></span>"
            )
    return "".join(parts)


def _qr(url: str) -> str:
    return segno.make(url, error="m").svg_inline(
        border=0, dark="#000", light="#fff", omitsize=True
    )


def render_page(raw_code: str) -> str:
    code = clean_code(raw_code)
    page_url = referrals.link_for(code) if code else referrals.LINK_BASE
    image = f"{referrals.LINK_BASE}{code or '_'}/card.png"
    if code:
        invite = "A friend invited you to Ayma. Your invite code:"
        code_block = (
            f'<div class="code"><b>{escape(code)}</b>'
            '<button class="copy" id="copy" type="button">Copy</button></div>'
        )
        note = "Enter the code above when you create your account."
    else:
        invite = "You have been invited to Ayma."
        code_block = ""
        note = "Download Ayma and create your account."
    values = {
        "__TITLE__": escape(TITLE, quote=True),
        "__DESC__": escape(DESCRIPTION, quote=True),
        "__URL__": escape(page_url, quote=True),
        "__IMAGE__": escape(image, quote=True),
        "__INVITE__": invite,
        "__CODE_BLOCK__": code_block,
        "__STORES__": _stores(code),
        "__QR__": _qr(page_url),
        "__NOTE__": note,
        "__CODE_JS__": code,
    }
    html = _TEMPLATE.read_text(encoding="utf-8")
    for key, val in values.items():
        html = html.replace(key, val)
    return html


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    return ImageFont.load_default(size=size)


def _ramp(stops: list[tuple[float, tuple[int, int, int]]], t: float) -> tuple[int, ...]:
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            k = (t - p0) / (p1 - p0)
            return tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
    return stops[-1][1]


def render_card(raw_code: str) -> bytes:
    """Dark branded 1200x630 card: glowing orb, wordmark, tagline, code."""
    code = clean_code(raw_code)
    w, h = _CARD_SIZE
    img = Image.new("RGB", (w, h), _BG)

    glow = Image.new("RGB", (w, h), _BG)
    gd = ImageDraw.Draw(glow)
    cx, cy, r = 880, 315, 190
    gd.ellipse((cx - r - 40, cy - r - 40, cx + r + 40, cy + r + 40), fill=(150, 40, 100))
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    img = Image.blend(img, glow, 0.55)

    orb = Image.new("RGB", (2 * r, 2 * r))
    od = ImageDraw.Draw(orb)
    stops = [
        (0.00, (255, 243, 245)),
        (0.22, (255, 169, 196)),
        (0.52, (255, 61, 140)),
        (0.74, (232, 64, 158)),
        (1.00, (122, 61, 106)),
    ]
    for step in range(r, 0, -1):
        t = step / r
        col = _ramp(stops, t)
        ox = round((1 - t) * r * 0.30)
        oy = round((1 - t) * r * 0.36)
        od.ellipse((r - step - ox, r - step - oy, r + step - ox, r + step - oy), fill=col)
    mask = Image.new("L", (2 * r, 2 * r), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, 2 * r - 1, 2 * r - 1), fill=255)
    img.paste(orb, (cx - r, cy - r), mask)

    d = ImageDraw.Draw(img)
    pad = 80
    d.text((pad, 90), "Ayma", font=_font(84), fill=_FG)
    d.text((pad, 190), "She finds your person.", font=_font(40), fill=_DIM)
    d.text((pad, 300), TITLE, font=_font(60), fill=_FG)
    if code:
        d.text((pad, 400), "Invite code", font=_font(28), fill=_DIM)
        d.text((pad, 440), code, font=_font(76), fill=_ACCENT)

    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()
