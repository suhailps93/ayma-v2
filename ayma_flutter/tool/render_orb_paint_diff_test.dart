import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:flutter_test/flutter_test.dart';

import 'baseline/head_orb_painter.dart';

/// Pixel-equivalence proof for the 2026-09-27 paint() optimization pass
/// (shader/color caching in `AymaOrbPainter`): renders the vendored HEAD
/// painter (`tool/baseline/head_orb_painter.dart`) and the live painter at
/// identical (t, state, amplitude, size, voiceLive, transition) params and
/// asserts a zero per-channel pixel diff, for a matrix that covers every
/// state, both benchmark sizes, motion peaks, transitions, the small-size
/// legibility ramp and the voice-live glow.
///
/// Also writes side-by-side before/after/(amplified) diff PNGs for a few
/// representative cases to `build/orb_paint_diff/` so the equivalence can be
/// checked by eye, per the repo's render-verification pattern
/// (`tool/render_orb_*_test.dart`). Run explicitly:
///   flutter test tool/render_orb_paint_diff_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> render(
    CustomPainter painter,
    double size,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // Dark app background behind the orb, same as the other render tools —
    // the painter composites translucent layers, so equivalence must hold
    // over a real backdrop.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size, size),
      ui.Paint()..color = AymaColors.darkBg,
    );
    painter.paint(canvas, ui.Size(size, size));
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.round(), size.round());
    picture.dispose();
    return image;
  }

  Future<void> savePng(ui.Image image, String name) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/orb_paint_diff/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path}');
  }

  test('optimized painter is pixel-identical to HEAD across the matrix',
      () async {
    // Motion peaks from tool/render_orb_rim_flutter_test.dart.
    const tSpeakPeak = 0.1068;
    const tListenPeak = 0.967;

    final cases = <({
      String name,
      AymaOrbState from,
      AymaOrbState to,
      double transitionT,
      double t,
      double amplitude,
      bool voiceLive,
      bool reducedMotion,
      double size,
      bool png,
    })>[];

    // Every state at both benchmark sizes, at rest and mid-motion.
    for (final size in [64.0, 400.0]) {
      for (final state in AymaOrbState.values) {
        for (final (tag, t, amp) in [
          ('rest', 0.0, 0.0),
          ('motion', 3.7, 0.6),
        ]) {
          cases.add((
            name: '${state.name}_${tag}_${size.round()}',
            from: state,
            to: state,
            transitionT: 1,
            t: t,
            amplitude: amp,
            voiceLive: false,
            reducedMotion: false,
            size: size,
            png: state == AymaOrbState.speaking && tag == 'motion',
          ));
        }
      }
    }
    // Motion peaks, loud amplitude.
    cases.addAll([
      (
        name: 'speaking_flutterpeak_amp1_400',
        from: AymaOrbState.speaking,
        to: AymaOrbState.speaking,
        transitionT: 1,
        t: tSpeakPeak,
        amplitude: 1.0,
        voiceLive: false,
        reducedMotion: false,
        size: 400.0,
        png: true,
      ),
      (
        name: 'listening_pulsepeak_amp1_400',
        from: AymaOrbState.listening,
        to: AymaOrbState.listening,
        transitionT: 1,
        t: tListenPeak,
        amplitude: 1.0,
        voiceLive: false,
        reducedMotion: false,
        size: 400.0,
        png: false,
      ),
      // Voice-live glow (the heaviest path: angelic petal light + halos).
      (
        name: 'speaking_live_400',
        from: AymaOrbState.speaking,
        to: AymaOrbState.speaking,
        transitionT: 1,
        t: tSpeakPeak,
        amplitude: 0.8,
        voiceLive: true,
        reducedMotion: false,
        size: 400.0,
        png: true,
      ),
      (
        name: 'listening_live_64',
        from: AymaOrbState.listening,
        to: AymaOrbState.listening,
        transitionT: 1,
        t: tListenPeak,
        amplitude: 0.5,
        voiceLive: true,
        reducedMotion: false,
        size: 64.0,
        png: false,
      ),
      // Mid state-transition (blended params + blended connected glow).
      (
        name: 'transition_idle_speaking_400',
        from: AymaOrbState.idle,
        to: AymaOrbState.speaking,
        transitionT: 0.4,
        t: 1.7,
        amplitude: 0.3,
        voiceLive: true,
        reducedMotion: false,
        size: 400.0,
        png: false,
      ),
      // Small-size legibility ramp branch.
      (
        name: 'idle_tiny_18',
        from: AymaOrbState.idle,
        to: AymaOrbState.idle,
        transitionT: 1,
        t: 0.0,
        amplitude: 0.0,
        voiceLive: false,
        reducedMotion: false,
        size: 18.0,
        png: false,
      ),
      // Reduced motion (the resting math the wing-flutter toggle reuses).
      (
        name: 'listening_reduced_160',
        from: AymaOrbState.listening,
        to: AymaOrbState.listening,
        transitionT: 1,
        t: 0.0,
        amplitude: 0.5,
        voiceLive: false,
        reducedMotion: true,
        size: 160.0,
        png: false,
      ),
    ]);

    for (final c in cases) {
      final before = await render(
        HeadAymaOrbPainter(
          t: c.t,
          fromState: c.from,
          toState: c.to,
          transitionT: c.transitionT,
          amplitude: c.amplitude,
          accent: AymaColors.accent,
          reducedMotion: c.reducedMotion,
          showGlow: true,
          voiceLive: c.voiceLive,
        ),
        c.size,
      );
      final after = await render(
        AymaOrbPainter(
          t: c.t,
          fromState: c.from,
          toState: c.to,
          transitionT: c.transitionT,
          amplitude: c.amplitude,
          accent: AymaColors.accent,
          reducedMotion: c.reducedMotion,
          showGlow: true,
          voiceLive: c.voiceLive,
        ),
        c.size,
      );

      final a =
          (await before.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final b = (await after.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(a.lengthInBytes, b.lengthInBytes, reason: c.name);

      var maxDiff = 0;
      var diffPixels = 0;
      for (var i = 0; i < a.lengthInBytes; i++) {
        final d = (a.getUint8(i) - b.getUint8(i)).abs();
        if (d > 0) diffPixels++;
        if (d > maxDiff) maxDiff = d;
      }
      // ignore: avoid_print
      print('${c.name}: maxChannelDiff=$maxDiff '
          'diffChannels=$diffPixels/${a.lengthInBytes}');

      if (c.png) {
        await savePng(before, '${c.name}_before');
        await savePng(after, '${c.name}_after');
      }

      expect(maxDiff, 0,
          reason: '${c.name}: optimized paint() must stay pixel-identical '
              'at equal (t, state, amplitude)');
      before.dispose();
      after.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
