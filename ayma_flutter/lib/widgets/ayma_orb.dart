import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme.dart';

/// What Ayma is doing — drives the orb's internal liquid motion.
///
/// `done` is a brief settle after `speaking`/`thinking` before the caller
/// hands control back to `idle`; the widget itself never auto-advances out
/// of it — that's the caller's call, same as every other transition here.
enum AymaOrbState { idle, listening, thinking, speaking, done }

/// Ayma Sol: a weightless Sunrise-coloured liquid sphere.
///
/// The outer silhouette is always a perfect circle. Two or three soft
/// internal fluid regions drift, swell and circulate inside it — driven by
/// [state] and, for `listening`/`speaking`, by [amplitude] (or the live
/// [amplitudeListenable], e.g. `VoiceSessionController.micLevel`/`aymaLevel`).
///
/// [active] + nullable [state] preserve the original spark widget's shape so
/// existing call sites (sign-in screen, nav bar) keep compiling unchanged —
/// `state` wins when given, otherwise `active` maps to listening/idle.
class AymaOrb extends StatefulWidget {
  const AymaOrb({
    super.key,
    this.size = 120,
    this.active = false,
    this.state,
    this.amplitude = 0,
    this.amplitudeListenable,
    this.showGlow = true,
    this.showListeningRings = false,
  });

  /// Diameter in logical pixels. Breakpoints per the Ayma Sol spec:
  /// tiny < 28, small < 80, medium < 160, large >= 160.
  final double size;

  /// Legacy shortcut (nav-bar tab icon): `true` -> listening, `false` -> idle.
  /// Ignored when [state] is given.
  final bool active;

  final AymaOrbState? state;

  /// 0.0 (silence) .. 1.0 (maximum intended response). Used when
  /// [amplitudeListenable] is null. Only affects `listening`/`speaking`.
  final double amplitude;

  /// Live amplitude source, e.g. `voice.micLevel` while listening or
  /// `voice.aymaLevel` while speaking. Takes priority over [amplitude].
  final ValueListenable<double>? amplitudeListenable;

  /// Outer soft glow — auto-suppressed below the medium breakpoint regardless
  /// of this flag (spec: tiny/small sizes carry no glow).
  final bool showGlow;

  /// Faint rings outside the sphere while listening — auto-suppressed below
  /// the medium breakpoint (spec: no rings at small sizes).
  final bool showListeningRings;

  @override
  State<AymaOrb> createState() => _AymaOrbState();
}

class _AymaOrbState extends State<AymaOrb> with TickerProviderStateMixin {
  // A long loop period means the sin()-driven motion never visibly restarts
  // during a normal session; same pragmatic choice the previous spark
  // painter made (120 s), just longer since more frequencies compose here.
  static const _loopSeconds = 3600.0;

  late final AnimationController _time = AnimationController(
    vsync: this,
    duration: Duration(seconds: _loopSeconds.round()),
  );

  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..value = 1;

  AymaOrbState _fromState = AymaOrbState.idle;
  AymaOrbState _toState = AymaOrbState.idle;
  double _smoothedAmp = 0;

  bool get _reducedMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  AymaOrbState get _effectiveState =>
      widget.state ?? (widget.active ? AymaOrbState.listening : AymaOrbState.idle);

