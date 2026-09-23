import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline visual-verification generator for the `voiceLive` silver/metallic
/// material added to [AymaOrbPainter] (founder ask: "when a voice is
/// activated, the wings should turn shiny silver ... and glowing").
///
/// Distinct from `render_orb_verification_test.dart` (which verifies the
/// Cherry Fuchsia glass-orb redesign itself, in the ordinary accent
/// material) — this one is specifically about the `voiceLive` material swap,
/// rendered against the CURRENT petal geometry/gradient code (post the three
/// orb-redesign commits), so the silver treatment is checked against what
/// actually ships, not a stale fork-point shape. Same technique as
/// `tool/generate_app_icon_test.dart`. Not part of the regular suite (tool/
/// isn't scanned by `flutter test` by default). Run explicitly:
///   flutter test tool/render_orb_voice_live_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> render({
    required String name,
    required double canvasSize,
    required double orbSize,
    required AymaOrbState state,
    required bool voiceLive,
    double amplitude = 0,
    double t = 0,
    bool showGlow = true,
    bool showListeningRings = false,
  }) async {
    final inset = (canvasSize - orbSize) / 2;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Composite on the app's real dark background so the material reads the
    // way it will in the actual UI, not floating on test-harness white.
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
      showGlow: showGlow,
      showListeningRings: showListeningRings,
      // Buys back the "always drifting" persistence-of-vision detail a
      // single still frame can't have on its own — same reasoning as the
      // app-icon generator.
      staticDetail: 2.6,
      voiceLive: voiceLive,
    ).paint(canvas, ui.Size(orbSize, orbSize));
    canvas.restore();

    final picture = recorder.endRecording();
    final image =
        await picture.toImage(canvasSize.round(), canvasSize.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull);

    final file = File('build/orb_voice_live_verification/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote ${file.path} (${bytes.lengthInBytes} bytes)');
  }

  test('render voiceLive silver states against the current orb geometry',
      () async {
    // Baseline: ordinary accent-coloured idle, voiceLive false — must look
    // exactly as it always has (current Cherry Fuchsia glass redesign), for
    // side-by-side comparison against silver.
    await render(
      name: '00_idle_accent_baseline',
      canvasSize: 240,
      orbSize: 160,
      state: AymaOrbState.idle,
      voiceLive: false,
      t: 185,
    );

    // Large (medium/large tier): listening vs speaking, both voiceLive —
    // t picked near each motion's own peak so the frame actually shows the
    // distinguishing shape rather than a neutral mid-cycle moment.
    await render(
      name: '01_listening_silver_large',
      canvasSize: 240,
      orbSize: 160,
      state: AymaOrbState.listening,
      voiceLive: true,
      amplitude: 0.6,
      t: 0.967, // near listening's pulse peak (sin(t*1.3*1.25) ~ 1)
      showListeningRings: true,
    );
    await render(
      name: '02_speaking_silver_large',
      canvasSize: 240,
      orbSize: 160,
      state: AymaOrbState.speaking,
      voiceLive: true,
      amplitude: 0.6,
      t: 0.1068, // near speaking's flutter peak (sin(t*9.5*1.55) ~ 1)
    );

    // Small tier (nav tab / launcher button scale) — glow/rings auto-suppress
    // below medium, so this checks the material still reads at that size,
    // against the current legibility-boosted small-size petal tuning.
    await render(
      name: '03_listening_silver_small',
      canvasSize: 80,
      orbSize: 48,
      state: AymaOrbState.listening,
      voiceLive: true,
      amplitude: 0.6,
      t: 0.967,
      showListeningRings: true,
    );
    await render(
      name: '04_speaking_silver_small',
      canvasSize: 80,
      orbSize: 48,
      state: AymaOrbState.speaking,
      voiceLive: true,
      amplitude: 0.6,
      t: 0.1068,
    );

    // Waking/connecting (thinking + voiceLive) at nav-bar scale — what the
    // tab bar/launcher show while the call is still connecting.
    await render(
      name: '05_thinking_silver_small',
      canvasSize: 80,
      orbSize: 48,
      state: AymaOrbState.thinking,
      voiceLive: true,
      t: 0.4,
    );

    // Same speaking/listening pair but voiceLive:false, same t/amplitude —
    // direct proof the material swap (not the motion) is what's different.
    await render(
      name: '06_listening_accent_large_forcompare',
      canvasSize: 240,
      orbSize: 160,
      state: AymaOrbState.listening,
      voiceLive: false,
      amplitude: 0.6,
      t: 0.967,
      showListeningRings: true,
    );
    await render(
      name: '07_speaking_accent_large_forcompare',
      canvasSize: 240,
      orbSize: 160,
      state: AymaOrbState.speaking,
      voiceLive: false,
      amplitude: 0.6,
      t: 0.1068,
    );
  });
}
