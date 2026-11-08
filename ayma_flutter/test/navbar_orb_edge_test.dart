// Navbar orb edge (founder, 2026-11-07, build 2356): "There is still a
// cherry fushia edge on the one in navbar." On his phone (terracotta
// accent, live call, Ayma speaking) the small nav-bar orb carried a hard,
// vivid cherry-red ring at its silhouette that the big voice-screen orb
// never shows: 40% of the on-device rim pixels sat at HSV saturation
// >= 0.72 while the big orb rim had none.
//
// Root cause, measured: the connected-glow rim stroke in
// AymaOrbPainter.paint (the stroke drawn at the full radius while a call
// is live) was the one compact-tier glow site that did NOT pass its
// backdrop to _glowStroke, so at nav size it painted the raw hot glow
// tone (saturation ~0.88 against the terracotta accent own 0.58) as a
// solid band. Every other compact glow site pre-blends with
// AymaColors.screenOver over the surface it lands on, which is how the
// small orb lands the same colours the big orb screen blend produces.
// These tests pin the rim ring specifically (the logo-unify test only
// measured whole-image share over a dark background, which diluted and
// filtered out exactly this fringe).
import "dart:math" as math;
import "dart:typed_data";
import "dart:ui" as ui;

import "package:ayma_flutter/theme.dart";
import "package:ayma_flutter/widgets/ayma_orb.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

const _terra = Color(0xFFE07A5F);
const _green = Color(0xFF2EAD55);
const _cherry = Color(0xFFDA4B65);

Future<ByteData> _render({
  required double size,
  required double dpr,
  required AymaOrbState state,
  required bool voiceLive,
  required double amplitude,
  required Color accent,
}) async {
  final px = (size * dpr).round();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  // The real tab bar sits on the light background; the founder screenshot
  // is a light-theme shot. (The earlier unify test rendered over darkBg,
  // which is part of why the fringe slipped past it.)
  canvas.drawRect(
    Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()),
    Paint()..color = AymaColors.lightBg,
  );
  canvas.scale(dpr);
  AymaOrbPainter(
    t: 0.3,
    fromState: state,
    toState: state,
    transitionT: 1,
    amplitude: amplitude,
    accent: accent,
    reducedMotion: false,
    showGlow: true,
    voiceLive: voiceLive,
  ).paint(canvas, Size(size, size));
  final image = await recorder.endRecording().toImage(px, px);
  return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
}

(double, double) _satVal(Color c) {
  final mx = math.max(c.r, math.max(c.g, c.b));
  final mn = math.min(c.r, math.min(c.g, c.b));
  return (mx == 0 ? 0.0 : (mx - mn) / mx, mx);
}

double _accentSat(Color accent) => _satVal(accent).$1;

/// (mean saturation, vivid share) over the rim ring (0.85R..1.0R).
/// A rim pixel is "vivid" when its saturation clears both an absolute
/// floor and a margin over the accent own saturation — i.e. a band more
/// saturated than anything the accent itself could paint, which is the
/// foreign cherry ring the founder photographed. Hue-agnostic on
/// purpose: the same raw-tone band lands at a different hue for every
/// accent (red for terracotta, blue for green), always over-saturated.
Future<(double, double)> _rim(
  WidgetTester tester, {
  required double size,
  required double dpr,
  required AymaOrbState state,
  required bool voiceLive,
  required double amplitude,
  required Color accent,
}) async {
  final data = (await tester.runAsync(
    () => _render(
      size: size,
      dpr: dpr,
      state: state,
      voiceLive: voiceLive,
      amplitude: amplitude,
      accent: accent,
    ),
  ))!;
  final px = (size * dpr).round();
  final threshold = math.max(0.72, _accentSat(accent) + 0.12);
  var n = 0;
  var vivid = 0;
  var satSum = 0.0;
  final rLogical = size / 2;
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      final i = (y * px + x) * 4;
      final c = Color.fromARGB(
        data.getUint8(i + 3),
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      );
      final dx = (x + 0.5) / dpr - size / 2;
      final dy = (y + 0.5) / dpr - size / 2;
      final dist = math.sqrt(dx * dx + dy * dy) / rLogical;
      if (dist < 0.85 || dist > 1.0) continue;
      final (s, v) = _satVal(c);
      if (v < 0.25 || s < 0.12) continue;
      n++;
      satSum += s;
      if (s >= threshold) vivid++;
    }
  }
  final meanSat = n == 0 ? 0.0 : satSum / n;
  final vividShare = n == 0 ? 0.0 : vivid / n;
  return (meanSat, vividShare);
}

void main() {
  testWidgets("nav orb rim carries no vivid foreign band in any state", (
    tester,
  ) async {
    final states = <(AymaOrbState, bool, double)>[
      (AymaOrbState.idle, false, 0),
      (AymaOrbState.thinking, false, 0),
      (AymaOrbState.listening, true, 0.35),
      (AymaOrbState.speaking, true, 0.6),
    ];
    // Terracotta is the founder accent from the report; cherry is the
    // default the glow palette was tuned on — the big orb rim carries
    // no vivid band for either, so the nav orb must not either. (Green
    // is covered by the parity test below: its band lands just under
    // the vivid threshold but still inflates the rim mean saturation.)
    for (final accent in [_terra, _cherry]) {
      for (final (state, live, amp) in states) {
        final (_, vivid) = await _rim(
          tester,
          size: 64,
          dpr: 3,
          state: state,
          voiceLive: live,
          amplitude: amp,
          accent: accent,
        );
        expect(
          vivid,
          lessThan(0.01),
          reason:
              "nav-size rim vivid share for $accent in $state "
              "(was 0.55 terracotta / 0.34 cherry while speaking, "
              "before the fix; the big orb is 0.00 for both)",
        );
      }
    }
  });

  testWidgets("nav orb rim saturation matches the big orb while speaking", (
    tester,
  ) async {
    for (final accent in [_terra, _green, _cherry]) {
      final (navMean, _) = await _rim(
        tester,
        size: 64,
        dpr: 3,
        state: AymaOrbState.speaking,
        voiceLive: true,
        amplitude: 0.6,
        accent: accent,
      );
      final (bigMean, bigVivid) = await _rim(
        tester,
        size: 220,
        dpr: 2,
        state: AymaOrbState.speaking,
        voiceLive: true,
        amplitude: 0.6,
        accent: accent,
      );
      // The big voice orb is the design reference and must stay clean.
      expect(
        bigVivid,
        lessThan(0.01),
        reason: "big orb rim stays clean for $accent",
      );
      expect(
        navMean,
        lessThan(bigMean + 0.08),
        reason:
            "nav rim mean saturation $navMean should sit next to the "
            "big orb $bigMean for $accent (gaps were 0.09-0.14 before "
            "the fix, 0.05-0.06 after it)",
      );
    }
  });
}
