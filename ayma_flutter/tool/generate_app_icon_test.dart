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
      t: 0,
      fromState: AymaOrbState.idle,
      toState: AymaOrbState.idle,
      transitionT: 1,
      amplitude: 0,
      accent: AymaColors.accent,
      // Calm idle frame, simplified highlights, no rings — the spec's own
      // wording for the static mark maps directly onto reduced motion.
      reducedMotion: true,
      showGlow: false,
      showListeningRings: false,
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
