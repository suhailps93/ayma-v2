import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline generator for the Ayma Sol app-icon source image.
///
/// Renders the voice-live frame straight out of [AymaOrbPainter] — the exact
/// orb a live voice call shows (founder ruling, 2026-11-05: the launcher icon,
/// outside the app, is the orb as it looks while Ayma voice is activated:
/// wings bright and spread in their flutter pose, with the live glow) — at
/// 1024x1024 with a transparent background, ready for
/// `flutter_launcher_icons` to turn into both platforms' icon sets.
///
/// Nothing inside the app changes: this only feeds the launcher pipeline
/// (`tool/build_icon_variants.py` + `flutter_launcher_icons`). In particular
/// `assets/icon/ayma_orb_ios.png` — the in-app logo mark loaded by
/// `AymaLogoLoader` and `AppearanceReportCard` — is deliberately NOT
/// regenerated from this; the iOS launcher art goes to a separate source file
/// (see `build_icon_variants.py`).
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
      // The live call's brightest, most-spread flutter frame: `speaking` is
      // the only state with real wing flutter (flutterAmount 1.0) and the
      // full white-hot connected glow, amplitude 1.0 is the loudest-syllable
      // peak of the live mic/Ayma level, and t=9.9642 is the joint maximum
      // of the two wings' opening angles over a full motion cycle (scanned
      // offline against the painter's own angle math: both wings land within
      // ~4% of their soft-open ceiling at once, versus the old single-wing
      // flutter peak t=0.1068 where the left wing sits half-closed).
      t: 9.9642,
      fromState: AymaOrbState.speaking,
      toState: AymaOrbState.speaking,
      transitionT: 1,
      amplitude: 1,
      // The launcher can't follow the user's runtime accent pick, so it uses
      // the default — same as every live call on a fresh install.
      accent: AymaColors.accent,
      reducedMotion: false,
      // The voice-live glow, on: exactly what VoiceCallScreen passes during
      // a live call (showGlow default true, voiceLive = isListening).
      showGlow: true,
      voiceLive: true,
      // staticDetail stays at its 1.0 default — the value every live call
      // site uses (the widget never passes it). The old 2.6 "held contrast"
      // boost was written for the retired amorphous blobs and diverged the
      // icon's compositing from the in-app orb (2026-09-27, founder bug);
      // 1.0 reproduces the live orb bit-for-bit at icon scale.
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
