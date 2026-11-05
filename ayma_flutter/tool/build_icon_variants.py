"""Derives per-platform launcher-icon sources from assets/icon/ayma_sol_icon.png
(the orb on a transparent 1024 canvas, written by generate_app_icon_test.dart).

Regeneration order (run from ayma_flutter/):
  flutter test tool/generate_app_icon_test.dart   # renders ayma_sol_icon.png
  python3 tool/build_icon_variants.py              # writes the per-platform sources
  dart run flutter_launcher_icons                  # generates every mipmap/drawable
  python3 tool/build_icon_variants.py              # re-stamp the OPAQUE round icons

The final re-run is required: flutter_launcher_icons regenerates
ic_launcher_round.png as a circle crop with transparent corners, which Android
search / app-drawer tiles render as a black box behind the orb. This script
overwrites those round rasters with the opaque, full-bleed brand art.
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
#
# This writes ayma_orb_ios_launcher.png — NOT ayma_orb_ios.png. That file is
# the in-app logo mark (loaded by AymaLogoLoader + AppearanceReportCard), and
# per the founder ruling (2026-11-05) nothing inside the app changes with the
# launcher icon: the resting-orb ayma_orb_ios.png stays byte-identical, and
# only the launcher pipeline (pubspec image_path_ios + this script) points at
# the voice-live art.
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
ios.convert('RGB').save(OUT + 'ayma_orb_ios_launcher.png')

# Android legacy (pre-API 26) launcher icon: the same opaque full-bleed art as
# iOS, so no launcher can paint a black box behind transparent corners.
ios.convert('RGB').save(OUT + 'ayma_orb_android_legacy.png')

# Android round icon (manifest roundIcon + mipmap-anydpi-v26/ic_launcher_round.xml
# for adaptive launchers). Rendered OPAQUE and full-bleed — identical art to the
# legacy square icon — and deliberately NOT circle-cropped. A circle crop leaves
# transparent corners, and Android's app-drawer / search tiles draw this raster
# inside a rounded SQUARE without applying their own circular mask, so those
# corners showed as a black box behind the orb. Opaque brand art means no surface
# can paint black. API 26+ launchers ignore this raster and mask the adaptive
# icon (ic_launcher_round.xml, pink background) above it instead.
RES = 'android/app/src/main/res/'
round_icon = ios.convert('RGB')
for density, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
    round_icon.resize((size, size), Image.LANCZOS).save(
        RES + 'mipmap-' + density + '/ic_launcher_round.png')
