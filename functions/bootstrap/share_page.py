"""Rendering for the public share routes: the server-rendered HTML page and
the PNG cards (``/s/{token}/card.png``) used as ``og:image`` and as the
Instagram-story / system-share image.

No external assets: one inline stylesheet, Pillow's bundled font for the
cards. Every snapshot string is HTML-escaped; only ``https`` URLs are ever
emitted as ``href``/``src``.
"""

from __future__ import annotations

import io
from html import escape
from typing import Any

from PIL import Image, ImageDraw, ImageFont

import share
from config import CONFIG

CARD_SIZES = {"story": (1080, 1920), "link": (1200, 630)}

_BG_TOP = (250, 248, 244)
_BG_BOTTOM = (240, 228, 214)
_INK = (28, 25, 22)
_MUTE = (112, 102, 92)
_ACCENT = (200, 112, 64)

_CSS = """
:root{color-scheme:light dark;--bg:#faf8f4;--fg:#1c1916;--mute:#70665c;--card:#fff;
--line:#e8e0d6;--accent:#c87040}
@media(prefers-color-scheme:dark){:root{--bg:#131210;--fg:#f2ede6;--mute:#a39a8f;
--card:#1c1a17;--line:#2d2a26}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.banner{position:sticky;top:0;z-index:2;background:var(--accent);color:#fff;
padding:10px 16px;display:flex;gap:12px;align-items:center;justify-content:space-between}
.banner strong{font-size:15px}
.banner a{background:#fff;color:#1c1916;text-decoration:none;font-weight:600;
padding:8px 14px;border-radius:999px;font-size:14px;white-space:nowrap}
.banner .btns{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end}
main{max-width:640px;margin:0 auto;padding:20px 16px 48px}
h1{font:600 26px/1.25 Georgia,serif;margin:8px 0 4px}
h2{font:600 11px/1.4 ui-monospace,Menlo,monospace;letter-spacing:.12em;
text-transform:uppercase;color:var(--mute);margin:28px 0 8px}
p{margin:8px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:12px 14px;margin:8px 0}
.stat{display:flex;justify-content:space-between;align-items:baseline;gap:12px}
.stat b{font-size:28px;color:var(--accent)}
.k{color:var(--mute);font-size:14px}
.tag{color:var(--mute);font-size:12px}
img{max-width:100%;border-radius:12px;display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:8px}
a{color:var(--accent)}
.cta{margin-top:36px;text-align:center}
.cta a{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;
font-weight:600;padding:12px 22px;border-radius:999px;margin:4px}
"""


def _https(url: Any) -> str:
    u = str(url or "").strip()
    return u if u.startswith("https://") else ""


def _store_links() -> list[tuple[str, str]]:
    links = [
        ("Google Play", CONFIG.share_android_store_url),
        ("App Store", CONFIG.share_ios_store_url),
    ]
    return [(label, url) for label, url in links if _https(url)]


def _value(v: Any) -> str:
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v)
    return str(v if v is not None else "")


def _block_html(b: dict) -> str:
    kind = b.get("type")
    if kind == "text":
        return f"<p>{escape(str(b.get('text') or ''))}</p>"
    if kind == "section_head":
        return f"<p class=k>{escape(str(b.get('text') or ''))}</p>"
    if kind == "fact":
        tag = str(b.get("tag") or "")
        tag_html = f" <span class=tag>{escape(tag)}</span>" if tag else ""
        return f"<div class=card>{escape(str(b.get('text') or ''))}{tag_html}</div>"
    if kind == "attribute":
        return (
            "<div class='card stat'>"
            f"<span class=k>{escape(str(b.get('label') or ''))}</span>"
            f"<span>{escape(_value(b.get('value')))}</span></div>"
        )
    if kind == "stat":
        basis = str(b.get("basis") or "")
        basis_html = f"<div class=tag>{escape(basis)}</div>" if basis else ""
        return (
            "<div class=card><div class=stat>"
            f"<span class=k>{escape(str(b.get('label') or ''))}</span>"
            f"<b>{escape(_value(b.get('value')))}</b></div>{basis_html}</div>"
        )
    if kind == "photo":
        src = _https(b.get("url"))
        return f"<img src='{escape(src)}' alt='' loading=lazy>" if src else ""
    if kind == "photo_grid":
        imgs = "".join(
            f"<img src='{escape(s)}' alt='' loading=lazy>"
            for s in (_https(p.get("url")) for p in b.get("photos") or [])
            if s
        )
        return f"<div class=grid>{imgs}</div>" if imgs else ""
    if kind == "link":
        href = _https(b.get("url"))
        if not href:
            return ""
        label = str(b.get("label") or "") or href
        return (
            f"<div class=card><a href='{escape(href)}' rel='nofollow noopener' "
            f"target=_blank>{escape(label)}</a></div>"
        )
    return ""


