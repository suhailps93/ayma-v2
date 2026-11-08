// Logo unification (founder, 2026-11-07): the nav-bar orb looked different
// from the voice-screen orb — during a live call the small orb kept
// saturated pink "Cherry Fuchsia" highlights while the big orb (same saved
// terracotta accent) read pale and warm — and two other in-app logos (the
// loader, the Appearance report card) were a bundled PNG frozen at the
// default accent. These tests pin the fix: one painter, one set of colours,
// at every size and placement.
import "dart:io";
import "dart:typed_data";
import "dart:ui" as ui;

import "package:ayma_flutter/theme.dart";
import "package:ayma_flutter/widgets/ayma_orb.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

const _terra = Color(0xFFE07A5F);
const _green = Color(0xFF2EAD55);

Future<ByteData> _render({
  required double size,
  required AymaOrbState state,
  required bool voiceLive,
  required double amplitude,
  required double t,
  required Color accent,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size, size),
    Paint()..color = AymaColors.darkBg,
  );
  AymaOrbPainter(
    t: t,
    fromState: state,
    toState: state,
    transitionT: 1,
    amplitude: amplitude,
    accent: accent,
    reducedMotion: false,
    showGlow: true,
    voiceLive: voiceLive,
  ).paint(canvas, Size(size, size));
  final image = await recorder.endRecording().toImage(
    size.toInt(),
    size.toInt(),
  );
  return (await image.toByteData())!;
}

/// Share of clearly-coloured pixels in the pink/magenta hue bin (330-359)
/// that the broken compact path produced at nav-bar size. (Terracotta and
/// Cherry Fuchsia hues are only ~23 degrees apart, so this uses the narrow
/// magenta bin the glow tones leaked into, not a window around the default.)
double _magentaShare(ByteData data) {
  var coloured = 0;
  var magenta = 0;
  for (var i = 0; i < data.lengthInBytes; i += 4) {
    final c = Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
    if (c.a < 0.5) continue;
    final hsl = HSLColor.fromColor(c);
    if (hsl.saturation < 0.4 || hsl.lightness < 0.2 || hsl.lightness > 0.85) {
      continue;
    }
    coloured++;
    if (hsl.hue >= 330 && hsl.hue < 360) magenta++;
  }
  return coloured == 0 ? 0 : magenta / coloured;
}

void main() {
  testWidgets(
    "nav-size live orb has no leftover pink cast the voice-size orb lacks",
    (tester) async {
      for (final accent in [_terra, _green]) {
        final nav = (await tester.runAsync(
          () => _render(
            size: 64,
            state: AymaOrbState.speaking,
            voiceLive: true,
            amplitude: 0.6,
            t: 0.3,
            accent: accent,
          ),
        ))!;
        final voice = (await tester.runAsync(
          () => _render(
            size: 220,
            state: AymaOrbState.speaking,
            voiceLive: true,
            amplitude: 0.6,
            t: 0.3,
            accent: accent,
          ),
        ))!;
        expect(
          _magentaShare(voice),
          lessThan(0.05),
          reason: "voice-size orb magenta share for $accent",
        );
        expect(
          _magentaShare(nav),
          lessThan(0.05),
          reason:
              "nav-size orb must match the voice-size orb for $accent "
              "(was ~0.14 at the terracotta accent before the fix)",
        );
      }
    },
  );

  testWidgets(
    "the orb repaints in the new accent when the theme accent changes",
    (tester) async {
      Color paintedAccent() {
        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(AymaOrb),
            matching: find.byType(CustomPaint),
          ),
        );
        return (paint.painter! as AymaOrbPainter).accent;
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.darkWithAccent(_terra),
          home: const Scaffold(body: Center(child: AymaOrb(size: 64))),
        ),
      );
      expect(paintedAccent(), _terra);

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.darkWithAccent(_green),
          home: const Scaffold(body: Center(child: AymaOrb(size: 64))),
        ),
      );
      // MaterialApp cross-fades ThemeData (~200ms): the orb rebuilds
      // through the fade and must land exactly on the new accent, never
      // stay parked on the previous one (or on the Cherry Fuchsia default).
      await tester.pump(const Duration(milliseconds: 300));
      expect(paintedAccent(), _green);
    },
  );

  testWidgets("AymaOrbMark paints the canonical painter in its given accent", (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.darkWithAccent(AymaColors.accent),
        home: const Scaffold(
          body: Center(child: AymaOrbMark(size: 48, accent: _terra)),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(AymaOrbMark),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter! as AymaOrbPainter;
    expect(painter.accent, _terra);
    expect(painter.voiceLive, isFalse);
  });

  test("no in-app code references the frozen PNG logo any more", () {
    final lib = Directory("lib");
    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith(".dart")) {
        final text = entity.readAsStringSync();
        if (text.contains("ayma_orb_ios") ||
            text.contains("assets/icon/ayma_orb")) {
          offenders.add(entity.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          "every in-app logo renders from AymaOrbPainter; a bundled "
          "orb PNG can only show the accent it was rendered with",
    );
  });

  test("tab bar and voice screen both build their logo from AymaOrb", () {
    final tabBar = File("lib/widgets/ayma_tab_bar.dart").readAsStringSync();
    final voice = File("lib/screens/voice_call_screen.dart").readAsStringSync();
    expect(tabBar, contains("AymaOrb("));
    expect(voice, contains("AymaOrb("));
  });
}
