"""Derives per-platform launcher-icon sources from assets/icon/ayma_sol_icon.png
(the orb on a transparent 1024 canvas, written by generate_app_icon_test.dart).

Run from ayma_flutter/ before `dart run flutter_launcher_icons`:
  python3 tool/build_icon_variants.py
"""
from PIL import Image

SRC = 'assets/icon/ayma_sol_icon.png'
OUT = 'assets/icon/'
N = 1024

src = Image.open(SRC).convert('RGBA')
orb = src.crop(src.getchannel('A').getbbox())


def place(img, diameter):
    canvas = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    scaled = img.resize((diameter, diameter), Image.LANCZOS)
    canvas.alpha_composite(scaled, ((N - diameter) // 2, (N - diameter) // 2))
    return canvas


# Android adaptive foreground: the orb overscans the launcher's circular mask
# (radius 33% of the canvas) so no gap is left for the launcher to paint black
# behind a transparent layer; the background layer below is the orb's rim color.
fg = place(orb, round(N * 0.72))
fg.save(OUT + 'ayma_orb_android_fg.png')
safe = place(orb, round(N * 0.62))
# Android legacy launcher icon: the orb circle itself, transparent corners.
place(orb, round(N * 0.96)).save(OUT + 'ayma_orb_android_legacy.png')
# Adaptive background layer: the orb's rim color, hidden behind the overscan.
Image.new('RGBA', (N, N), (219, 78, 104, 255)).save(OUT + 'ayma_orb_android_bg.png')

# Themed (monochrome) layer: orb silhouette with the lighter petals cut out.
mono = Image.new('RGBA', (N, N), (0, 0, 0, 0))
px, mp = safe.load(), mono.load()
for y in range(N):
    for x in range(N):
        r, g, b, a = px[x, y]
        if a:
            cut = min(1.0, max(0.0, (g - 90) / 60))
            mp[x, y] = (0, 0, 0, round(a * (1 - cut)))
mono.save(OUT + 'ayma_orb_android_mono.png')

# iOS: opaque, full-bleed. Diagonal gradient sampled from the orb's own rim
# fills the corners; the orb is scaled past the canvas edge so no foreign
# frame shows once iOS applies its rounded mask.
tl, br = (220, 80, 106), (190, 55, 81)
bg = Image.new('RGB', (N, N))
bp = bg.load()
for y in range(N):
    for x in range(N):
        t = (x + y) / (2 * (N - 1))
        bp[x, y] = tuple(round(tl[i] + (br[i] - tl[i]) * t) for i in range(3))
big = orb.resize((round(N * 1.04),) * 2, Image.LANCZOS)
ios = bg.convert('RGBA')
ios.alpha_composite(big, ((N - big.width) // 2, (N - big.height) // 2))
ios.convert('RGB').save(OUT + 'ayma_orb_ios.png')
