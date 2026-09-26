import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline generator for the Ayma Sol app-icon source image.
///
/// Renders the exact calm-idle frame straight out of [AymaOrbPainter] — no
/// separate logo artwork, per the spec's "App icon / static mark" section —
/// at 1024x1024 with a transparent background, ready for
/// `flutter_launcher_icons` to turn into both platforms' icon sets.
///
/// Not part of the regular test suite (lives under tool/, which `flutter
/// test` doesn't scan by default). Run explicitly:
///   flutter test tool/generate_app_icon_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate the Ayma Sol app-icon PNG', () async {
    const canvasSize = 1024.0;
    // Android adaptive icons crop/mask to roughly the inner 66% of the
    // canvas depending on launcher shape; sit a little inside that so the
    // orb is never clipped, whatever mask is applied.
    const orbSize = canvasSize * 0.72;
    const inset = (canvasSize - orbSize) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.save();
    canvas.translate(inset, inset);
    AymaOrbPainter(
      // t=0 (and every phase near it) lands the idle blobs' orbit/wobble
      // sines at values that leave the three internal blobs nearly
      // concentric and barely deformed — a static frame from a genuinely
      // flat instant in the cycle. t=185 is a phase, sampled and chosen by
      // eye, where the blobs separate into a clearly readable curved
      // internal band instead of overlapping into a featureless wash.
      t: 185,
      fromState: AymaOrbState.idle,
      toState: AymaOrbState.idle,
      transitionT: 1,
      amplitude: 0,
      accent: AymaColors.accent,
      // reducedMotion(true) also multiplies idle's already-subtle wobble by
      // 0.25x and its circulation by 0.08x — meant for continuous
      // accessibility playback, not a single detail-bearing frame — so it
      // is left off here; showGlow(false) already gives the calm-idle,
      // no-glow look the spec asks for regardless.
      reducedMotion: false,
      showGlow: false,
      // A static PNG has no persistence-of-vision to sell the internal
      // blobs' motion the way the live, continuously-drifting widget does
      // — staticDetail buys that back as held contrast (more blob alpha +
      // wobble amplitude, same shapes/positions/palette) without touching
      // the default (1.0) used everywhere the orb actually animates.
      staticDetail: 2.6,
    ).paint(canvas, const ui.Size(orbSize, orbSize));
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(canvasSize.round(), canvasSize.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('assets/icon/ayma_sol_icon.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  });
}