def render_page(token: str, snap: dict) -> str:
    """The full public HTML page for a snapshot."""
    url = share.share_url(token)
    title = snap["title"] or "Ayma report"
    desc = snap["summary"] or "A report from Ayma."
    sections = "".join(
        (f"<h2>{escape(s.get('heading') or '')}</h2>" if s.get("heading") else "")
        + "".join(_block_html(b) for b in s.get("blocks") or [])
        for s in snap["sections"]
    )
    buttons = "".join(
        f"<a href='{escape(u)}'>{escape(label)}</a>" for label, u in _store_links()
    )
    return f"""<!doctype html>
<html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>{escape(title)} · Ayma</title>
<meta name=description content="{escape(desc, quote=True)}">
<meta property=og:type content=article>
<meta property=og:site_name content=Ayma>
<meta property=og:title content="{escape(title, quote=True)}">
<meta property=og:description content="{escape(desc, quote=True)}">
<meta property=og:url content="{escape(url, quote=True)}">
<meta property=og:image content="{escape(url, quote=True)}/card.png">
<meta property=og:image:width content=1200>
<meta property=og:image:height content=630>
<meta name=twitter:card content=summary_large_image>
<meta name=twitter:title content="{escape(title, quote=True)}">
<meta name=twitter:description content="{escape(desc, quote=True)}">
<meta name=twitter:image content="{escape(url, quote=True)}/card.png">
<meta name=robots content="noindex">
<style>{_CSS}</style></head><body>
<div class=banner><strong>Ayma</strong><div class=btns>{buttons or "<span>Get the Ayma app</span>"}</div></div>
<main><h1>{escape(title)}</h1>{sections}
<div class=cta><p class=k>Want a report like this about you?</p>
<a href="{escape(url, quote=True)}">Open in Ayma</a>{buttons}</div></main></body></html>"""


_ASCII_PUNCT = str.maketrans(
    {"\u2014": "-", "\u2013": "-", "\u2026": "...", "\u2018": "'",
     "\u2019": "'", "\u201c": '"', "\u201d": '"'}
)


def _printable(text: str) -> str:
    """Card text the bundled font can draw: common punctuation folded to
    ASCII, anything outside Latin dropped (it would render as tofu)."""
    return "".join(c for c in text.translate(_ASCII_PUNCT) if ord(c) <= 0x24F)


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    return ImageFont.load_default(size=size)


def _wrap(draw: ImageDraw.ImageDraw, text: str, font, width: int) -> list[str]:
    lines: list[str] = []
    line = ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if line and draw.textlength(trial, font=font) > width:
            lines.append(line)
            line = word
        else:
            line = trial
    if line:
        lines.append(line)
    return lines


def render_card(snap: dict, fmt: str) -> bytes:
    """A branded PNG for the snapshot: ``story`` (1080x1920) or ``link``
    (1200x630, the link-preview ratio)."""
    w, h = CARD_SIZES[fmt]
    img = Image.new("RGB", (w, h), _BG_TOP)
    draw = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        draw.line(
            [(0, y), (w, y)],
            fill=tuple(
                round(a + (b - a) * t) for a, b in zip(_BG_TOP, _BG_BOTTOM)
            ),
        )
    scale = w / 1080 if fmt == "story" else h / 1920 * 1.6
    pad = round(80 * (1 if fmt == "story" else 0.8))
    inner = w - 2 * pad
    y = pad if fmt == "link" else round(h * 0.18)

    draw.text((pad, y), "Ayma", font=_font(round(64 * max(scale, 0.8))), fill=_ACCENT)
    y += round(110 * max(scale, 0.8))

    title_font = _font(round(88 * max(scale, 0.6)))
    lines = _wrap(draw, _printable(snap["title"]) or "Ayma report", title_font, inner)[
        : 4 if fmt == "story" else 2
    ]
    for ln in lines:
        draw.text((pad, y), ln, font=title_font, fill=_INK)
        y += round(110 * max(scale, 0.6))
    y += round(30 * max(scale, 0.6))

    body_font = _font(round(48 * max(scale, 0.6)))
    max_lines = 9 if fmt == "story" else 3
    for ln in _wrap(draw, _printable(snap["summary"]), body_font, inner)[:max_lines]:
        draw.text((pad, y), ln, font=body_font, fill=_MUTE)
        y += round(66 * max(scale, 0.6))

    foot_font = _font(round(44 * max(scale, 0.7)))
    draw.text(
        (pad, h - pad - round(44 * max(scale, 0.7))),
        CONFIG.share_base_url.split("://", 1)[-1],
        font=foot_font,
        fill=_ACCENT,
    )
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()
