import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

import 'icon_render_pose.dart';

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
      // The live call's speaking hero frame: `speaking` is the only state
      // with real wing flutter (flutterAmount 1.0) and the full white-hot
      // connected glow, and amplitude 1.0 is the loudest-syllable peak of
      // the live mic/Ayma level. t=7.1915 is the flutter cycle's symmetric
      // slightly-closed instant (both wings at -0.0916/+0.0915 rad, joint
      // -0.0916, symmetric to ~2e-4 — scanned offline against the painter's
      // own angle math): positive rotation opens a wing outward+down, so the
      // old t=9.9642 joint-maximum-OPEN frame read as a wide flat U — the
      // resting orb (Task 2, founder eye-check). This frame holds the raised
      // bright heart/V of the live speaking orb (FOUNDER_TARGET.png). The
      // pose lives in `tool/icon_render_pose.dart`, shared with
      // `test/launcher_icon_pose_test.dart`, which fails if this frame ever
      // drifts back to the flat/resting read.
      t: IconRenderPose.t,
      fromState: IconRenderPose.fromState,
      toState: IconRenderPose.toState,
      transitionT: IconRenderPose.transitionT,
      amplitude: IconRenderPose.amplitude,
      // The launcher can't follow the user's runtime accent pick, so it uses
      // the default — same as every live call on a fresh install.
      accent: AymaColors.accent,
      reducedMotion: false,
      // The voice-live glow, on: exactly what VoiceCallScreen passes during
      // a live call (showGlow default true, voiceLive = isListening).
      showGlow: IconRenderPose.showGlow,
      voiceLive: IconRenderPose.voiceLive,
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
