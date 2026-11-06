"""Derives per-platform launcher-icon sources from assets/icon/ayma_sol_icon.png
(the voice-live orb + glow on a transparent 1024 canvas, written by
generate_app_icon_test.dart).

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

# The launcher dark: AymaColors.darkBg (#131210) — the voice call screen's own
# background, sampled (19, 18, 16) off the founder's speaking-state target
# (FOUNDER_TARGET.png). Every opaque variant sits on it so the orb's neon rim,
# halo and pooled floor glow read exactly as they do mid-call.
DARK = (19, 18, 16)

# Task-2 correction: the voice-live render carries a real outer glow (halo +
# floor wash) whose faint pixels reach the canvas edges, so cropping to the
# alpha bbox grabs ~the whole canvas and shrinks the sphere in every variant.
# Crop from the harness's known geometry instead: the orb is painted at
# 0.72*N, centered.
ORB = round(N * 0.72)  # 737: sphere diameter in SRC
C0 = (N - ORB) // 2  # 143 (true inset 143.5; 1px either way is sub-glow)
SPHERE_BOX = (C0, C0, C0 + ORB + 1, C0 + ORB + 1)  # tight 738px sphere
BLOOM = 24  # keep the neon rim bloom just outside the silhouette
FG_BOX = (SPHERE_BOX[0] - BLOOM, SPHERE_BOX[1] - BLOOM,
          SPHERE_BOX[2] + BLOOM, SPHERE_BOX[3] + BLOOM)
FG_SIZE = (ORB + 1) + 2 * BLOOM  # 786

src = Image.open(SRC).convert('RGBA')
orb = src.crop(SPHERE_BOX)
fgsrc = src.crop(FG_BOX)


def place(img, diameter):
    canvas = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    scaled = img.resize((diameter, diameter), Image.LANCZOS)
    canvas.alpha_composite(scaled, ((N - diameter) // 2, (N - diameter) // 2))
    return canvas


# Android adaptive foreground: the sphere keeps its long-standing 0.72*N
# safe-zone size (the launcher's circular mask never clips past it) with the
# rim bloom riding along into the transparent margin; the background layer
# below is the launcher dark, hidden behind the overscan.
fg = place(fgsrc, FG_SIZE)
fg.save(OUT + 'ayma_orb_android_fg.png')
safe = place(orb, round(N * 0.62))
# Adaptive background layer: the launcher dark, hidden behind the overscan.
Image.new('RGBA', (N, N), DARK + (255,)).save(OUT + 'ayma_orb_android_bg.png')

# Themed (monochrome) layer: orb silhouette with the lighter petals cut out.
# The radial mask keeps the voice-live halo out of the silhouette: `safe` is a
# square crop, and the halo/floor glow living in its corners would otherwise
# ship as a visible grey rounded square around the mark.
MONO_R = round(N * 0.62) / 2  # 317.5: `safe`'s sphere radius
mono = Image.new('RGBA', (N, N), (0, 0, 0, 0))
px, mp = safe.load(), mono.load()
for y in range(N):
    for x in range(N):
        r, g, b, a = px[x, y]
        if a:
            dist = ((x - N / 2) ** 2 + (y - N / 2) ** 2) ** 0.5
            if dist > MONO_R + 1:
                continue
            if dist > MONO_R - 1:
                a = round(a * (MONO_R + 1 - dist) / 2)
            cut = min(1.0, max(0.0, (g - 90) / 60))
            mp[x, y] = (0, 0, 0, round(a * (1 - cut)))
mono.save(OUT + 'ayma_orb_android_mono.png')

# Full-bleed opaque art (iOS, Android legacy, round re-stamp): the whole
# source canvas — sphere AND its halo/floor glow — scaled as one so the
# sphere lands at 0.92*N on the launcher dark, reproducing the live call
# composition (halo hugging the rim, magenta pooled under the sphere, dark
# margins) instead of bleeding the sphere past the edges. The old 1.04
# overscan existed so no seam could show between orb art and a contrasting
# backdrop; on the uniform dark there is no seam at any scale.
#
# This writes ayma_orb_ios_launcher.png — NOT ayma_orb_ios.png. That file is
# the in-app logo mark (loaded by AymaLogoLoader + AppearanceReportCard), and
# per the founder ruling (2026-11-05) nothing inside the app changes with the
# launcher icon: the resting-orb ayma_orb_ios.png stays byte-identical, and
# only the launcher pipeline (pubspec image_path_ios + this script) points at
# the voice-live art.
scale = (N * 0.92) / ORB
big_size = round(N * scale)
big = src.resize((big_size, big_size), Image.LANCZOS)
x0 = (big_size - N) // 2
full = big.crop((x0, x0, x0 + N, x0 + N))
ios = Image.new('RGBA', (N, N), DARK + (255,))
ios.alpha_composite(full)
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
# icon (ic_launcher_round.xml, dark background) above it instead.
RES = 'android/app/src/main/res/'
round_icon = ios.convert('RGB')
for density, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
    round_icon.resize((size, size), Image.LANCZOS).save(
        RES + 'mipmap-' + density + '/ic_launcher_round.png')
