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
///
/// [voiceLive] is a separate, purely additive axis from [state]: `state`
/// picks the *motion* (idle sway / flutter / pulse / circulation), while
/// [voiceLive] picks the *material* — false (the default) always paints the
/// usual theme-accent glass, exactly as before this flag existed. Only flip
/// it on for an orb that is standing in for an actual, currently-live voice
/// call (connecting/waking/live on `VoiceSessionController`) — plenty of
/// call sites reuse `AymaOrbState.thinking`/`.speaking`/`.listening` for
/// unrelated things (a loading spinner, the accent-color picker's preview,
/// a voice-preset sample) and must keep rendering in the accent colour, so
/// this is never inferred from [state] alone. When true, the wings/sphere
/// switch from the flat accent tint to a cool, neutral "shiny
/// silver"/liquid-mercury metallic palette with stronger specular
/// highlights and a brighter, icier outer glow — a different material, not
/// just a lighter tint of the same hue — so a live call visibly reads as a
/// distinct, more premium state than ordinary text-mode use.
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
    this.voiceLive = false,
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

  /// True only for an orb standing in for an actively-live voice call — see
  /// the class doc. Swaps the accent material for the silver/metallic one;
  /// leaves [state]'s motion untouched.
  final bool voiceLive;

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
                voiceLive: widget.voiceLive,
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
      // A real breathe on the petals, not just the shared idle sway every
      // state already gets — reuses `listening`'s swell mechanic, but at
      // `thinking`'s own faster `speed`, so it reads as a quicker, more
      // deliberate "working on it" pulse rather than listening's calmer
      // breathing (§ founder: loading screen needed visible petal feedback,
      // not just a static/near-static orb).
      pulseAmount: 0.9,
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
    this.voiceLive = false,
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

  /// True for an orb representing a currently-live voice call — see
  /// `AymaOrb.voiceLive`. Swaps every place this painter would otherwise
  /// derive its palette from [accent] over to the fixed silver/metallic
  /// [_silverBase]/[_silverHighlight] pair instead; nothing else about the
  /// paint (geometry, motion) changes.
  final bool voiceLive;

  /// The "shiny silver"/liquid-mercury material's base tone (from
  /// `AymaColors.orbSilverBase` — deliberately not derived from [accent] so
  /// a live call reads as a genuinely different material rather than a
  /// paler version of whatever accent colour is active). Fed through the
  /// same [_tint]/[_shade]/[_richDeepen] machinery [accent] normally goes
  /// through, so it picks up the sphere gradient/shadow/wing-tint/ring/
  /// overlap logic for free.
  static const _silverBase = AymaColors.orbSilverBase;

  /// The material's highlight tone (`AymaColors.orbSilverHighlight`) — used
  /// in place of plain white for every highlight/rim/specular pass while
  /// [voiceLive] is true, so the whole sphere reads as one consistent cool,
  /// glowing material instead of a silver body with warm-white glints.
  static const _silverHighlight = AymaColors.orbSilverHighlight;

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

  /// A richer, more saturated darkening than [_shade]: lerping straight
  /// toward black keeps HSV saturation constant (scaling every channel by
  /// the same factor doesn't change the max/min ratio), which is why the
  /// old bottom-of-sphere stop stayed a flat mid-saturation red no matter
  /// how far it was shaded. The reference logo's lower sphere reads as a
  /// much deeper, more vivid crimson-maroon (saturation climbing well past
  /// the base accent's own, not just getting darker) — pushing saturation
  /// toward 1 *and* value down, in HSV space, reproduces that "rich glass"
  /// look instead of a washed-out dark tint.
  static Color _richDeepen(Color c, double amt) {
    final hsv = HSVColor.fromColor(c);
    final sat = (hsv.saturation + (1 - hsv.saturation) * amt * 0.7).clamp(
      0.0,
      1.0,
    );
    final val = (hsv.value * (1 - amt * 0.55)).clamp(0.0, 1.0);
    return hsv.withSaturation(sat).withValue(val).toColor();
  }

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

  // Genuinely mirrored (negate x, same y), not independently hand-tuned —
  // an earlier iteration diverged the two lobes' control points by up to
  // ~11% (most of all on inner1's y, which drives the inner concave curve),
  // which read as two structurally different shapes (a rounded heart-lobe
  // vs. a thin crescent) rather than the same petal mirrored. The reference
  // logo's two petals are the same curve on both sides. Only tip and inner1
  // carry a ~1% nudge on the left — the "tiny optical asymmetry for
  // balance" the spec allows, nowhere near enough to change the silhouette.
  // Each lobe's outer/inner control points bulge to opposite sides of the
  // apex-to-tip axis by a real fraction of its length (not near-collinear
  // with it) so the lobe reads as a full teardrop/petal rather than a thin
  // sliver; the inner edge's second control point crosses just past the
  // vertical centerline, which is what makes the two lobes visibly overlap.
  // dx values squeezed ~7% narrower than the previous iteration (uniform
  // horizontal scale about the apex, dy untouched) so the pair lands in the
  // spec's ~65-70%-of-sphere-width envelope without changing petal height
  // or curve character.
  //
  // Vertical (dy) magnitudes scaled by ~0.76 from the prior revision — a
  // direct-image measurement against the founder's reference (not the
  // written spec) found the petal lobes' rounded tops sit around 35-40%
  // down the sphere with a clear plain-sphere band above them, whereas the
  // previous curve's raw control points put the visible silhouette as high
  // as 5-25% down, overlapping the highlight. Shrinking dy (not dx) pulls
  // the whole lobe down toward the apex without changing its width or
  // outward flare — "bring the root of petals more to the bottom" (founder,
  // rev. 2) combined with nudging the apex itself down (0.52 -> 0.56, see
  // below) is what actually moves the visible mass, since the previous
  // revision's apex was already close to the reference's.
  //
  // outer1/outer2/tip dx widened ~8% (inner1/inner2 dx, the concave inner
  // edge near the meeting point, left alone) — pixel-measuring how close the
  // reference's petal silhouette gets to the sphere's own rim (sustained
  // petal-color runs, not isolated rim-light pixels) found it reaching
  // ~97% of the way out vs. this shape's ~86% before this nudge; widening
  // only the outer control points/tip stretches the lobe's outward flare
  // toward the rim without touching the inner crossover shape.
  static const _rightWing = _WingDef(
    outer1: Offset(0.626, 0.015),
    outer2: Offset(0.940, -0.479),
    tip: Offset(0.778, -0.775),
    inner1: Offset(0.56, -1.072),
    inner2: Offset(-0.47, -0.152),
  );
  static const _leftWing = _WingDef(
    outer1: Offset(-0.626, 0.015),
    outer2: Offset(-0.940, -0.479),
    tip: Offset(-0.772, -0.768),
    inner1: Offset(-0.555, -1.064),
    inner2: Offset(0.47, -0.152),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    if (radius <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final tier = _tierOf(size.shortestSide);
    final p = _StateParams.lerp(fromState, toState, transitionT);

    // The material this frame paints with: the usual theme accent, or —
    // only while [voiceLive] — the fixed silver/metallic tone. Every gradient
    // below that used to reference [accent] directly now goes through this
    // instead, so the whole sphere (base fill, shadow, wing fills, overlap
    // shading, rings, glow) shifts together as one material swap rather than
    // a patchwork of independently-tinted pieces.
    final material = voiceLive ? _silverBase : accent;
    // Highlights/rim/specular normally lerp toward pure white; while
    // [voiceLive] they lerp toward a cool near-white instead, so the whole
    // sphere reads as one consistent glowing metal rather than a silver body
    // with warm-white glints sprinkled on top.
    final highlightWhite = voiceLive ? _silverHighlight : Colors.white;
    // A genuinely live call gets a visibly stronger presence on top of the
    // material swap itself — brighter specular, a bigger/brighter bloom —
    // so it reads as "lit up", not just "a different colour".
    final liveBoost = voiceLive ? 1.0 : 0.0;

    // Small-size legibility: the petal/sphere alpha tuned for large sizes
    // reads fine at 128px+ but the petal silhouette nearly disappears by
    // 48px and is gone by 32px — downscaling (and eventual on-screen
    // anti-aliasing) eats contrast faster than it eats gradient nuance. Ramp
    // from 0 (no change) at 80px up to 1 (full boost) at 32px and below, so
    // the carefully-tuned glass look at large sizes is untouched while the
    // exact sizes the spec calls out (48px, 32px) get a real fill-opacity +
    // saturation boost instead. Simplifies gradients, not the shape.
    final legibilityT = ((80 - size.shortestSide) / 48).clamp(0.0, 1.0);

    // Reduced motion: no continuous path deformation. `t` arrives as 0 from
    // the widget; use gentle, discrete brightness/scale response only.
    final ampForScale = reducedMotion ? amplitude * 0.5 : amplitude;
    final sphereScale =
        1 + (reducedMotion ? ampForScale * p.voiceAmount * 0.05 : 0.0);

    // 1. Subtle external glow (medium/large only) — brighter, icier and
    // wider while [voiceLive], so a live call visibly *glows* rather than
    // just sitting in a different colour (founder ask: "glowing").
    if (showGlow && (tier == _Tier.medium || tier == _Tier.large)) {
      final glowAlpha =
          0.10 + p.brightness * 0.10 + amplitude * 0.06 + liveBoost * 0.10;
      final glowR = radius * (1.28 + amplitude * 0.06 + liveBoost * 0.10);
      final glowColor = voiceLive
          ? Color.lerp(_silverBase, _silverHighlight, 0.55)!
          : accent;
      canvas.drawCircle(
        center,
        glowR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              glowColor.withValues(
                  alpha: glowAlpha.clamp(0, voiceLive ? 0.46 : 0.32)),
              glowColor.withValues(alpha: 0),
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
            ..color = _tint(material, voiceLive ? 0.4 : 0.2)
                .withValues(alpha: alpha.clamp(0, 1)),
        );
      }
    }

    final circlePath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius * sphereScale));

    canvas.save();
    canvas.clipPath(circlePath);

    // 2. Sphere base — soft peach radial depth. Four graduated stops instead
    // of the old three: a softer core-to-mid transition reads as glass depth
    // rather than a flat two-tone "beach ball" fill. The upper-left core
    // brightness is toned down as size shrinks (via legibilityT) — that
    // bright core sits in the same region as the petals' own tips, and at
    // large sizes it reads as glass depth, but by 32-48px it was competing
    // directly with the boosted petal fill for contrast. A flatter, more
    // uniform sphere at small sizes is the "simplify gradients... preserve
    // silhouette" the spec calls for.
    canvas.drawPath(
      circlePath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.35),
          radius: 0.78,
          colors: [
            _tint(
              material,
              0.54 +
                  p.brightness * 0.18 -
                  legibilityT * 0.22 +
                  liveBoost * 0.10,
            ),
            _tint(material, 0.22 + p.brightness * 0.10 - legibilityT * 0.10),
            material,
            _richDeepen(material, 1.15),
          ],
          stops: const [0, 0.26, 0.48, 1],
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
                _shade(material, 0.32).withValues(alpha: 0.16),
                _shade(material, 0.32).withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(center: shadowCenter, radius: radius * 0.8),
            ),
    );

    // 2c. Subtle reflected/bounce light near the bottom perimeter — a glass
    // sphere picks up a faint warm glow from whatever it's resting near;
    // kept low-alpha so it reads as ambient bounce, not a second light
    // source, and stays part of the layered sphere shading (not a highlight).
    final bounceCenter = center + Offset(0, radius * 0.80);
    canvas.drawCircle(
      bounceCenter,
      radius * 0.4,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                _tint(material, 0.4 + p.brightness * 0.1)
                    .withValues(alpha: 0.12),
                _tint(material, 0.4).withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(center: bounceCenter, radius: radius * 0.4),
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
    // Convergence sits ~78% down the sphere and the two apexes are nudged
    // closer together than before — a tighter, narrower meeting point reads
    // more deliberate than a loose intersection. (0.52 -> 0.56: a small
    // extra nudge down from direct comparison against the founder's
    // reference image, rev. 2 — see `_rightWing`/`_leftWing` doc comment.)
    final apexY = center.dy + radius * 0.56;
    final rightApex = Offset(center.dx - radius * 0.028, apexY);
    final leftApex = Offset(center.dx + radius * 0.028, apexY);

    _paintWing(
      canvas: canvas,
      apex: rightApex,
      radius: radius,
      def: _rightWing,
      angle: rightAngle,
      flare: rightFlare,
      // Right/left fill tone+alpha used to differ by ~6-9% (0.53/0.74 vs
      // 0.47/0.68) as a deliberate "not a stamped mirror copy" choice. That
      // was a mistake once the path geometry itself is mirrored (above): a
      // gap that size makes one lobe read as bold/solid and the other as
      // faint/thin — a different-looking SHAPE, not just an optical nudge.
      // Now both wings share the same tint/alpha, only a ~2% nudge apart
      // (the "tiny optical asymmetry for balance" the spec allows). The
      // overlap region's own tonal contrast comes from the explicit 5b
      // overlay below, not from an alpha gap between the two wings, so
      // equalizing this doesn't cost that.
      //
      // Small sizes pull tintAmount down (richer/less pale, more saturated
      // against the sphere) and alpha up (more opaque) via legibilityT —
      // see its definition above. At large sizes (legibilityT=0) this is
      // exactly the frosted-glass tuning below; by 32px it's pushed to a
      // near-opaque, higher-contrast fill so the silhouette survives
      // downscaling instead of washing into the sphere.
      tintAmount:
          0.51 + p.brightness * 0.15 - legibilityT * 0.13 + liveBoost * 0.08,
      // Lower than before (was 0.88) — frosted glass, not an opaque
      // sticker: the cherry sphere underneath should visibly read through
      // the petal via real alpha compositing (spec: "Petal material").
      alpha: ((0.72 + legibilityT * 0.26) * staticDetail).clamp(0, 1),
      accent: material,
    );
    _paintWing(
      canvas: canvas,
      apex: leftApex,
      radius: radius,
      def: _leftWing,
      angle: leftAngle,
      flare: leftFlare,
      tintAmount:
          0.50 + p.brightness * 0.15 - legibilityT * 0.13 + liveBoost * 0.08,
      alpha: ((0.70 + legibilityT * 0.26) * staticDetail).clamp(0, 1),
      accent: material,
    );

    // 5b. Petal overlap tonal region — where the two translucent lobes
    // cross, plain over-compositing of two paler-than-sphere fills actually
    // trends *lighter* (each layer pushes further from the dark backdrop
    // toward its own pale tint), the opposite of real stacked glass. Two
    // sheets of tinted glass read darker/richer where they overlap, so fill
    // just the geometric intersection with a shaded, blurred-edge overlay —
    // soft enough to arise as a natural tonal shift, not a drawn boundary.
    final overlap = Path.combine(
      PathOperation.intersect,
      _wingPath(rightApex, radius, _rightWing, rightAngle, rightFlare),
      _wingPath(leftApex, radius, _leftWing, leftAngle, leftFlare),
    );
    canvas.drawPath(
      overlap,
      Paint()
        ..color = _shade(_tint(material, 0.42), 0.16).withValues(
          alpha: ((0.30 + legibilityT * 0.12) * staticDetail).clamp(0, 1),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.035),
    );

    // 6. Internal soft highlight — a large, diffused reflection across the
    // upper-left. Elongated (not a circle) via a canvas transform: the
    // gradient's own Rect is defined in the same pre-transform local space
    // as the circle path, so scale+rotate stretch both together into a
    // coherent ellipse rather than a distorted radial. Long axis lands
    // around a quarter of the sphere's diameter, short axis around
    // one-sixth — inside the spec's ~15-25%-of-diameter range. Three stops
    // so it feathers out gradually instead of fading on a single linear
    // ramp — softer, less "painted-on" glow patch. Sits right over the
    // petal tips, so it's faded down at small sizes (legibilityT) along
    // with the sphere's own core brightness above — one less bright wash
    // competing with the petal silhouette for contrast.
    final hlDrift = reducedMotion ? 0.0 : math.sin(t * 0.12) * 0.03;
    final hlCenter =
        center + Offset(-radius * (0.28 + hlDrift), -radius * (0.30 - hlDrift));
    final hlFade = 1 - legibilityT * 0.65;
    canvas.save();
    canvas.translate(hlCenter.dx, hlCenter.dy);
    canvas.rotate(-0.5);
    canvas.scale(1.7, 1.15);
    // Enlarged from the previous 0.17/1.55 (direct-image comparison against
    // the founder's reference, rev. 2: its glossy highlight reads as a
    // noticeably bigger, softer patch than the earlier tighter glow — see
    // `_rightWing` doc comment for the same reference-driven methodology).
    final hlR = radius * 0.24;
    canvas.drawCircle(
      Offset.zero,
      hlR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            highlightWhite.withValues(
              alpha: (0.26 + p.brightness * 0.10 + liveBoost * 0.08) * hlFade,
            ),
            highlightWhite.withValues(alpha: 0.10 * hlFade),
            highlightWhite.withValues(alpha: 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: hlR)),
    );
    canvas.restore();

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
            highlightWhite.withValues(alpha: 0.0),
            highlightWhite.withValues(
              alpha: (0.38 + p.brightness * 0.10 + liveBoost * 0.14) *
                  (1 - legibilityT * 0.4),
            ),
            highlightWhite.withValues(alpha: 0.0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(rimRect),
    );

    // 8. Glassy specular catchlight (skip on tiny, and fully faded out below
    // ~40px — "minimal detail"/legibility both point the same way at these
    // sizes): one soft-edged halo, no near-opaque core — a hard bright dot
    // reads as a sticker/cartoon "eye glint" (spec explicitly calls that
    // out), so this stays diffused all the way to its center, just brighter
    // there. A faint, equally soft secondary catchlight below-right adds
    // the layered-highlight depth glass rendering typically shows, without
    // ever hardening into its own dot.
    if (tier != _Tier.tiny && legibilityT < 1) {
      final specFade = 1 - legibilityT * 0.8;
      final specCenter = center + Offset(-radius * 0.34, -radius * 0.40);
      canvas.drawCircle(
        specCenter,
        radius * 0.15,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  highlightWhite.withValues(
                    alpha: (0.32 + p.brightness * 0.08 + liveBoost * 0.10) *
                        specFade,
                  ),
                  highlightWhite.withValues(alpha: 0.09 * specFade),
                  highlightWhite.withValues(alpha: 0),
                ],
                stops: const [0, 0.6, 1],
              ).createShader(
                Rect.fromCircle(center: specCenter, radius: radius * 0.15),
              ),
      );
      final secCenter = specCenter + Offset(radius * 0.13, radius * 0.12);
      canvas.drawCircle(
        secCenter,
        radius * 0.045,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  highlightWhite.withValues(
                    alpha: (0.16 + p.brightness * 0.06 + liveBoost * 0.08) *
                        specFade,
                  ),
                  highlightWhite.withValues(alpha: 0),
                ],
              ).createShader(
                Rect.fromCircle(center: secCenter, radius: radius * 0.045),
              ),
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
      old.staticDetail != staticDetail ||
      old.voiceLive != voiceLive;
}
