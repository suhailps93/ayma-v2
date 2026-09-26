import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline visual-verification generator for the founder's two `ayma_orb.dart`
/// follow-ups on the "angelic glow" redesign (`493278a`):
///   1. "The old voice animations are gone. I want it to flutter like before."
///   2. "Add some padding to the petals so it doesn't touch the edge."
///
/// Renders rest AND motion-peak frames (same peak-`t` technique as
/// `render_orb_voice_live_test.dart`: `t` chosen so
/// `sin(t * 9.5 * speed) ~ 1` for speaking's flutter, `sin(t * 1.3 * speed)
/// ~ 1` for listening's pulse) at both a large size and the nav-bar's new
/// 64px orb size, at max mic amplitude (the worst case for rim clearance).
/// A thin cyan ring is drawn at the sphere's own clip radius on every frame
/// so any petal pixel crossing it is immediately obvious by eye. Not part of
/// the regular suite — run explicitly:
///   flutter test tool/render_orb_rim_flutter_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> render({
    required String name,
    required double canvasSize,
    required double orbSize,
    required AymaOrbState state,
    required double t,
    double amplitude = 1.0,
  }) async {
    final inset = (canvasSize - orbSize) / 2;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, canvasSize, canvasSize),
      ui.Paint()..color = AymaColors.darkBg,
    );

    canvas.save();
    canvas.translate(inset, inset);
    AymaOrbPainter(
      t: t,
      fromState: state,
      toState: state,
      transitionT: 1,
      amplitude: amplitude,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      voiceLive: false,
    ).paint(canvas, ui.Size(orbSize, orbSize));
    canvas.restore();

    // Reference ring at the exact clip radius, so any petal crossing it is
    // unambiguous.
    canvas.drawCircle(
      ui.Offset(canvasSize / 2, canvasSize / 2),
      orbSize / 2,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const ui.Color(0xFF00E5FF),
    );

    final picture = recorder.endRecording();
    final image =
        await picture.toImage(canvasSize.round(), canvasSize.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('build/orb_rim_flutter_verification/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  }

  test('render rim-clearance + flutter-liveliness verification frames',
      () async {
    // Speaking flutter peak: sin(t * 9.5 * 1.55) ~ 1.
    const tSpeakPeak = 0.1068;
    // Listening pulse peak: sin(t * 1.3 * 1.25) ~ 1.
    const tListenPeak = 0.967;

    for (final (sizeName, orbSize, canvasSize) in [
      ('large', 160.0, 220.0),
      ('nav64', 64.0, 110.0),
    ]) {
      await render(
        name: '00_${sizeName}_idle_rest',
        canvasSize: canvasSize,
        orbSize: orbSize,
        state: AymaOrbState.idle,
        t: 0,
        amplitude: 0,
      );
      await render(
        name: '01_${sizeName}_speaking_rest_t0',
        canvasSize: canvasSize,
        orbSize: orbSize,
        state: AymaOrbState.speaking,
        t: 0,
        amplitude: 0,
      );
      await render(
        name: '02_${sizeName}_speaking_flutterpeak_amp1',
        canvasSize: canvasSize,
        orbSize: orbSize,
        state: AymaOrbState.speaking,
        t: tSpeakPeak,
        amplitude: 1.0,
      );
      await render(
        name: '03_${sizeName}_speaking_flutterpeak_amp0_6',
        canvasSize: canvasSize,
        orbSize: orbSize,
        state: AymaOrbState.speaking,
        t: tSpeakPeak,
        amplitude: 0.6,
      );
      await render(
        name: '04_${sizeName}_listening_pulsepeak_amp1',
        canvasSize: canvasSize,
        orbSize: orbSize,
        state: AymaOrbState.listening,
        t: tListenPeak,
        amplitude: 1.0,
      );
      await render(
        name: '05_${sizeName}_listening_rest_t0',
        canvasSize: canvasSize,
        orbSize: orbSize,
        state: AymaOrbState.listening,
        t: 0,
        amplitude: 0,
      );
    }
  });
}