  @override
  void initState() {
    super.initState();
    _toState = _effectiveState;
    _fromState = _toState;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(AymaOrb old) {
    super.didUpdateWidget(old);
    final next = _effectiveState;
    if (next != _toState) {
      _fromState = _toState;
      _toState = next;
      if (_reducedMotion) {
        _transition.value = 1;
      } else {
        _transition
          ..value = 0
          ..forward();
      }
    }
    _syncMotion();
  }

  void _syncMotion() {
    if (_reducedMotion) {
      if (_time.isAnimating) _time.stop();
    } else {
      if (!_time.isAnimating) _time.repeat();
    }
  }

  @override
  void dispose() {
    _time.dispose();
    _transition.dispose();
    super.dispose();
  }

  double _rawAmplitude() =>
      (widget.amplitudeListenable?.value ?? widget.amplitude).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final reduced = _reducedMotion;
    final listenable = widget.amplitudeListenable;
    final merged = Listenable.merge([
      _time,
      _transition,
      if (listenable != null) listenable,
    ]);
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: merged,
          builder: (context, _) {
            // Smoothed once here (spec formula) — decoupled from whatever
            // smoothing the audio pipeline itself already applies upstream.
            final target = _rawAmplitude();
            _smoothedAmp = _smoothedAmp * 0.82 + target * 0.18;
            return CustomPaint(
              painter: AymaOrbPainter(
                t: reduced ? 0 : _time.value * _loopSeconds,
                fromState: _fromState,
                toState: _toState,
                transitionT: Curves.easeOutCubic.transform(_transition.value),
                amplitude: _smoothedAmp,
                accent: ac.accent,
                reducedMotion: reduced,
                showGlow: widget.showGlow,
                showListeningRings: widget.showListeningRings,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Per-state motion/appearance targets, blended by [AymaOrbPainter] across a
/// state change. Field-by-field lerp, not a single global "intensity" knob —
/// each axis (idle drift, voice reactivity, thinking circulation, highlight
/// brightness, ring opacity) moves independently.
class _StateParams {
  const _StateParams({
    required this.idleAmount,
    required this.voiceAmount,
    required this.circulation,
    required this.speed,
    required this.brightness,
    required this.ringOpacity,
  });

  /// Fractional blob-radius wobble from the slow idle sine drift.
  final double idleAmount;

  /// How strongly smoothed amplitude pushes blob radius/scale.
  final double voiceAmount;

  /// Extra slow rotational drift of blob centers ("circulating liquid").
  final double circulation;

  /// Multiplier on the base animation speed.
  final double speed;

  /// 0..1 lightening of blob colors + highlight strength.
  final double brightness;

  /// Opacity of the outside listening rings.
  final double ringOpacity;

  static const _byState = {
    AymaOrbState.idle: _StateParams(
      idleAmount: 0.055,
      voiceAmount: 0,
      circulation: 0.10,
      speed: 1.0,
      brightness: 0,
      ringOpacity: 0,
    ),
    AymaOrbState.listening: _StateParams(
      idleAmount: 0.045,
      voiceAmount: 0.32,
      circulation: 0.16,
      speed: 1.25,
      brightness: 0.16,
      ringOpacity: 1,
    ),
    AymaOrbState.thinking: _StateParams(
      idleAmount: 0.05,
      voiceAmount: 0,
      circulation: 1.0,
      speed: 2.05,
      brightness: 0.08,
      ringOpacity: 0,
    ),
    AymaOrbState.speaking: _StateParams(
      idleAmount: 0.04,
      voiceAmount: 0.36,
      circulation: 0.32,
      speed: 1.55,
      brightness: 0.26,
      ringOpacity: 0,
    ),
    AymaOrbState.done: _StateParams(
      idleAmount: 0.03,
      voiceAmount: 0.06,
      circulation: 0.14,
      speed: 1.0,
      brightness: 0.10,
      ringOpacity: 0,
    ),
  };

  static _StateParams of(AymaOrbState s) => _byState[s]!;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static _StateParams lerp(AymaOrbState from, AymaOrbState to, double t) {
    final a = of(from), b = of(to);
    return _StateParams(
      idleAmount: _lerp(a.idleAmount, b.idleAmount, t),
      voiceAmount: _lerp(a.voiceAmount, b.voiceAmount, t),
      circulation: _lerp(a.circulation, b.circulation, t),
      speed: _lerp(a.speed, b.speed, t),
      brightness: _lerp(a.brightness, b.brightness, t),
      ringOpacity: _lerp(a.ringOpacity, b.ringOpacity, t),
    );
  }
}

enum _Tier { tiny, small, medium, large }

_Tier _tierOf(double size) {
  if (size < 28) return _Tier.tiny;
  if (size < 80) return _Tier.small;
  if (size < 160) return _Tier.medium;
  return _Tier.large;
}

class AymaOrbPainter extends CustomPainter {
  AymaOrbPainter({
    required this.t,
    required this.fromState,
    required this.toState,
    required this.transitionT,
    required this.amplitude,
    required this.accent,
    required this.reducedMotion,
    required this.showGlow,
    required this.showListeningRings,
  });

  final double t;
  final AymaOrbState fromState;
  final AymaOrbState toState;
  final double transitionT;
  final double amplitude;
  final Color accent;
  final bool reducedMotion;
  final bool showGlow;
  final bool showListeningRings;

  static Color _tint(Color c, double amt) => Color.lerp(c, Colors.white, amt)!;
  static Color _shade(Color c, double amt) => Color.lerp(c, Colors.black, amt)!;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    if (radius <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final tier = _tierOf(size.shortestSide);
    final p = _StateParams.lerp(fromState, toState, transitionT);

    // Reduced motion: no continuous path deformation. `t` arrives as 0 from
    // the widget; use gentle, discrete brightness/scale response only.
    final ampForScale = reducedMotion ? amplitude * 0.5 : amplitude;
    final sphereScale =
        1 + (reducedMotion ? ampForScale * p.voiceAmount * 0.05 : 0.0);

    // 1. Subtle external glow (medium/large only).
    if (showGlow && (tier == _Tier.medium || tier == _Tier.large)) {
      final glowAlpha = 0.10 + p.brightness * 0.10 + amplitude * 0.06;
      final glowR = radius * (1.28 + amplitude * 0.06);
      canvas.drawCircle(
        center,
        glowR,
        Paint()
          ..shader = RadialGradient(colors: [
            accent.withValues(alpha: glowAlpha.clamp(0, 0.32)),
            accent.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: center, radius: glowR)),
      );
    }

    // Listening rings, outside the sphere (medium/large, listening only).
    if (showListeningRings &&
        p.ringOpacity > 0.01 &&
        (tier == _Tier.medium || tier == _Tier.large)) {
      for (var i = 0; i < 2; i++) {
        final wobble = reducedMotion ? 0.0 : math.sin(t * 0.9 + i * 1.7) * 0.02;
        final ringR = radius * (1.14 + i * 0.12 + amplitude * 0.06 + wobble);
        final alpha = p.ringOpacity * (0.42 - i * 0.16) * (0.55 + amplitude * 0.45);
        canvas.drawCircle(
          center,
          ringR,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = radius * 0.032
            ..color = _tint(accent, 0.2).withValues(alpha: alpha.clamp(0, 1)),
        );
      }
    }

    final circlePath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius * sphereScale));

    canvas.save();
    canvas.clipPath(circlePath);

    // 2. Sphere base — soft peach radial depth.
    canvas.drawPath(
      circlePath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.35),
          radius: 1.05,
          colors: [
            _tint(accent, 0.46 + p.brightness * 0.18),
            accent,
            _shade(accent, 0.16),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    // 3-5. Internal liquid blobs.
    final blobCount = switch (tier) {
      _Tier.tiny => 1,
      _Tier.small => 2,
      _Tier.medium => 3,
      _Tier.large => 3,
    };
    final pointsPerBlob = switch (tier) {
      _Tier.tiny => 6,
      _Tier.small => 8,
      _Tier.medium => 10,
      _Tier.large => 12,
    };
    const blobDefs = [
      // (centerAngle, centerRadius, baseRadius, phase, colorLerp, alpha)
      (0.9 * math.pi, 0.22, 0.62, 0.0, 0.30, 0.55),
      (1.75 * math.pi, 0.24, 0.58, 2.1, 0.05, 0.42),
      (0.15 * math.pi, 0.18, 0.46, 4.2, 0.55, 0.32),
    ];

    final circulation =
        reducedMotion ? p.circulation * 0.08 : p.circulation;
    final speed = reducedMotion ? p.speed * 0.15 : p.speed;
    final idleAmount = reducedMotion ? p.idleAmount * 0.25 : p.idleAmount;
    final voiceAmount = p.voiceAmount;

    for (var b = 0; b < blobCount; b++) {
      final def = blobDefs[b];
      final drift = t * 0.10 * speed + def.$4;
      final orbitAngle = def.$1 + t * circulation * 0.22 + math.sin(drift) * 0.06;
      final orbitRadius =
          def.$2 * (1 + math.sin(t * 0.07 * speed + def.$4) * 0.12);
      final blobCenter = center +
          Offset(math.cos(orbitAngle), math.sin(orbitAngle)) *
              (radius * orbitRadius);
      final blobRadius = radius *
          def.$3 *
          (1 + amplitude * voiceAmount * 0.28);

      final pts = <Offset>[];
      for (var i = 0; i < pointsPerBlob; i++) {
        final a = (i / pointsPerBlob) * math.pi * 2;
        final wobble = math.sin(
              t * 0.55 * speed + def.$4 + a * 3,
            ) *
                idleAmount +
            math.sin(t * 0.9 * speed + a * 2 - def.$4) * idleAmount * 0.5 +
            amplitude * voiceAmount * 0.22 * math.sin(a * 2 + t * 1.4);
        final r = blobRadius * (1 + wobble);
        pts.add(blobCenter + Offset(math.cos(a), math.sin(a)) * r);
      }

      canvas.drawPath(
        _smoothPathThrough(pts),
        Paint()
          ..style = PaintingStyle.fill
          ..color = _tint(accent, def.$5 + p.brightness * 0.2)
              .withValues(alpha: def.$6),
      );
    }

    // 6. Internal soft highlight — a large, very soft light patch, upper-left.
    final hlDrift = reducedMotion ? 0.0 : math.sin(t * 0.12) * 0.03;
    final hlCenter = center +
        Offset(-radius * (0.32 + hlDrift), -radius * (0.36 - hlDrift));
    canvas.drawCircle(
      hlCenter,
      radius * 0.55,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.16 + p.brightness * 0.10),
          Colors.white.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: hlCenter, radius: radius * 0.55)),
    );

    canvas.restore();

    // 7. Thin rim highlight — bright arc along the upper-left edge.
    final rimRect = Rect.fromCircle(center: center, radius: radius * 0.97);
    canvas.drawArc(
      rimRect,
      -2.55,
      1.9,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radius * 0.035)
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: -2.55,
          endAngle: -2.55 + 1.9,
          colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(rimRect),
    );

    // 8. Small crisp specular highlight (skip on tiny — "minimal detail").
    if (tier != _Tier.tiny) {
      final specCenter =
          center + Offset(-radius * 0.34, -radius * 0.4);
      canvas.drawCircle(
        specCenter,
        radius * 0.075,
        Paint()..color = Colors.white.withValues(alpha: 0.55 + p.brightness * 0.2),
      );
    }
  }

  /// Builds a smooth closed path through [pts] via the classic
  /// quadratic-through-midpoints technique: every original point becomes a
  /// Bézier control point, every curve segment's end anchor is the midpoint
  /// between consecutive points. No random sampling, fully deterministic.
  static Path _smoothPathThrough(List<Offset> pts) {
    final n = pts.length;
    Offset mid(Offset a, Offset b) => Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final path = Path()..moveTo(mid(pts[n - 1], pts[0]).dx, mid(pts[n - 1], pts[0]).dy);
    for (var i = 0; i < n; i++) {
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final m = mid(p1, p2);
      path.quadraticBezierTo(p1.dx, p1.dy, m.dx, m.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(AymaOrbPainter old) =>
      old.t != t ||
      old.fromState != fromState ||
      old.toState != toState ||
      old.transitionT != transitionT ||
      old.amplitude != amplitude ||
      old.accent != accent ||
      old.reducedMotion != reducedMotion ||
      old.showGlow != showGlow ||
      old.showListeningRings != showListeningRings;
}
