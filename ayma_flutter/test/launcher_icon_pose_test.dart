import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/icon_render_pose.dart';

/// Guards the launcher-icon render pose (Task 2, founder eye-check): the icon
/// ships the live speaking orb — wings raised in a bright heart/V with the
/// voice-live halo — not the resting read. Renders [IconRenderPose] (the exact
/// frame `tool/generate_app_icon_test.dart` rasterizes) at small scale through
/// the real [AymaOrbPainter] and checks the two measurable correlates of that
/// verdict against the Task-1 flat frame as a negative control.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const canvasSize = 256.0;
  // Same 0.72 orb-to-canvas ratio as the 1024 generator; 184px still takes
  // the painter's large-tier path, so the pose matches the shipped art.
  const orbSize = canvasSize * 0.72;
  const inset = (canvasSize - orbSize) / 2;

  Future<Uint8List> renderPose(double t) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.save();
    canvas.translate(inset, inset);
    AymaOrbPainter(
      t: t,
      fromState: IconRenderPose.fromState,
      toState: IconRenderPose.toState,
      transitionT: IconRenderPose.transitionT,
      amplitude: IconRenderPose.amplitude,
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: IconRenderPose.showGlow,
      voiceLive: IconRenderPose.voiceLive,
    ).paint(canvas, const ui.Size(orbSize, orbSize));
    canvas.restore();
    final image = await recorder
        .endRecording()
        .toImage(canvasSize.round(), canvasSize.round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes!.buffer.asUint8List();
  }

  /// Near-white wing pixel: the lit petal material, not the pink sphere, the
  /// pale resting wings (which fail the green gate), or the dark backdrop.
  bool isLitWing(int r, int g, int b, int a) =>
      a > 200 && r > 200 && g > 150 && b > 190;

  /// Topmost lit-wing row over the wing columns, or null when the wings never
  /// light (the resting read). Scanning starts below the upper
  /// highlight/specular zone (which ends ~0.39N) so only wing tips register.
  int? topWingRow(Uint8List px) {
    const n = 256; // == canvasSize
    int? top;
    for (final x in [95, 105, 151, 161]) {
      for (var y = (n * 0.40).round(); y < n; y++) {
        final o = (y * n + x) * 4;
        if (isLitWing(px[o], px[o + 1], px[o + 2], px[o + 3])) {
          top = top == null ? y : (y < top ? y : top);
          break;
        }
      }
    }
    return top;
  }

  test('icon pose holds the raised speaking V, not the flat frame', () async {
    final iconTop = topWingRow(await renderPose(IconRenderPose.t));
    final flatTop = topWingRow(await renderPose(IconRenderPose.flatControlT));
    expect(iconTop, isNotNull, reason: 'icon wings never light: resting read');
    expect(flatTop, isNotNull);
    // Measured gap is ~21px at this scale; 10px keeps half of it as margin.
    expect(iconTop, lessThan(flatTop! - 10),
        reason:
            'wing tips at y=$iconTop, flat control at y=$flatTop: the pose drifted back to the wide flat U');
  });

  test('icon pose paints the voice-live halo outside the sphere', () async {
    final px = await renderPose(IconRenderPose.t);
    const n = 256; // == canvasSize
    const r = orbSize / 2; // 92.08: sphere radius
    var faint = 0;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final dx = x + 0.5 - n / 2, dy = y + 0.5 - n / 2;
        if (dx * dx + dy * dy <= (r + 1) * (r + 1)) continue;
        final a = px[(y * n + x) * 4 + 3];
        if (a >= 1 && a <= 200) faint++;
      }
    }
    // Measured ~35k; the resting/glowless render scores 0.
    expect(faint, greaterThan(5000),
        reason: 'no halo outside the sphere: voice-live glow is not painted');
  });
}
