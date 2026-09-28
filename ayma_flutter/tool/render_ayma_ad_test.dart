import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;

import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_rail_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offline frame renderer for the 15-second Ayma motion-graphics ad —
/// 450 deterministic 1080×1920 PNG frames at 30fps, choreographed entirely
/// from the real brand system: [AymaOrbPainter] (every state, amplitude,
/// the voice-live "angelic" connected glow), [AymaColors] dark theme tokens,
/// the app's chat-bubble geometry (16/16/16/4 radii, solid accent + onAccent
/// ink) and the [AymaMatchGlyph] double-heart + sparkle rail painter.
///
/// Same harness pattern as the other `tool/render_*` generators (a plain
/// `test()` painting straight onto a `PictureRecorder` canvas — no widget
/// tree, no vsync, every frame a pure function of its timestamp). Fonts are
/// loaded like `render_public_profile_report_test.dart` does: the bundled
/// Geist faces for real, and the serif/mono display roles from
/// `build/ad_fonts/` when the real Instrument Serif / JetBrains Mono files
/// are staged there, falling back to system stand-ins so the test stays
/// green on a bare machine.
///
/// Not part of the regular suite (tool/ isn't scanned). Run explicitly:
///
///   flutter test tool/render_ayma_ad_test.dart
///
/// Modes via environment variables (plain env, not dart-defines, so chunked
/// renders don't recompile):
///   AYMA_AD_MODE=full   render frames [AYMA_AD_START..AYMA_AD_END] (default
///                       0..449) every AYMA_AD_STEP-th (default 1) to
///                       build/ayma_ad_frames/frame_%03d.png
///   AYMA_AD_MODE=beats  render the key-beat stills to build/ayma_ad_beats/
///   (unset)             quick verification: a handful of spot frames plus a
///                       determinism check (same frame rendered twice must be
///                       byte-identical)
///
/// Choreography (30fps, 450 frames):
///   0.0–2.0s   black; an accent point blooms and breathes; the orb
///              materialises out of it (easeOutBack scale from 0.2, alpha +
///              glow ramp, thinking-state swirl already circulating).
///   2.0–5.0s   state montage — listening pulse with a rising voice-cadence
///              amplitude (attack/decay bursts, not a sine), then speaking
///              with high-amplitude petal flutter.
///   5.0–8.5s   kinetic type beside a smaller orb: mono eyebrow MEET AYMA,
///              then "She listens." / "She remembers." / "She finds your
///              person." — word-staggered easeOutCubic reveals, clean exits;
///              the orb flips listening → thinking → speaking as lines land.
///   8.5–11.0s  product motifs: two chat bubbles (real app geometry) pop in
///              with spring overshoot, then the Match double-heart + sparkle
///              draws on as an outline sweep and fills with the luminous
///              overlap.
///   11.0–13.0s crescendo — orb large and speaking with voiceLive true, the
///              full connected-glow bloom swelling on a dense cadence, the
///              faintest accent vignette warming the background.
///   13.0–15.0s resolve — orb settles to calm idle above the serif "Ayma"
///              wordmark and the tagline "Your heart, understood."; every
///              parameter is frozen from frame 440 so the final 10 frames
///              are pixel-identical.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const width = 1080.0;
  const height = 1920.0;
  const fps = 30;
  const totalFrames = 450;

  // Every animated quantity below reads this clamped clock, so frames
  // 440..449 all sample the exact same instant — "perfectly still" by
  // construction, not by hoping nothing drifts.
  const freezeTime = 440 / fps;

  // --------------------------------------------------------------------
  // Fonts
  // --------------------------------------------------------------------

  Future<void> loadFont(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  String pick(List<String> candidates) => candidates
      .firstWhere((p) => File(p).existsSync(), orElse: () => candidates.last);

  Future<void> loadAllFonts() async {
    // The real bundled Geist family, all three shipped weights.
    await loadFont('Geist', [
      'assets/fonts/Geist-Light.ttf',
      'assets/fonts/Geist-Regular.ttf',
      'assets/fonts/Geist-SemiBold.ttf',
    ]);
    // Display serif (Instrument Serif — the app's `AymaType.serif` face,
    // normally fetched by google_fonts at runtime) and the mono eyebrow
    // (JetBrains Mono). Staged real files win; system faces keep the test
    // green anywhere.
    await loadFont('AdSerif', [
      pick([
        'build/ad_fonts/InstrumentSerif-Regular.ttf',
        '/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf',
      ]),
    ]);
    await loadFont('AdMono', [
      pick([
        'build/ad_fonts/JetBrainsMono-Medium.ttf',
        '/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf',
      ]),
    ]);
  }

  // --------------------------------------------------------------------
  // Easing
  // --------------------------------------------------------------------

  double clamp01(double x) => x.clamp(0.0, 1.0);

  /// 0..1 progress of [t] through [a]..[b].
  double seg(double t, double a, double b) =>
      b <= a ? (t < a ? 0 : 1) : clamp01((t - a) / (b - a));

  double easeOutCubic(double x) => 1 - math.pow(1 - x, 3).toDouble();
  double easeInCubic(double x) => x * x * x;
  double easeInOutCubic(double x) => x < 0.5
      ? 4 * x * x * x
      : 1 - math.pow(-2 * x + 2, 3).toDouble() / 2;
  double easeOutBack(double x) {
    const c1 = 1.70158, c3 = c1 + 1;
    final u = x - 1;
    return 1 + c3 * u * u * u + c1 * u * u;
  }

  /// Spring overshoot for the bubble pops — livelier than easeOutBack.
  double springPop(double x) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    return 1 - math.exp(-6.5 * x) * math.cos(11 * x);
  }

  // --------------------------------------------------------------------
  // Orb state timeline (mirrors the widget: 380ms transition, easeOutCubic)
  // --------------------------------------------------------------------

  const stateTimeline = <(double, AymaOrbState)>[
    (0.0, AymaOrbState.thinking), // materialise with the thinking swirl
    (2.0, AymaOrbState.listening),
    (3.3, AymaOrbState.speaking),
    (5.0, AymaOrbState.listening), // "She listens."
    (6.35, AymaOrbState.thinking), // "She remembers."
    (7.55, AymaOrbState.speaking), // "She finds your person."
    (8.7, AymaOrbState.done), // settle behind the product motifs
    (9.85, AymaOrbState.thinking), // watching the match hearts draw on
    (11.0, AymaOrbState.speaking), // crescendo
    (13.0, AymaOrbState.done),
    (13.6, AymaOrbState.idle), // final rest
  ];

  (AymaOrbState, AymaOrbState, double) stateAt(double t) {
    var idx = 0;
    for (var i = 0; i < stateTimeline.length; i++) {
      if (stateTimeline[i].$1 <= t) idx = i;
    }
    final to = stateTimeline[idx].$2;
    final from = idx == 0 ? to : stateTimeline[idx - 1].$2;
    final transT = seg(t, stateTimeline[idx].$1, stateTimeline[idx].$1 + 0.38);
    return (from, to, transT);
  }

  // --------------------------------------------------------------------
  // Amplitude — a voice cadence: sharp attacks, exponential decays.
  // --------------------------------------------------------------------

  const bursts = <(double, double)>[
    // listening, waves rising (2.0–3.3)
    (2.15, 0.30), (2.50, 0.45), (2.80, 0.55), (3.05, 0.70),
    // speaking, lively syllable clusters (3.3–5.0)
    (3.35, 0.95), (3.52, 0.65), (3.72, 0.90), (3.95, 0.55),
    (4.12, 0.85), (4.30, 0.60), (4.55, 0.95), (4.78, 0.70),
    // kinetic-type reactions as each line lands
    (5.20, 0.50), (5.45, 0.35), (6.45, 0.40), (6.70, 0.30),
    (7.65, 0.80), (7.90, 0.55), (8.15, 0.65),
    // crescendo cadence (11.0–13.0)
    (11.05, 0.90), (11.30, 0.70), (11.50, 0.95), (11.75, 0.60),
    (11.95, 0.90), (12.15, 0.75), (12.40, 1.00), (12.60, 0.80),
    (12.80, 0.55),
  ];

  double ampAt(double t) {
    var a = 0.0;
    for (final (b, s) in bursts) {
      final dt = t - b;
      if (dt < 0 || dt > 2.0) continue;
      final attack = dt < 0.07 ? dt / 0.07 : 1.0;
      final decay = dt < 0.07 ? 1.0 : math.exp(-(dt - 0.07) / 0.30);
      a += s * attack * decay;
    }
    // Crescendo swell under the bursts, gone again by the resolve.
    a += 0.35 * seg(t, 11.0, 12.6) * (1 - easeInOutCubic(seg(t, 12.9, 13.4)));
    return clamp01(a);
  }

  // --------------------------------------------------------------------
  // Orb layout — piecewise (x, y, diameter) keyframes, easeInOutCubic.
  // --------------------------------------------------------------------

  const layoutSegs = <(double, double, Offset, double, Offset, double)>[
    // (t0, t1, fromCenter, fromSize, toCenter, toSize)
    (4.85, 5.25, Offset(540, 880), 560, Offset(540, 540), 300),
    (8.55, 8.95, Offset(540, 540), 300, Offset(540, 330), 210),
    (10.95, 11.60, Offset(540, 330), 210, Offset(540, 880), 630),
    (12.95, 13.75, Offset(540, 880), 630, Offset(540, 650), 310),
  ];

  (Offset, double) orbLayoutAt(double t) {
    var center = const Offset(540, 880);
    var size = 560.0;
    for (final (t0, t1, c0, s0, c1, s1) in layoutSegs) {
      if (t <= t0) break;
      final u = easeInOutCubic(seg(t, t0, t1));
      center = Offset.lerp(c0, c1, u)!;
      size = s0 + (s1 - s0) * u;
    }
    return (center, size);
  }

  // --------------------------------------------------------------------
  // Text helpers
  // --------------------------------------------------------------------

  final tpCache = <String, TextPainter>{};
  TextPainter tp(String text, TextStyle style) {
    final key =
        '${style.fontFamily}|${style.fontSize}|${style.letterSpacing}|'
        '${style.fontWeight}|${style.color?.toARGB32()}|$text';
    return tpCache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout(),
    );
  }

  const serifLine = TextStyle(
      fontFamily: 'AdSerif',
      fontSize: 92,
      color: AymaColors.darkFg,
      height: 1.1);
  const eyebrowStyle = TextStyle(
      fontFamily: 'AdMono',
      fontSize: 27,
      letterSpacing: 7,
      color: AymaColors.accent);
  const wordmarkStyle = TextStyle(
      fontFamily: 'AdSerif',
      fontSize: 172,
      color: AymaColors.darkFg,
      height: 1.05);
  const taglineStyle = TextStyle(
      fontFamily: 'Geist',
      fontSize: 36,
      fontWeight: FontWeight.w300,
      letterSpacing: 0.6,
      color: AymaColors.darkFgDim);
  const bubbleStyle = TextStyle(
      fontFamily: 'Geist',
      fontSize: 36,
      color: AymaColors.onAccent,
      height: 1.4);

  /// One kinetic serif line: word-staggered easeOutCubic slide-up reveal,
  /// clean easeInCubic rise-and-fade exit. Words are positioned by prefix
  /// layout widths so inter-word metrics match a single-run layout exactly.
  void paintKineticLine(Canvas canvas, String line, double centerY, double t,
      double inStart, double outStart) {
    const inDur = 0.42, stagger = 0.10, outDur = 0.28;
    if (t < inStart || t > outStart + outDur) return;
    final words = line.split(' ');
    final full = tp(line, serifLine);
    final x0 = (width - full.width) / 2;
    final top = centerY - full.height / 2;
    final out = easeInCubic(seg(t, outStart, outStart + outDur));
    for (var i = 0; i < words.length; i++) {
      final prefix = words.sublist(0, i).map((w) => '$w ').join();
      final dx = prefix.isEmpty ? 0.0 : tp(prefix, serifLine).width;
      final inU = easeOutCubic(seg(t, inStart + i * stagger,
          inStart + i * stagger + inDur));
      final alpha = clamp01(inU * (1 - out));
      if (alpha <= 0.001) continue;
      final dy = (1 - inU) * 46 - out * 38;
      final wp = tp(words[i], serifLine);
      canvas.saveLayer(
          null, Paint()..color = Colors.white.withValues(alpha: alpha));
      wp.paint(canvas, Offset(x0 + dx, top + dy));
      canvas.restore();
    }
  }

  /// Fade + rise for a single text block (eyebrow, wordmark, tagline).
  void paintReveal(Canvas canvas, TextPainter painter, Offset topCenter,
      double inU, double outU) {
    final alpha = clamp01(easeOutCubic(inU) * (1 - easeInCubic(outU)));
    if (alpha <= 0.001) return;
    final dy = (1 - easeOutCubic(inU)) * 30 - easeInCubic(outU) * 30;
    canvas.saveLayer(
        null, Paint()..color = Colors.white.withValues(alpha: alpha));
    painter.paint(
        canvas, Offset(topCenter.dx - painter.width / 2, topCenter.dy + dy));
    canvas.restore();
  }

  // --------------------------------------------------------------------
  // Chat bubbles — the app's real "mine" bubble at 2.4× chat scale:
  // radii 16/16/16/4 (dp), solid accent fill, onAccent ink, 14/10 padding.
  // --------------------------------------------------------------------

  void paintBubble(Canvas canvas, String text, double top, double t,
      double inStart, double outStart,
      {required bool right}) {
    const k = 2.4, outDur = 0.28;
    if (t < inStart || t > outStart + outDur) return;
    final pop = springPop(seg(t, inStart, inStart + 0.55));
    final out = easeInCubic(seg(t, outStart, outStart + outDur));
    final alpha = clamp01(clamp01(pop * 2.2) * (1 - out));
    if (alpha <= 0.001) return;

    final body = tp(text, bubbleStyle);
    final w = body.width + 2 * 14 * k;
    final h = body.height + 2 * 10 * k;
    final left = right ? width - 100 - w : 100.0;
    final rect = Rect.fromLTWH(left, top, w, h);
    const r = Radius.circular(16 * k), tail = Radius.circular(4 * k);
    final rrect = RRect.fromRectAndCorners(rect,
        topLeft: r,
        topRight: r,
        bottomLeft: right ? r : tail,
        bottomRight: right ? tail : r);
    // Spring scale about the tail corner, exit sinks slightly.
    final anchor = right ? rect.bottomRight : rect.bottomLeft;
    final scale = (0.55 + 0.45 * pop) * (1 - 0.10 * out);

    canvas.saveLayer(
        null, Paint()..color = Colors.white.withValues(alpha: alpha));
    canvas.save();
    canvas.translate(anchor.dx, anchor.dy);
    canvas.scale(scale);
    canvas.translate(-anchor.dx, -anchor.dy);
    canvas.drawRRect(rrect, Paint()..color = AymaColors.accent);
    body.paint(canvas, Offset(left + 14 * k, top + 10 * k));
    canvas.restore();
    canvas.restore();
  }

  // --------------------------------------------------------------------
  // Match double-heart + sparkle (the real rail painter): outline sweeps
  // on clockwise from 12 o'clock, then the filled state (luminous overlap
  // included) cross-fades in with a gentle swell.
  // --------------------------------------------------------------------

  final matchOutline =
      AymaMatchGlyph(accent: AymaColors.accent, filled: false).buildPainter();
  final matchFilled =
      AymaMatchGlyph(accent: AymaColors.accent, filled: true).buildPainter();

  void paintMatchGlyph(Canvas canvas, Offset center, double glyphSize,
      double t, double drawStart, double fillStart, double outStart) {
    const drawDur = 0.62, fillDur = 0.42, outDur = 0.32;
    if (t < drawStart || t > outStart + outDur) return;
    final draw = easeOutCubic(seg(t, drawStart, drawStart + drawDur));
    final fill = easeInOutCubic(seg(t, fillStart, fillStart + fillDur));
    final out = easeInCubic(seg(t, outStart, outStart + outDur));
    final alpha = clamp01((draw < 1 ? 0.55 + 0.45 * draw : 1) * (1 - out));
    if (alpha <= 0.001 || draw <= 0.001) return;
    final swell = 1 + 0.045 * math.sin(math.pi * fill);
    final scale = swell * (1 - 0.12 * out);
    final half = glyphSize / 2;

    canvas.saveLayer(
        null, Paint()..color = Colors.white.withValues(alpha: alpha));
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-half, -half);
    if (draw < 1) {
      // Radial wipe: only the swept sector of the outline exists yet.
      final sweep = draw * 2 * math.pi;
      final c = Offset(half, half);
      final rBig = glyphSize * 1.2;
      canvas.save();
      canvas.clipPath(Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx, c.dy - rBig)
        ..arcTo(Rect.fromCircle(center: c, radius: rBig), -math.pi / 2, sweep,
            false)
        ..close());
      matchOutline.paint(canvas, Size(glyphSize, glyphSize));
      canvas.restore();
    } else {
      matchOutline.paint(canvas, Size(glyphSize, glyphSize));
    }
    if (fill > 0.001) {
      canvas.saveLayer(
          null, Paint()..color = Colors.white.withValues(alpha: fill));
      matchFilled.paint(canvas, Size(glyphSize, glyphSize));
      canvas.restore();
    }
    canvas.restore();
    canvas.restore();
  }

  // --------------------------------------------------------------------
  // Orb
  // --------------------------------------------------------------------

  void paintOrbOnce(Canvas canvas, double t, Offset center, double size,
      double matScale, bool voiceLive) {
    final (from, to, transT) = stateAt(t);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(matScale);
    canvas.translate(-size / 2, -size / 2);
    AymaOrbPainter(
      t: t,
      fromState: from,
      toState: to,
      transitionT: Curves.easeOutCubic.transform(transT),
      amplitude: ampAt(t),
      accent: AymaColors.accent,
      reducedMotion: false,
      showGlow: true,
      voiceLive: voiceLive,
    ).paint(canvas, Size(size, size));
    canvas.restore();
  }

  // --------------------------------------------------------------------
  // The frame
  // --------------------------------------------------------------------

  void paintFrame(Canvas canvas, int frame) {
    final t = math.min(frame / fps, freezeTime);

    // 1. Ground: true black through the opening beat, warming to the app's
    // dark background as the orb materialises.
    final bgU = easeInOutCubic(seg(t, 0.9, 1.9));
    canvas.drawRect(const Rect.fromLTWH(0, 0, width, height),
        Paint()..color = Color.lerp(Colors.black, AymaColors.darkBg, bgU)!);

    // 2. Crescendo vignette — the faintest accent warmth creeping in from
    // the edges, easing back for the resolve.
    final vig = 0.055 * seg(t, 11.0, 11.9) * (1 - 0.5 * seg(t, 13.0, 13.9));
    if (vig > 0.001) {
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, width, height),
        Paint()
          ..shader = RadialGradient(
            radius: 1.05,
            colors: [
              AymaColors.accent.withValues(alpha: 0),
              AymaColors.accent.withValues(alpha: 0),
              AymaColors.accent.withValues(alpha: vig),
            ],
            stops: const [0, 0.55, 1],
          ).createShader(Rect.fromCircle(
              center: const Offset(540, 880), radius: 1080)),
      );
    }

    // 3. Opening: a faint accent point blooms and breathes where the orb
    // will be born, handing off as the sphere scales in.
    final dotIn = easeOutCubic(seg(t, 0.15, 0.85));
    final dotOut = easeInCubic(seg(t, 0.85, 1.30));
    final dotA = clamp01(dotIn * (1 - dotOut));
    if (dotA > 0.001) {
      final breathe = 1 + 0.18 * math.sin(2 * math.pi * 0.7 * t - math.pi / 2);
      const c = Offset(540, 880);
      final rHalo = 150.0 * breathe * dotIn;
      canvas.drawCircle(
        c,
        rHalo,
        Paint()
          ..shader = RadialGradient(colors: [
            AymaColors.accent.withValues(alpha: 0.22 * dotA),
            AymaColors.accent.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: c, radius: rHalo)),
      );
      canvas.drawCircle(
          c,
          9.0 * breathe,
          Paint()
            ..color = AymaColors.orbGlowPearl.withValues(alpha: 0.95 * dotA)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }

    // 4. The orb — materialise (easeOutBack scale from 0.2 + alpha ramp),
    // then the layout keyframes; voiceLive cross-fades in for the crescendo
    // and back out for the resolve.
    final born = seg(t, 0.80, 1.87);
    final matScale = 0.2 + 0.8 * easeOutBack(born);
    final orbAlpha = easeOutCubic(seg(t, 0.80, 1.35));
    if (orbAlpha > 0.001) {
      final (center, size) = orbLayoutAt(t);
      final liveU = easeInOutCubic(seg(t, 11.0, 11.5)) *
          (1 - easeInOutCubic(seg(t, 13.0, 13.55)));
      void withAlpha(double a, void Function() body) {
        if (a <= 0.001) return;
        if (a >= 0.999) {
          body();
        } else {
          canvas.saveLayer(
              null, Paint()..color = Colors.white.withValues(alpha: a));
          body();
          canvas.restore();
        }
      }

      withAlpha(orbAlpha * (1 - liveU),
          () => paintOrbOnce(canvas, t, center, size, matScale, false));
      withAlpha(orbAlpha * liveU,
          () => paintOrbOnce(canvas, t, center, size, matScale, true));
    }

    // 5. Kinetic type (5.0–8.5s).
    paintReveal(canvas, tp('MEET AYMA', eyebrowStyle), const Offset(540, 924),
        seg(t, 5.0, 5.40), seg(t, 6.05, 6.33));
    paintKineticLine(canvas, 'She listens.', 1056, t, 5.15, 6.05);
    paintKineticLine(canvas, 'She remembers.', 1056, t, 6.35, 7.25);
    paintKineticLine(canvas, 'She finds your person.', 1056, t, 7.55, 8.46);

    // 6. Product motifs (8.5–11.0s).
    paintBubble(canvas, 'What does home feel like?', 780, t, 8.65, 9.50,
        right: false);
    paintBubble(canvas, 'Sunday mornings, no rush.', 960, t, 9.10, 9.60,
        right: true);
    paintMatchGlyph(
        canvas, const Offset(540, 1010), 400, t, 9.85, 10.55, 11.05);

    // 7. Lockup (13.5s →): serif wordmark + tagline easing up under the
    // settling orb. No exit — they are the resolve.
    paintReveal(canvas, tp('Ayma', wordmarkStyle), const Offset(540, 905),
        seg(t, 13.50, 14.05), 0);
    paintReveal(
        canvas,
        tp('Your heart, understood.', taglineStyle),
        const Offset(540, 1135),
        seg(t, 13.82, 14.35),
        0);
  }

  // --------------------------------------------------------------------
  // Rasterising
  // --------------------------------------------------------------------

  Future<Uint8List> renderFrame(int frame) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    paintFrame(canvas, frame);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width.toInt(), height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    expect(bytes, isNotNull);
    return bytes!.buffer.asUint8List();
  }

  Future<void> writeFrame(String path, int frame) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await renderFrame(frame));
  }

  final mode = Platform.environment['AYMA_AD_MODE'];

  test('render the Ayma ad', () async {
    await loadAllFonts();

    if (mode == 'full') {
      final start = int.parse(Platform.environment['AYMA_AD_START'] ?? '0');
      final end = int.parse(Platform.environment['AYMA_AD_END'] ?? '449');
      final step = int.parse(Platform.environment['AYMA_AD_STEP'] ?? '1');
      final sw = Stopwatch()..start();
      for (var f = start; f <= end && f < totalFrames; f += step) {
        await writeFrame(
            'build/ayma_ad_frames/frame_${f.toString().padLeft(3, '0')}.png',
            f);
      }
      // ignore: avoid_print
      print('Rendered frames $start..$end step $step '
          'in ${sw.elapsed.inSeconds}s -> build/ayma_ad_frames/');
      return;
    }

    if (mode == 'beats') {
      const beats = <String, int>{
        'beat_01_bloom': 20,
        'beat_02_materialise': 42,
        'beat_03_listening': 88,
        'beat_04_speaking': 132,
        'beat_05_type_listens': 165,
        'beat_06_type_remembers': 204,
        'beat_07_type_person': 240,
        'beat_08_bubbles': 288,
        'beat_09_match_draw': 310,
        'beat_10_match_filled': 327,
        'beat_11_crescendo': 366,
        'beat_12_lockup': 445,
      };
      for (final entry in beats.entries) {
        await writeFrame('build/ayma_ad_beats/${entry.key}.png', entry.value);
        // ignore: avoid_print
        print('Wrote build/ayma_ad_beats/${entry.key}.png');
      }
      return;
    }

    // Default: quick spot render + determinism proof.
    for (final f in const [0, 45, 165, 300, 366, 449]) {
      final bytes = await renderFrame(f);
      expect(bytes.length, greaterThan(1000), reason: 'frame $f');
    }
    final a = await renderFrame(366);
    final b = await renderFrame(366);
    expect(a, equals(b), reason: 'renderer must be deterministic');
    // The freeze: the last 10 frames are pixel-identical.
    final f440 = await renderFrame(440);
    final f449 = await renderFrame(449);
    expect(f449, equals(f440), reason: 'final 10 frames must be still');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
