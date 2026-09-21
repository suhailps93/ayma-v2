import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline verification renderer for the Cherry Fuchsia glass-orb redesign
/// (visual-only pass over `AymaOrbPainter`). Renders the orb at the
/// founder's acceptance-criteria sizes (128/64/48/32px) for the calm-idle
/// frame, plus a couple of the animated states at 120px so the flutter/pulse
/// motion states are visible too. Not part of the regular test suite — run
/// explicitly:
///   flutter test tool/render_orb_verification_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> renderTo(
    String path, {
    required double size,
    required AymaOrbState state,
    double t = 185,
    double amplitude = 0,
    bool background = true,
    double staticDetail = 1.0,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (background) {
      // Paint on a neutral dark card-like background so translucency/edge
      // lighting is actually visible (matches how the orb sits in-app,
      // rather than judging it against pure transparency).
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, size, size),
        ui.Paint()..color = const ui.Color(0xFF15121A),
      );
    }
    AymaOrbPainter(
      t: t,
      fromState: state,
      toState: state,
      transitionT: 1,
      amplitude: amplitude,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: false,
      showListeningRings: false,
      // Defaults to 1.0 — the exact value every real call site gets, so
      // these renders are an honest, unboosted capture of what ships (not
      // the persistence-of-vision buyback tool/generate_app_icon_test.dart
      // uses for a literal static icon asset).
      staticDetail: staticDetail,
    ).paint(canvas, ui.Size(size, size));

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.round(), size.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    // ignore: avoid_print
    print('Wrote $path (${bytes.lengthInBytes} bytes)');
  }

  test('render idle orb at 128/64/48/32px', () async {
    for (final size in [128.0, 64.0, 48.0, 32.0]) {
      await renderTo(
        '/tmp/ayma_orb_verify/idle_${size.round()}.png',
        size: size,
        state: AymaOrbState.idle,
      );
    }
  });

  test('render other states at 120px for reference', () async {
    await renderTo(
      '/tmp/ayma_orb_verify/listening_120.png',
      size: 120,
      state: AymaOrbState.listening,
      amplitude: 0.6,
      t: 40,
    );
    await renderTo(
      '/tmp/ayma_orb_verify/speaking_120.png',
      size: 120,
      state: AymaOrbState.speaking,
      amplitude: 0.6,
      t: 40,
    );
    await renderTo(
      '/tmp/ayma_orb_verify/thinking_120.png',
      size: 120,
      state: AymaOrbState.thinking,
      t: 40,
    );
  });

  test('render idle orb large for close petal/overlap inspection', () async {
    await renderTo(
      '/tmp/ayma_orb_verify/idle_512_inspect.png',
      size: 512,
      state: AymaOrbState.idle,
    );
    // Reference only — approximates what persistence-of-vision buys the
    // live, continuously-animating widget back, at the same held frame.
    await renderTo(
      '/tmp/ayma_orb_verify/idle_512_inspect_animated_reference.png',
      size: 512,
      state: AymaOrbState.idle,
      staticDetail: 1.6,
    );
  });

  test('render idle orb at 128px on transparent bg (app-icon-style check)',
      () async {
    await renderTo(
      '/tmp/ayma_orb_verify/idle_128_transparent.png',
      size: 128,
      state: AymaOrbState.idle,
      background: false,
    );
  });
}
