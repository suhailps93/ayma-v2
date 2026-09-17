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

/// Ayma Sol: a weightless, glossy Cherry Fuchsia sphere (the app's
/// user-configurable accent colour — see `AccentColorController` — Cherry
/// Fuchsia is only the default).
///
/// The outer silhouette is always a perfect circle. Two internal wing/petal
/// lobes meet near the bottom-center and flare outward/upward, drifting,
/// fluttering (speaking) or pulsing (listening) — driven by [state] and,
/// for `listening`/`speaking`, by [amplitude] (or the live
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
      widget.state ??
      (widget.active ? AymaOrbState.listening : AymaOrbState.idle);

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
    required this.flutterAmount,
    required this.pulseAmount,
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

  /// Weight (0..1) of the rapid, small-amplitude wing flutter — real motion
  /// only while `speaking` (§ Task 3): the two wing lobes rotate slightly,
  /// out of phase with each other, louder syllables pushing a bit more.
  final double flutterAmount;

  /// Weight (0..1) of the slow, synchronised wing swell/pulse — `listening`'s
  /// deliberately different, calmer motion (§ Task 3): both lobes breathe
  /// open-and-closed together in time with the user's own mic amplitude,
  /// the contrast against speaking's rapid asynchronous flutter being the
  /// point (see `ayma_orb.dart` doc + this batch's report for the reasoning).
  final double pulseAmount;

  static const _byState = {
    AymaOrbState.idle: _StateParams(
      idleAmount: 0.055,
      voiceAmount: 0,
      circulation: 0.10,
      speed: 1.0,
      brightness: 0,
      ringOpacity: 0,
      flutterAmount: 0,
      pulseAmount: 0,
    ),
    AymaOrbState.listening: _StateParams(
      idleAmount: 0.045,
      voiceAmount: 0.32,
      circulation: 0.16,
      speed: 1.25,
      brightness: 0.16,
      ringOpacity: 1,
      flutterAmount: 0,
      pulseAmount: 1.0,
    ),
    AymaOrbState.thinking: _StateParams(
      idleAmount: 0.05,
      voiceAmount: 0,
      circulation: 1.0,
      speed: 2.05,
      brightness: 0.08,
      ringOpacity: 0,
      flutterAmount: 0,
      pulseAmount: 0,
    ),
    AymaOrbState.speaking: _StateParams(
      idleAmount: 0.04,
      voiceAmount: 0.36,
      circulation: 0.32,
      speed: 1.55,
      brightness: 0.26,
      ringOpacity: 0,
      flutterAmount: 1.0,
      pulseAmount: 0.15,
    ),
    AymaOrbState.done: _StateParams(
      idleAmount: 0.03,
      voiceAmount: 0.06,
      circulation: 0.14,
      speed: 1.0,
      brightness: 0.10,
      ringOpacity: 0,
      flutterAmount: 0.15,
      pulseAmount: 0.1,
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
      flutterAmount: _lerp(a.flutterAmount, b.flutterAmount, t),
      pulseAmount: _lerp(a.pulseAmount, b.pulseAmount, t),
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

/// One wing/petal lobe's shape, apex-relative, in fractions of the sphere's
/// radius (+x outward from center, -y up). Two cubic Béziers: apex -> [tip]
/// via ([outer1], [outer2]), [tip] -> apex via ([inner1], [inner2]).
class _WingDef {
  const _WingDef({
    required this.outer1,
    required this.outer2,
    required this.tip,
    required this.inner1,
    required this.inner2,
  });

  final Offset outer1;
  final Offset outer2;
  final Offset tip;
  final Offset inner1;
  final Offset inner2;
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
    this.staticDetail = 1.0,
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

  /// Compensates for the one thing continuous motion normally sells for
  /// free: at rest, a single frozen frame of the idle blobs reads flatter
  /// than the live, always-drifting widget ever does, because persistence
  /// of vision — not any one frame's own contrast — is what makes the
  /// "living liquid" internal detail visible frame-to-frame. Defaults to
  /// 1.0 (a no-op, so every live call site is pixel-identical to before);
  /// the offline static-icon generator raises it to buy back that missing
  /// motion cue as real, held contrast — same blobs, same positions, same
  /// palette, just not washed out by relying on change-over-time that a
  /// static PNG can never have. Scales blob fill alpha and idle wobble
  /// amplitude together so the boost reads as "more of the same shape",
  /// not a different rendering.
  final double staticDetail;

  static Color _tint(Color c, double amt) => Color.lerp(c, Colors.white, amt)!;
  static Color _shade(Color c, double amt) => Color.lerp(c, Colors.black, amt)!;

  /// Fills and paints one wing lobe: [apex] is its world-space base point
  /// (where both lobes meet); [def] gives its shape in apex-relative unit
  /// space (fractions of [radius]); [angle]/[flare] apply the live
  /// flutter/pulse/idle-sway motion as a rotation + uniform scale about the
  /// apex, computed by the caller. A soft radial fill (tinted [accent],
  /// fading to transparent at the lobe's own edge) keeps the glow-not-sticker
  /// look the sphere's other internal fills already use.
  static void _paintWing({
    required Canvas canvas,
    required Offset apex,
    required double radius,
    required _WingDef def,
    required double angle,
    required double flare,
    required double tintAmount,
    required double alpha,
    required Color accent,
  }) {
    final path = _wingPath(apex, radius, def, angle, flare);
    final fillColor = _tint(accent, tintAmount.clamp(0, 1));
    // Gradient center: partway from apex to tip, in the same rotated/scaled
    // local frame the path itself was built in. A wide, high stop before the
    // fade starts keeps the lobe reading as a solid, saturated petal with a
    // softened edge, rather than hazing out across its whole area.
    final centroid = _wingLocalToWorld(
      apex,
      radius,
      def.tip * 0.48,
      angle,
      flare,
    );
    canvas.drawPath(
      path,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                fillColor.withValues(alpha: alpha),
                fillColor.withValues(alpha: alpha * 0.88),
                fillColor.withValues(alpha: alpha * 0.55),
              ],
              stops: const [0, 0.6, 1],
            ).createShader(
              Rect.fromCircle(center: centroid, radius: radius * 0.95 * flare),
            ),
    );
  }

  /// Maps a point in a wing's apex-relative unit space (fractions of
  /// [radius], +x outward, -y up) to world space, applying the same
  /// rotation-about-apex + uniform-scale transform [_wingPath] uses.
  static Offset _wingLocalToWorld(
    Offset apex,
    double radius,
    Offset local,
    double angle,
    double flare,
  ) {
    final scaled = local * flare;
    final ca = math.cos(angle), sa = math.sin(angle);
    final rx = scaled.dx * ca - scaled.dy * sa;
    final ry = scaled.dx * sa + scaled.dy * ca;
    return apex + Offset(rx, ry) * radius;
  }

  /// Builds one wing lobe as a closed path: apex -> outer edge (cubic) ->
  /// tip -> inner edge (cubic) -> apex. The inner edge stays close to the
  /// apex's own vertical, and the two wings' apexes are nudged toward each
  /// other by the caller, so the pair reads as overlapping near the meeting
  /// point — this app's established curve-drawing approach (`Path` +
  /// cubic/quadratic Béziers).
  static Path _wingPath(
    Offset apex,
    double radius,
    _WingDef def,
    double angle,
    double flare,
  ) {
    Offset xf(Offset local) =>
        _wingLocalToWorld(apex, radius, local, angle, flare);
    final o1 = xf(def.outer1);
    final o2 = xf(def.outer2);
    final tip = xf(def.tip);
    final i1 = xf(def.inner1);
    final i2 = xf(def.inner2);
    return Path()
      ..moveTo(apex.dx, apex.dy)
      ..cubicTo(o1.dx, o1.dy, o2.dx, o2.dy, tip.dx, tip.dy)
      ..cubicTo(i1.dx, i1.dy, i2.dx, i2.dy, apex.dx, apex.dy)
      ..close();
  }

  // Hand-tuned independently rather than mirrored, per the reference logo's
  // natural asymmetry: the right lobe reads slightly larger/bolder (longer
  // tip, wider bulge) than the left, not a stamped mirror copy. Each lobe's
  // outer/inner control points bulge to opposite sides of the apex-to-tip
  // axis by a real fraction of its length (not near-collinear with it) so
  // the lobe reads as a full teardrop/petal rather than a thin sliver; the
  // inner edge's second control point crosses just past the vertical
  // centerline, which is what makes the two lobes visibly overlap.
  static const _rightWing = _WingDef(
    outer1: Offset(0.62, 0.02),
    outer2: Offset(0.94, -0.63),
    tip: Offset(0.77, -1.02),
    inner1: Offset(0.60, -1.41),
    inner2: Offset(-0.50, -0.20),
  );
  static const _leftWing = _WingDef(
    outer1: Offset(-0.61, -0.02),
    outer2: Offset(-0.96, -0.66),
    tip: Offset(-0.78, -0.96),
    inner1: Offset(-0.60, -1.26),
    inner2: Offset(0.48, -0.20),
  );

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
          ..shader = RadialGradient(
            colors: [
              accent.withValues(alpha: glowAlpha.clamp(0, 0.32)),
              accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: glowR)),
      );
    }

    // Listening rings, outside the sphere (medium/large, listening only).
    if (showListeningRings &&
        p.ringOpacity > 0.01 &&
        (tier == _Tier.medium || tier == _Tier.large)) {
      for (var i = 0; i < 2; i++) {
        final wobble = reducedMotion ? 0.0 : math.sin(t * 0.9 + i * 1.7) * 0.02;
        final ringR = radius * (1.14 + i * 0.12 + amplitude * 0.06 + wobble);
        final alpha =
            p.ringOpacity * (0.42 - i * 0.16) * (0.55 + amplitude * 0.45);
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

    // 2. Sphere base — soft peach radial depth. Four graduated stops instead
    // of the old three: a softer core-to-mid transition reads as glass depth
    // rather than a flat two-tone "beach ball" fill.
    canvas.drawPath(
      circlePath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.35),
          radius: 0.8,
          colors: [
            _tint(accent, 0.54 + p.brightness * 0.18),
            _tint(accent, 0.22 + p.brightness * 0.10),
            accent,
            _shade(accent, 0.32),
          ],
          stops: const [0, 0.30, 0.64, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    // 2b. Soft shadow crescent, opposite the key light (lower-right) — gives
    // the sphere a sense of turning away from the light source, the way a
    // glass/liquid orb would, instead of reading as uniformly flat-lit.
    final shadowCenter = center + Offset(radius * 0.42, radius * 0.46);
    canvas.drawCircle(
      shadowCenter,
      radius * 0.8,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                _shade(accent, 0.32).withValues(alpha: 0.16),
                _shade(accent, 0.32).withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(center: shadowCenter, radius: radius * 0.8),
            ),
    );

    // 3-5. Internal wing/petal lobes (Cherry Fuchsia mark, replacing the old
    // amorphous liquid blobs): two lighter-pink teardrop lobes meeting at a
    // point near the sphere's bottom-center and flaring outward/upward,
    // overlapping near the top — see `_rightWing`/`_leftWing`/`_wingPath`.
    final circulation = reducedMotion ? p.circulation * 0.08 : p.circulation;
    final speed = reducedMotion ? p.speed * 0.15 : p.speed;
    final idleAmount =
        (reducedMotion ? p.idleAmount * 0.25 : p.idleAmount) * staticDetail;
    final voiceAmount = p.voiceAmount;

    // Small/tiny sizes simplify the flutter/pulse detail the same way the
    // old painter thinned blob point-counts down at small tiers — the wing
    // shapes themselves stay the same two lobes at every size (they're
    // already simple enough to read), only the *motion* amplitude backs off.
    final tierMotion = switch (tier) {
      _Tier.tiny => 0.35,
      _Tier.small => 0.65,
      _Tier.medium => 1.0,
      _Tier.large => 1.0,
    };
    final motionScale = (reducedMotion ? 0.12 : 1.0) * tierMotion;

    // Baseline idle sway/breathe — same spirit as the old blobs' slow drift
    // and thinking's fast circulation, carried into the wings: a gentle
    // rotational sway (more pronounced when `circulation` is high, e.g.
    // thinking's internal churn) plus a very slight scale breathe. Present
    // at low weight in every state, not just idle.
    final idleSway =
        math.sin(t * 0.10 * speed) * (0.05 + circulation * 0.05) * staticDetail;
    final idleFlare = 1 + math.sin(t * 0.14 * speed + 1.1) * idleAmount * 0.6;

    // Speaking: rapid, small-amplitude alternating flutter — rotation,
    // slightly out of phase between the two wings so they don't move as one
    // rigid unit, like real butterfly wings. Louder syllables (higher
    // `amplitude`) push a bit more flutter.
    final flutterBase =
        (0.09 + amplitude * 0.16) * p.flutterAmount * motionScale;
    final rightFlutter = math.sin(t * 9.5 * speed) * flutterBase;
    final leftFlutter =
        math.sin(t * 9.5 * speed + math.pi * 0.62) * flutterBase * 0.9;

    // Listening: slow, synchronised swell/pulse — both lobes breathe
    // open-and-closed together, in time with the user's own mic amplitude —
    // a calmer, larger-amplitude motion deliberately contrasted against
    // speaking's rapid asynchronous flutter (design call, see report).
    final pulseFlare =
        1 +
        math.sin(t * 1.3 * speed) *
            (0.07 + amplitude * 0.18) *
            p.pulseAmount *
            motionScale;

    final voiceFlare = 1 + amplitude * voiceAmount * 0.06;
    final rightAngle = idleSway + rightFlutter;
    final leftAngle = -idleSway * 0.9 + leftFlutter;
    final rightFlare = idleFlare * pulseFlare * voiceFlare;
    final leftFlare = idleFlare * pulseFlare * voiceFlare;

    // Apex — near the sphere's bottom-center, each wing's own apex nudged a
    // touch toward the *other* side so the two lobes' bases interpenetrate,
    // reading as overlapping right at the meeting point (reference logo).
    final apexY = center.dy + radius * 0.70;
    final rightApex = Offset(center.dx - radius * 0.045, apexY);
    final leftApex = Offset(center.dx + radius * 0.045, apexY);

    _paintWing(
      canvas: canvas,
      apex: rightApex,
      radius: radius,
      def: _rightWing,
      angle: rightAngle,
      flare: rightFlare,
      tintAmount: 0.53 + p.brightness * 0.15,
      alpha: (0.88 * staticDetail).clamp(0, 1),
      accent: accent,
    );
    _paintWing(
      canvas: canvas,
      apex: leftApex,
      radius: radius,
      def: _leftWing,
      angle: leftAngle,
      flare: leftFlare,
      tintAmount: 0.47 + p.brightness * 0.15,
      alpha: (0.82 * staticDetail).clamp(0, 1),
      accent: accent,
    );

    // 6. Internal soft highlight — a large, very soft light patch, upper-left.
    // Three stops (was two) so it feathers out gradually instead of fading
    // on a single linear ramp — softer, less "painted-on" glow patch.
    final hlDrift = reducedMotion ? 0.0 : math.sin(t * 0.12) * 0.03;
    final hlCenter =
        center + Offset(-radius * (0.32 + hlDrift), -radius * (0.36 - hlDrift));
    canvas.drawCircle(
      hlCenter,
      radius * 0.55,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                Colors.white.withValues(alpha: 0.20 + p.brightness * 0.10),
                Colors.white.withValues(alpha: 0.06),
                Colors.white.withValues(alpha: 0),
              ],
              stops: const [0, 0.55, 1],
            ).createShader(
              Rect.fromCircle(center: hlCenter, radius: radius * 0.55),
            ),
    );

    canvas.restore();

    // 7. Soft rim light along the upper-left edge — a gentle glow that fades
    // in and out on both ends (was a hard cutoff at the arc's start, which
    // read as a crisp cartoon rim). Blurred, lower peak alpha, so it looks
    // like ambient light catching glass rather than a painted stroke.
    final rimRect = Rect.fromCircle(center: center, radius: radius * 0.97);
    const rimStart = -2.75;
    const rimSweep = 2.1;
    canvas.drawArc(
      rimRect,
      rimStart,
      rimSweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radius * 0.03)
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.02)
        ..shader = SweepGradient(
          startAngle: rimStart,
          endAngle: rimStart + rimSweep,
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.38 + p.brightness * 0.10),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(rimRect),
    );

    // 8. Glassy specular highlight (skip on tiny — "minimal detail"): a soft
    // halo plus a small soft-edged core, replacing the old flat hard-edged
    // dot that read as a cartoon "eye glint". A faint secondary catchlight
    // below-right of the primary adds the layered-highlight depth anime-style
    // glass rendering typically uses.
    if (tier != _Tier.tiny) {
      final specCenter = center + Offset(-radius * 0.34, -radius * 0.4);
      canvas.drawCircle(
        specCenter,
        radius * 0.13,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.22 + p.brightness * 0.08),
                  Colors.white.withValues(alpha: 0),
                ],
              ).createShader(
                Rect.fromCircle(center: specCenter, radius: radius * 0.13),
              ),
      );
      canvas.drawCircle(
        specCenter,
        radius * 0.05,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.92 + p.brightness * 0.08),
                  Colors.white.withValues(alpha: 0.32),
                ],
              ).createShader(
                Rect.fromCircle(center: specCenter, radius: radius * 0.05),
              ),
      );
      final secCenter = specCenter + Offset(radius * 0.11, radius * 0.10);
      canvas.drawCircle(
        secCenter,
        radius * 0.026,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.20 + p.brightness * 0.08),
      );
    }
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
      old.showListeningRings != showListeningRings ||
      old.staticDetail != staticDetail;
}
