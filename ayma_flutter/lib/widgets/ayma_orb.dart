import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../services/orb_animation_settings.dart';
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
/// [voiceLive] is a separate, purely additive axis from [state]: true only
/// for an orb standing in for an actual, currently-live voice call
/// (connecting/waking/live on `VoiceSessionController`) — plenty of call
/// sites reuse `AymaOrbState.thinking`/`.speaking`/`.listening` for
/// unrelated things (a loading spinner, the accent-color picker's preview,
/// a voice-preset sample) and must never pick up whatever [voiceLive] would
/// otherwise gate, so this is never inferred from [state] alone. It no
/// longer swaps the sphere/wing material to a separate silver palette (an
/// earlier revision did; that treatment was retired in favour of the
/// "angelic glow" pass — see `AymaOrbPainter.voiceLive`'s own doc): it now
/// only gates that glow, which renders through the whole live call —
/// `listening`/`thinking`/`speaking` — at a per-state intensity (full at
/// `speaking`, dimmer at `listening`/`thinking`; see
/// `AymaOrbPainter._connectedGlowIntensity`), never in text mode.
class AymaOrb extends StatefulWidget {
  const AymaOrb({
    super.key,
    this.size = 120,
    this.active = false,
    this.state,
    this.amplitude = 0,
    this.amplitudeListenable,
    this.showGlow = true,
    this.voiceLive = false,
    this.navBarVariant = false,
    this.animationSettings,
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

  /// True only for an orb standing in for an actively-live voice call — see
  /// the class doc. Swaps the accent material for the silver/metallic one;
  /// leaves [state]'s motion untouched.
  final bool voiceLive;

  /// True for the nav-bar tab orbs (`AymaTabBar`) — scopes the user's
  /// "Wing flutter in nav bar" setting (see [OrbAnimationSettings]) to just
  /// them, leaving big orbs (chat header, voice call screen) animating.
  final bool navBarVariant;

  /// The animation preferences this orb obeys — injectable for tests;
  /// defaults to [orbAnimationSettingsGlobal]. When the effective flag for
  /// this placement is off, the continuous wing flutter/pulse motion stops
  /// (petals rest at the reduced-motion calm pose — see
  /// [AymaOrbPainter.wingMotion]) and, once settled, the ticker stops
  /// entirely; state transitions and the voice-live glow are untouched.
  final OrbAnimationSettings? animationSettings;

  @override
  State<AymaOrb> createState() => _AymaOrbState();
}

class _AymaOrbState extends State<AymaOrb> with TickerProviderStateMixin {
  // The continuous animation clock, in seconds. This used to be a repeating
  // 3600 s AnimationController, which notified — and therefore re-painted the
  // orb's layer — on EVERY vsync frame in EVERY state, forever. With an orb
  // in the nav bar of nearly every route, that meant a nontrivial paint
  // (gradients, blurred strokes, a Path intersection) running at the full
  // display refresh rate app-wide even when the orb was just idling — the
  // founder-reported "whole app renders slow" regression. A raw [Ticker]
  // plus [_t] below keeps the exact same clock semantics (monotonic seconds
  // since mount, so any given `t` still paints pixel-identically), but only
  // *publishes* the clock — i.e. triggers a repaint — as often as the current
  // state visually needs (see [_minPublishInterval]).
  late final Ticker _ticker = createTicker(_onTick);
  Duration _lastElapsed = Duration.zero;
  double _clockSeconds = 0;

  /// The published animation clock the painter actually sees. Only advances
  /// when at least [_minPublishInterval] has accumulated — and for a settled
  /// `idle` orb the ticker below is stopped outright ([_syncMotion]), so it
  /// never advances at all: an idle orb is painted once and then costs
  /// nothing per frame (founder call: the barely-perceptible 45-60 s idle
  /// drift isn't worth repainting for).
  final ValueNotifier<double> _t = ValueNotifier(0);

  late final AnimationController _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..value = 1;

  AymaOrbState _fromState = AymaOrbState.idle;
  AymaOrbState _toState = AymaOrbState.idle;
  double _smoothedAmp = 0;

  bool get _reducedMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  OrbAnimationSettings get _animSettings =>
      widget.animationSettings ?? orbAnimationSettingsGlobal;

  /// The user's effective "wing flutter" answer for this orb's placement —
  /// the master toggle everywhere, further scoped by the nav-bar toggle for
  /// [AymaOrb.navBarVariant] orbs. When false the painter renders the
  /// reduced-motion calm pose ([AymaOrbPainter.wingMotion]) and no longer
  /// reads the clock at all, so [_syncMotion] keeps the ticker stopped —
  /// the flag is a perf lever, not just cosmetic.
  bool get _wingMotionEnabled =>
      _animSettings.flutterEnabledFor(navBar: widget.navBarVariant);

  @override
  void initState() {
    super.initState();
    _toState = _effectiveState;
    _fromState = _toState;
    _transition.addStatusListener(_onTransitionStatus);
    _animSettings.addListener(_onAnimSettingsChanged);
  }

  AymaOrbState get _effectiveState =>
      widget.state ??
      (widget.active ? AymaOrbState.listening : AymaOrbState.idle);

  /// A settings toggle flipped (possibly from the Settings screen while this
  /// orb is visible elsewhere): repaint with the new flag and start/stop the
  /// ticker to match — live, no restart.
  void _onAnimSettingsChanged() {
    if (!mounted) return;
    setState(() {});
    _syncMotion();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(AymaOrb old) {
    super.didUpdateWidget(old);
    if (!identical(
        old.animationSettings ?? orbAnimationSettingsGlobal, _animSettings)) {
      (old.animationSettings ?? orbAnimationSettingsGlobal)
          .removeListener(_onAnimSettingsChanged);
      _animSettings.addListener(_onAnimSettingsChanged);
    }
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

  /// How much clock time must accumulate before the next repaint is
  /// published, per state — the throttle that keeps a mostly-decorative orb
  /// from re-rasterising its layer on every vsync:
  ///
  ///  * live voice states (`listening`/`speaking`) and any in-flight state
  ///    transition run at full display rate — their flutter/pulse motion is
  ///    the founder-approved liveliness and stays exactly as smooth as
  ///    before;
  ///  * `thinking`/`done` (loading spinners all over the app) cap at 30 fps —
  ///    their fastest component (the pulse swell) has a ~2.4 s period, so
  ///    30 fps is visually indistinguishable from full rate;
  ///  * `idle` (the nav-bar orb on nearly every route) is fully frozen — no
  ///    republish, and [_syncMotion] stops the ticker itself, so a settled
  ///    idle orb does zero per-frame work. Its 45-60 s drift sines were
  ///    imperceptible at a glance anyway (founder call, 2026-09-26).
  ///
  /// Frames themselves are untouched: any published `t` paints exactly what
  /// the old always-on clock painted at that same `t`.
  double get _minPublishInterval {
    if (_transition.isAnimating) return 0;
    return switch (_toState) {
      AymaOrbState.listening || AymaOrbState.speaking => 0,
      // 60fps, not 30: on the 120Hz Pixel panel a 30fps step cadence reads
      // as visible judder next to 120Hz scrolling (founder: "rendering looks
      // glitchy"); gfxinfo showed frames themselves are cheap (12ms p99), so
      // the cost of 60 is fine and still halves the old always-full-rate
      // work.
      AymaOrbState.thinking || AymaOrbState.done => 1 / 60,
      // A live call must never show a dead-frozen orb: the quiet moments
      // between exchanges flap listening<->idle, and full-freeze there reads
      // as stutter (founder screen recording, 2026-09-26: 1.6s static runs
      // between full-rate bursts). 30fps ambient drift is smooth to the eye
      // and still 2-4x cheaper than full rate. True zero-cost freeze stays
      // for the everyday nav-bar orb outside calls.
      AymaOrbState.idle => widget.voiceLive ? 1 / 60 : double.infinity,
    };
  }

  void _onTick(Duration elapsed) {
    _clockSeconds += (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    if (_clockSeconds - _t.value >= _minPublishInterval) {
      _t.value = _clockSeconds;
    }
  }

  /// Runs the ticker only while something can actually move: any non-idle
  /// state, or a state transition still animating (including one INTO idle —
  /// the ticker keeps feeding it until [_onTransitionStatus] publishes the
  /// final resting frame and stops it). A settled idle orb has no ticker at
  /// all, not just a withheld republish. With the user's wing-flutter flag
  /// off for this placement the painter never reads the clock (it's handed
  /// `t: 0`, same as reduced motion), so the ticker stays stopped in every
  /// state — transitions still animate via [_transition], which has its own
  /// vsync.
  void _syncMotion() {
    final wanted = !_reducedMotion &&
        _wingMotionEnabled &&
        (_toState != AymaOrbState.idle ||
            _transition.isAnimating ||
            widget.voiceLive);
    if (wanted && !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!wanted && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTransitionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // Publish the exact settled frame before the ticker (maybe) stops, so
      // an orb coming to rest in idle lands on its final pose rather than
      // freezing a stale mid-transition frame.
      _t.value = _clockSeconds;
      _syncMotion();
    }
  }

  @override
  void dispose() {
    _animSettings.removeListener(_onAnimSettingsChanged);
    _ticker.dispose();
    _transition.dispose();
    _t.dispose();
    super.dispose();
  }

  double _rawAmplitude() =>
      (widget.amplitudeListenable?.value ?? widget.amplitude).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final reduced = _reducedMotion;
    final wingMotion = _wingMotionEnabled;
    final listenable = widget.amplitudeListenable;
    final merged = Listenable.merge([
      _t,
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
                // With wing motion off the painter's clock-driven terms must
                // sit at the same calm rest reduced motion uses — hand it
                // the same frozen clock.
                t: reduced || !wingMotion ? 0 : _t.value,
                fromState: _fromState,
                toState: _toState,
                transitionT: Curves.easeOutCubic.transform(_transition.value),
                amplitude: _smoothedAmp,
                accent: ac.accent,
                reducedMotion: reduced,
                showGlow: widget.showGlow,
                voiceLive: widget.voiceLive,
                wingMotion: wingMotion,
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
/// brightness) moves independently.
class _StateParams {
  const _StateParams({
    required this.idleAmount,
    required this.voiceAmount,
    required this.circulation,
    required this.speed,
    required this.brightness,
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

  /// Weight (0..1) of the rapid, small-amplitude wing flutter — real motion
  /// only while `speaking` (§ Task 3): the two wing lobes rotate slightly,
  /// out of phase with each other, louder syllables pushing a bit more.
  final double flutterAmount;

  /// Weight (0..1) of the slow, synchronised wing swell/pulse — `listening`'s
  /// deliberately different, calmer motion (§ Task 3): both lobes breathe
  /// open-and-closed together (real rotation, not just scale — see
  /// `pulseOpen` in `AymaOrbPainter.paint()`, rev. 5) in time with the user's
  /// own mic amplitude, the contrast against speaking's rapid asynchronous
  /// flutter being the point (see `ayma_orb.dart` doc + this batch's report
  /// for the reasoning).
  final double pulseAmount;

  static const _byState = {
    AymaOrbState.idle: _StateParams(
      idleAmount: 0.055,
      voiceAmount: 0,
      circulation: 0.10,
      speed: 1.0,
      brightness: 0,
      flutterAmount: 0,
      pulseAmount: 0,
    ),
    AymaOrbState.listening: _StateParams(
      idleAmount: 0.045,
      voiceAmount: 0.32,
      circulation: 0.16,
      speed: 1.25,
      brightness: 0.16,
      flutterAmount: 0,
      pulseAmount: 1.0,
    ),
    AymaOrbState.thinking: _StateParams(
      idleAmount: 0.05,
      voiceAmount: 0,
      circulation: 1.0,
      speed: 2.05,
      brightness: 0.08,
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
      flutterAmount: 1.0,
      pulseAmount: 0.15,
    ),
    AymaOrbState.done: _StateParams(
      idleAmount: 0.03,
      voiceAmount: 0.06,
      circulation: 0.14,
      speed: 1.0,
      brightness: 0.10,
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

/// Voice-live glow stroke. Medium/large keep the blurred, screen-blended
/// look. Small/tiny ([compact]) get no MaskFilter blur and no
/// BlendMode.screen: on-device (Impeller) those layers dropped out at the
/// 64px nav-bar orb's bottom edge, leaving a dark banded strip. The blur is
/// replaced by a stroke widened by [blur] with alpha scaled to keep the
/// same energy, composited srcOver, so there is nothing for Impeller to drop.
Paint _glowStroke(Color c, double width, double blur, bool compact,
    {bool round = false}) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = round ? StrokeCap.round : StrokeCap.butt;
  if (!compact) {
    return paint
      ..strokeWidth = width
      ..color = c
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
      ..blendMode = BlendMode.screen;
  }
  return paint
    ..strokeWidth = width + blur
    ..color = c.withValues(alpha: c.a * width / (width + blur));
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
    this.staticDetail = 1.0,
    this.voiceLive = false,
    this.wingMotion = true,
  });

  final double t;
  final AymaOrbState fromState;
  final AymaOrbState toState;
  final double transitionT;
  final double amplitude;
  final Color accent;
  final bool reducedMotion;
  final bool showGlow;

  /// False when the user turned the continuous petal/wing flutter off for
  /// this orb's placement (Settings › Animation — see
  /// [OrbAnimationSettings]). The petals then hold the exact calm resting
  /// pose reduced motion already renders (same damped idle-drift math, and
  /// the widget hands in the same frozen `t: 0`), while everything reduced
  /// motion additionally suppresses — animated state transitions, the
  /// amplitude-substitute sphere scale — stays untouched: this flag stops
  /// the wings' continuous motion, nothing else.
  final bool wingMotion;

  /// True for an orb representing a currently-live voice call — see
  /// `AymaOrb.voiceLive`. No longer swaps the sphere/wing material to a
  /// separate silver palette (that treatment was retired in favour of the
  /// "angelic glow" pass below); it now only gates `connectedGlow` (see
  /// `paint()`) — the warm-white/pink internal petal light and sphere halo
  /// only ever render while a call is genuinely live, never for
  /// `state == speaking`/`.listening`/`.thinking` reused elsewhere (a loading
  /// spinner, an accent-picker preview, etc.).
  final bool voiceLive;

  /// How strongly `connectedGlow` (see `paint()`) renders per state — the
  /// founder's original "white-hot filament" reference is `speaking`'s full
  /// 1.0; `listening`/`thinking` reuse the exact same rendering layers at a
  /// dimmer weight (a filament glowing warm, not white-hot) so the "voice is
  /// connected" cue is present for the whole call, not just while Ayma is
  /// actually talking. Zero for every other state (never in text mode, since
  /// `connectedGlow` is separately gated on [voiceLive] too).
  static double _connectedGlowIntensity(AymaOrbState s) => switch (s) {
        AymaOrbState.speaking => 1.0,
        AymaOrbState.listening => 0.5,
        AymaOrbState.thinking => 0.32,
        _ => 0.0,
      };

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

  // Speaking-light palette (petals + speaking sphere glow) — named tokens
  // live in `AymaColors` (`color_audit_test.dart`: no literal colours
  // outside theme.dart), aliased here under their original short names so
  // every use site below is unchanged.
  static const _glowPearl = AymaColors.orbGlowPearl;
  static const _glowBlush = AymaColors.orbGlowBlush;
  static const _glowHotPink = AymaColors.orbGlowHotPink;
  static const _glowSaturate = AymaColors.orbGlowSaturate;
  static const _glowLavender = AymaColors.orbGlowLavender;
  static const _glowLavenderWhite = AymaColors.orbGlowLavenderWhite;
  static const _glowMagenta = AymaColors.orbGlowMagenta;
  static const _glowTeardrop = AymaColors.orbGlowTeardrop;
  /// Hot red-pink the sphere itself radiates while speaking (halo, rim,
  /// floor glow, lower-body light).
  static const _glowSphereHot = AymaColors.orbGlowSphereHot;

  /// Soft ceiling on how far a petal may rotate *open* (radians). The
  /// reference-fit petals reach close to the rim, so loud flutter + sway
  /// would otherwise push them past the sphere and get cut off by its clip.
  /// Closing motion is untouched.
  ///
  /// Rev. 4 (founder follow-up: "flutter like before" + "petals touching the
  /// edge"): measuring this file's own geometry found the wing's rest pose
  /// already sits at ~99-100% of the sphere radius (the doc above's "~97%"
  /// pixel estimate was optimistic) — any rotation at all pushes some part of
  /// the petal past the rim. Raising this ceiling alone (was 0.10, restoring
  /// liveliness needs it back near the old, pre-493278a file's much wider
  /// natural swing) would only make that worse, so it now pairs with
  /// [_wingInset] below: shrinking the wing's own reach first buys back the
  /// headroom this larger ceiling spends. The two together were tuned by
  /// scanning reach across a full idle-sway cycle at max mic amplitude for
  /// both `speaking`/`listening` and both large/nav-bar tiers (see the
  /// batch's report) — not just checked at rest.
  static const _maxPetalOpen = 0.16;
  static double _softOpen(double a) {
    if (a <= 0) return a;
    final e = math.exp(2 * a / _maxPetalOpen);
    return _maxPetalOpen * (e - 1) / (e + 1); // tanh
  }

  /// Rev. 4: shrinks the wings' own reach (as a fraction of the sphere
  /// radius) around the apex — NOT the apex position itself, which stays put
  /// at the sphere's own bottom-center convergence point — so the "meets at
  /// the bottom, flares up toward the rim" silhouette is unchanged at rest
  /// (still reads as reaching close to the rim, just no longer touching it),
  /// while every downstream motion (rotation via [_softOpen], scale via
  /// [_softFlareGrow]) now has real clearance to work with before it can
  /// reach the sphere's own circular clip.
  static const _wingInset = 0.90;

  /// Soft ceiling on how much the wing's flare/scale may *grow* past 1.0.
  /// [_softOpen] only ever bounded the flutter/sway *rotation* — nothing
  /// bounded `pulseFlare`/`voiceFlare`/`idleFlare`'s multiplicative growth,
  /// so `listening`'s loud-mic swell (and `thinking`'s faster reuse of the
  /// same mechanic) could scale the already rim-close wings up to ~30%
  /// larger with nothing stopping them — the single biggest source of the
  /// "petals crossing the rim" glitch, well past what the flutter-angle
  /// clamp alone could fix. Shrinking motion (< 1.0) is untouched, same
  /// asymmetry as [_softOpen].
  static const _maxFlareGrow = 0.08;
  static double _softFlareGrow(double excess) {
    if (excess <= 0) return excess;
    final e = math.exp(2 * excess / _maxFlareGrow);
    return _maxFlareGrow * (e - 1) / (e + 1); // tanh
  }

  static Color _tint(Color c, double amt) => Color.lerp(c, Colors.white, amt)!;
  static Color _shade(Color c, double amt) => Color.lerp(c, Colors.black, amt)!;

  // --- Phase-independent paint caches (perf pass, 2026-09-27) --------------
  // `paint()` used to allocate every gradient shader fresh on every frame.
  // Several of them are phase-independent: the sphere base/shadow/bounce,
  // highlight, specular, outer-glow and connected-glow gradients depend only
  // on size, palette and the (per-state constant) blend weights — never on
  // the animation clock `t` — so a fluttering or thinking orb was creating
  // and throwing away identical native shader objects at 60fps, app-wide.
  // Cache them (immutable, safely shared across frames and orb instances);
  // only the truly per-frame gradients (wing fills and the voice-live
  // internal light, whose geometry moves with `t`) stay uncached. Bounded:
  // continuously-varying inputs (a live-amplitude glow mid-speech) would
  // otherwise grow it without limit; steady state needs a handful of
  // entries, so a rare full clear beats LRU bookkeeping.
  /// Keys are records of each call site's actual independent inputs — a
  /// site tag plus every value its colors/rect are derived from (structural
  /// `==`/`hashCode`, no per-frame string building) — so a hit returns the
  /// exact shader those inputs would have created. On a hit the `create`
  /// closure (gradient construction included) never runs.
  static final Map<Object, Shader> _shaderCache = <Object, Shader>{};

  static Shader _memoShader(Object key, Shader Function() create) {
    final cached = _shaderCache[key];
    if (cached != null) return cached;
    if (_shaderCache.length >= 256) _shaderCache.clear();
    return _shaderCache[key] = create();
  }

  /// Memo for [_richDeepen] — two HSV conversions per call, three calls per
  /// frame on the hot path, always with the same (accent, amt) pairs.
  static final Map<(double, double, double, double, double), Color>
      _deepenCache = {};

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
    final key = (c.a, c.r, c.g, c.b, amt);
    final hit = _deepenCache[key];
    if (hit != null) return hit;
    if (_deepenCache.length >= 128) _deepenCache.clear();
    final hsv = HSVColor.fromColor(c);
    final sat = (hsv.saturation + (1 - hsv.saturation) * amt * 0.7).clamp(
      0.0,
      1.0,
    );
    final val = (hsv.value * (1 - amt * 0.55)).clamp(0.0, 1.0);
    return _deepenCache[key] = hsv.withSaturation(sat).withValue(val).toColor();
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
    double angelicGlow = 0.0,
    bool compact = false,
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

    // Connected-call light (voice-live only, weight varies by state — see
    // `_connectedGlowIntensity`): the petal reads as frosted glass with a
    // light source INSIDE it, the whole body glowing, brightest at the rim
    // and tips. Built from blurred low-alpha passes (mostly screen) so no
    // single layer reads as a drawn line. Every point is derived from the
    // same [def]/[angle]/[flare] transform the petal path itself uses.
    if (angelicGlow > 0.001) {
      final g = angelicGlow.clamp(0.0, 1.0);
      Offset x(Offset local) =>
          _wingLocalToWorld(apex, radius, local, angle, flare);
      Paint screenFill(Color c) => Paint()
        ..color = c
        ..blendMode = compact ? BlendMode.srcOver : BlendMode.screen;
      Paint screenStroke(Color c, double width, double blur,
              {bool round = false}) =>
          _glowStroke(c, width, blur, compact, round: round);
      Path curve(Offset a, Offset c1, Offset c2, Offset e) => Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, e.dx, e.dy);

      // Outer bloom the petal casts onto the sphere (skipped when compact:
      // it is blur-only and the saturated petal fill below covers it).
      if (!compact) {
        canvas.drawPath(
          path,
          screenFill(_glowHotPink.withValues(alpha: 0.34 * g))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.085),
        );
      }

      canvas.save();
      canvas.clipPath(path);

      // Base glass stays visible but is pushed to a saturated pink, so the
      // light layered on top reads as pink glass lit from within.
      canvas.drawPath(
        path,
        Paint()..color = _glowSaturate.withValues(alpha: 0.64 * g),
      );
      // Whole-petal emission.
      canvas.drawPath(path, screenFill(_glowBlush.withValues(alpha: 0.08 * g)));

      // Volumetric body light: pearl core -> blush -> petal material.
      final bodyC = x(def.tip * 0.52);
      final bodyR = radius * 1.0 * flare;
      canvas.drawCircle(
        bodyC,
        bodyR,
        screenFill(Colors.white)
          ..shader = RadialGradient(
            colors: [
              _glowPearl.withValues(alpha: 0.78 * g),
              _glowPearl.withValues(alpha: 0.48 * g),
              _glowBlush.withValues(alpha: 0.24 * g),
              _glowBlush.withValues(alpha: 0),
            ],
            stops: const [0, 0.35, 0.7, 1],
          ).createShader(Rect.fromCircle(center: bodyC, radius: bodyR)),
      );
      // Lavender-pink energy pooled low in the petal, near the meeting point.
      final lowC = x(const Offset(0, -0.32));
      final lowR = radius * 0.75 * flare;
      canvas.drawCircle(
        lowC,
        lowR,
        screenFill(Colors.white)
          ..shader = RadialGradient(
            colors: [
              _glowLavender.withValues(alpha: 1.0 * g),
              _glowLavender.withValues(alpha: 0.55 * g),
              _glowLavender.withValues(alpha: 0),
            ],
            stops: const [0, 0.5, 1],
          ).createShader(Rect.fromCircle(center: lowC, radius: lowR)),
      );

      // Scattering: the lit boundary bleeding inward (clipped, so only the
      // inner half of each blurred stroke lands) — white-hot rim band.
      canvas.drawPath(
        path,
        screenStroke(_glowPearl.withValues(alpha: 0.40 * g), radius * 0.14,
            radius * 0.06),
      );
      canvas.drawPath(
        path,
        screenStroke(Colors.white.withValues(alpha: 0.90 * g), radius * 0.05,
            radius * 0.015),
      );

      // Internal glass layers: partial arcs of two inset copies of the
      // outline (the reference's curved internal reflections)...
      final layerC = x(def.tip * 0.50);
      for (final (k, a) in const [(0.82, 0.55), (0.64, 0.38)]) {
        // Uniform scale by k about layerC (column-major 4x4).
        final inset = path.transform(Float64List.fromList([
          k, 0, 0, 0, //
          0, k, 0, 0, //
          0, 0, 1, 0, //
          layerC.dx * (1 - k), layerC.dy * (1 - k), 0, 1,
        ]));
        for (final metric in inset.computeMetrics()) {
          canvas.drawPath(
            metric.extractPath(metric.length * 0.08, metric.length * 0.46),
            screenStroke(Colors.white.withValues(alpha: a * g),
                radius * 0.008, radius * 0.006,
                round: true),
          );
          break; // one contour
        }
      }
      // ...and a fan of very fine, faint fibres sweeping base -> tip.
      for (var i = 0; i < 7; i++) {
        final s = -0.12 + i * 0.04;
        final e = 0.62 + i * 0.045;
        canvas.drawPath(
          curve(
            x(Offset(s, -0.12)),
            x(def.inner2 * 0.20 + Offset(s, 0)),
            x(def.inner1 * 0.40 + Offset(s * 1.4, 0)),
            x(def.tip * e),
          ),
          screenStroke(Colors.white.withValues(alpha: 0.60 * g),
              radius * 0.006, radius * 0.0045,
              round: true),
        );
      }

      // Filament: three stacked ribbons (wide halo, medium ribbon, soft
      // narrow core), each blurred by about its own width.
      final hotPath = curve(
        x(const Offset(0, -0.10)),
        x(def.inner2 * 0.24),
        x(def.inner1 * 0.43),
        x(def.tip * 0.73),
      );
      for (final (color, alpha, width, blur) in [
        (_glowBlush, 0.72, 0.27, 0.13),
        (_glowPearl, 1.0, 0.11, 0.055),
        (Colors.white, 1.0, 0.03, 0.022),
      ]) {
        canvas.drawPath(
          hotPath,
          screenStroke(color.withValues(alpha: alpha * g), radius * width,
              radius * blur,
              round: true),
        );
      }

      // Two faint secondary light streaks.
      for (final (shift, alpha) in const [(-0.07, 0.34), (0.075, 0.28)]) {
        canvas.drawPath(
          curve(
            x(Offset(shift, -0.13)),
            x(def.inner2 * 0.20 + Offset(shift, 0)),
            x(def.inner1 * 0.38 + Offset(shift, 0)),
            x(def.tip * 0.68 + Offset(shift * 0.35, 0)),
          ),
          screenStroke(Colors.white.withValues(alpha: alpha * g),
              radius * 0.012, radius * 0.016,
              round: true),
        );
      }

      // White-hot energy at the rounded outer tip.
      final tipC = x(def.tip * 0.86);
      final tipR = radius * 0.46;
      canvas.drawCircle(
        tipC,
        tipR,
        screenFill(Colors.white)
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.72 * g),
              _glowPearl.withValues(alpha: 0.34 * g),
              // Transparent BLUSH, not Colors.transparent (black): Skia
              // interpolates unpremultiplied, and white -> transparent black
              // passes through visible grey.
              _glowBlush.withValues(alpha: 0),
            ],
            stops: const [0, 0.4, 1],
          ).createShader(Rect.fromCircle(center: tipC, radius: tipR)),
      );
      canvas.restore();

      // Luminous edge: wide hot-pink bloom + pearl bloom + white-hot line.
      canvas.drawPath(
        path,
        screenStroke(_glowHotPink.withValues(alpha: 0.90 * g), radius * 0.12,
            radius * 0.06),
      );
      canvas.drawPath(
        path,
        screenStroke(_glowPearl.withValues(alpha: 0.60 * g), radius * 0.02,
            radius * 0.012),
      );
      canvas.drawPath(
        path,
        screenStroke(Colors.white.withValues(alpha: 1.0 * g),
            math.max(1.0, radius * 0.016), radius * 0.004),
      );
    }

    // Thin luminous edge: this is what gives the reference petals their
    // polished glass boundary instead of a flat translucent sticker edge.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radius * 0.010)
        ..color = Colors.white.withValues(alpha: 0.30 * alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.004),
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
  //
  // Rev. 3 (speaking-reference fit): control points re-fit to the founder's
  // state sheet, where every state shares the same flatter, wider oval petals
  // meeting in a small teardrop. Fitted by rasterising both lobes at rest
  // (angle 0, flare 1) and maximising overlap with the reference silhouette
  // (~96% IoU) and with its central teardrop (~92% IoU), then hand-nudging
  // outer1 up so the lower edges don't sit below the reference's. Still two
  // cubics per lobe, still mirrored; motion math is untouched.
  static const _rightWing = _WingDef(
    outer1: Offset(0.72, -0.05),
    outer2: Offset(0.99, -0.72),
    tip: Offset(0.89, -0.89),
    inner1: Offset(0.64, -1.30),
    inner2: Offset(-0.52, -0.05),
  );
  static const _leftWing = _WingDef(
    outer1: Offset(-0.72, -0.05),
    outer2: Offset(-0.99, -0.72),
    tip: Offset(-0.89, -0.89),
    inner1: Offset(-0.64, -1.30),
    inner2: Offset(0.52, -0.05),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    if (radius <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final tier = _tierOf(size.shortestSide);
    final compact = tier == _Tier.small || tier == _Tier.tiny;
    final p = _StateParams.lerp(fromState, toState, transitionT);

    // The material this frame paints with: the usual theme accent, or —
    // only while [voiceLive] — the fixed silver/metallic tone. Every gradient
    // below that used to reference [accent] directly now goes through this
    // instead, so the whole sphere (base fill, shadow, wing fills, overlap
    // shading, glow) shifts together as one material swap rather than
    // a patchwork of independently-tinted pieces.
    final material = accent;
    // Highlights/rim/specular normally lerp toward pure white; while
    // [voiceLive] they lerp toward a cool near-white instead, so the whole
    // sphere reads as one consistent glowing metal rather than a silver body
    // with warm-white glints sprinkled on top.
    final highlightWhite = Colors.white;
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

    // Glow only while a voice call is genuinely live (never in text mode —
    // [voiceLive] is false there) — but no longer narrowed to `speaking`
    // alone (founder follow-up: "bring the bright glow when voice is
    // connected like a filament in a bulb", for the WHOLE call, not just the
    // speaking window). Each state gets its own weight via
    // [_connectedGlowIntensity]: `speaking` keeps the founder's original
    // full "white-hot" reference intensity; `listening`/`thinking` reuse
    // every one of the same rendering layers below (petal internal light,
    // sphere halo/rim/floor glow, teardrop core) at a lower weight, which
    // reads as a warm, present filament rather than the full blaze — same
    // detail, dimmer, not a separate treatment. The existing from/to blend
    // across a state transition is preserved, just driven by each state's
    // own intensity instead of a hardcoded 0/1.
    final connectedGlow = voiceLive
        ? (_connectedGlowIntensity(fromState) * (1.0 - transitionT) +
                _connectedGlowIntensity(toState) * transitionT)
            .clamp(0.0, 1.0)
        : 0.0;

    // 1. Subtle external glow (medium/large only) — brighter, icier and
    // wider while [voiceLive], so a live call visibly *glows* rather than
    // just sitting in a different colour (founder ask: "glowing").
    if (showGlow && (tier == _Tier.medium || tier == _Tier.large)) {
      final glowAlpha =
          0.10 + p.brightness * 0.10 + amplitude * 0.06 + liveBoost * 0.10;
      final glowR = radius * (1.28 + amplitude * 0.06 + liveBoost * 0.10);
      // Always the accent: this used to switch to the silver tone while
      // [voiceLive], a leftover of the retired silver material that put a
      // grey haze around the (voice-live-only) speaking glow.
      final glowColor = accent;
      canvas.drawCircle(
        center,
        glowR,
        Paint()
          ..shader = _memoShader(
            // glowAlpha/glowR derive from brightness, amplitude and
            // voiceLive; glowColor is the accent.
            ('glow', center.dx, center.dy, radius, glowColor, p.brightness,
                amplitude, voiceLive),
            () => RadialGradient(
              colors: [
                glowColor.withValues(
                    alpha: glowAlpha.clamp(0, voiceLive ? 0.46 : 0.32)),
                glowColor.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: center, radius: glowR)),
          ),
      );

      // Connected: the whole orb radiates — a wide ambient wash, a tighter
      // hot-pink halo hugging the rim, and a floor glow underneath. Full
      // intensity at `speaking`, dimmer (but the same layers) through
      // `listening`/`thinking` — see [_connectedGlowIntensity].
      if (connectedGlow > 0.001) {
        final g = connectedGlow;
        // All three sites' colors derive only from `hot` (const) and `g`.
        Paint radial(String tag, Offset c, double r, List<Color> colors,
                List<double> stops) =>
            Paint()
              ..shader = _memoShader(
                (tag, c.dx, c.dy, r, g),
                () => RadialGradient(colors: colors, stops: stops)
                    .createShader(Rect.fromCircle(center: c, radius: r)),
              )
              ..blendMode = BlendMode.screen;
        final hot = _glowSphereHot;
        final washR = radius * 1.70;
        canvas.drawCircle(
          center,
          washR,
          radial('wash', center, washR, [
            hot.withValues(alpha: 0.30 * g),
            hot.withValues(alpha: 0.30 * g),
            hot.withValues(alpha: 0.10 * g),
            hot.withValues(alpha: 0),
          ], const [0, 0.55, 0.78, 1]),
        );
        final haloR = radius * 1.30;
        canvas.drawCircle(
          center,
          haloR,
          radial('halo', center, haloR, [
            hot.withValues(alpha: 0.40 * g),
            hot.withValues(alpha: 0.34 * g),
            hot.withValues(alpha: 0.10 * g),
            hot.withValues(alpha: 0),
          ], const [0, 0.76, 0.86, 1]),
        );
        final floorC = center + Offset(0, radius * 0.96);
        final floorRx = radius * 1.05;
        canvas.save();
        canvas.translate(floorC.dx, floorC.dy);
        canvas.scale(1, 0.26 / 1.05);
        canvas.drawCircle(
          Offset.zero,
          floorRx,
          radial('floor', Offset.zero, floorRx, [
            hot.withValues(alpha: 0.95 * g),
            hot.withValues(alpha: 0.40 * g),
            hot.withValues(alpha: 0),
          ], const [0, 0.45, 1]),
        );
        canvas.restore();
      }
    }

    // (The expanding concentric "listening rings" that used to render here —
    // outside the sphere, listening state only — were removed entirely,
    // 2026-09-26 founder ask. The petal pulse + connected glow carry the
    // listening state on their own now.)

    final circlePath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius * sphereScale));

    canvas.save();
    canvas.clipPath(circlePath);

    // 2. Sphere base — saturated glass (rev. 3, matched to the founder's state
    // sheet): the old 0.62-tint core washed the whole upper-left to a pale
    // peach; the reference sphere stays a rich accent red with only a soft
    // light area and a crisp specular. Deepens toward the rim through
    // [_richDeepen] (saturation up, value down) instead of flat black shading.
    canvas.drawPath(
      circlePath,
      Paint()
        ..shader = _memoShader(
          // Colors derive from material, brightness and legibilityT (a pure
          // function of size); rect from center/radius.
          ('base', center.dx, center.dy, radius, material, p.brightness,
              legibilityT),
          () => RadialGradient(
            center: const Alignment(-0.30, -0.36),
            radius: 0.80,
            colors: [
              _tint(
                  material, 0.16 + p.brightness * 0.10 - legibilityT * 0.10),
              _tint(material, 0.04),
              material,
              _richDeepen(material, 0.18),
              _richDeepen(material, 0.34),
            ],
            stops: const [0, 0.25, 0.55, 0.85, 1],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
        ),
    );

    // 2b. Deep crimson toward the upper-right, away from the key light.
    final deep = _richDeepen(material, 0.45);
    final shadowCenter = center + Offset(radius * 0.42, -radius * 0.40);
    canvas.drawCircle(
      shadowCenter,
      radius * 0.75,
      Paint()
        ..shader = _memoShader(
          // `deep` and shadowCenter derive from material/center/radius.
          ('shadow', center.dx, center.dy, radius, material),
          () => RadialGradient(
            colors: [
              deep.withValues(alpha: 0.70),
              deep.withValues(alpha: 0.32),
              deep.withValues(alpha: 0),
            ],
            stops: const [0, 0.5, 1],
          ).createShader(
            Rect.fromCircle(center: shadowCenter, radius: radius * 0.75),
          ),
        ),
    );

    // 2c. Light in the lower half — gentle bounce at rest; while connected
    // it turns into hot-pink light the glowing petals throw into the glass
    // (full strength speaking, dimmer listening/thinking).
    final bounceCenter = center + Offset(0, radius * 0.72);
    final bounce =
        Color.lerp(_tint(material, 0.30), _glowSphereHot, connectedGlow)!;
    canvas.drawCircle(
      bounceCenter,
      radius * 0.62,
      Paint()
        ..shader = _memoShader(
          // `bounce` derives from material and connectedGlow; bounceCenter
          // from center/radius.
          ('bounce', center.dx, center.dy, radius, material, connectedGlow),
          () => RadialGradient(
            colors: [
              bounce.withValues(alpha: 0.30 + 0.55 * connectedGlow),
              bounce.withValues(alpha: 0.12 + 0.35 * connectedGlow),
              bounce.withValues(alpha: 0),
            ],
            stops: const [0, 0.55, 1],
          ).createShader(
            Rect.fromCircle(center: bounceCenter, radius: radius * 0.62),
          ),
        )
        ..blendMode = compact ? BlendMode.srcOver : BlendMode.screen,
    );

    // 3-5. Internal wing/petal lobes (Cherry Fuchsia mark, replacing the old
    // amorphous liquid blobs): two lighter-pink teardrop lobes meeting at a
    // point near the sphere's bottom-center and flaring outward/upward,
    // overlapping near the top — see `_rightWing`/`_leftWing`/`_wingPath`.
    //
    // The wings' continuous-motion terms rest exactly the way reduced motion
    // rests them when the user's wing-flutter toggle is off ([wingMotion]) —
    // one shared calm pose, not a second nearly-identical one.
    final restingWings = reducedMotion || !wingMotion;
    final circulation = restingWings ? p.circulation * 0.08 : p.circulation;
    final speed = restingWings ? p.speed * 0.15 : p.speed;
    final idleAmount =
        (restingWings ? p.idleAmount * 0.25 : p.idleAmount) * staticDetail;
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
    final motionScale = (restingWings ? 0.12 : 1.0) * tierMotion;

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
    // `amplitude`) push a bit more flutter. Rev. 3 had cut this to base 0.06 /
    // gain 0.10 (from 0.09/0.16) specifically to fight rim clipping, but that
    // read as the flutter having gone missing entirely (founder: "I want it
    // to flutter like before"). Rev. 4 restores the original 0.09/0.16 — the
    // clipping problem that motivated Rev. 3's cut is now handled properly by
    // [_wingInset] + the wider, still-soft [_maxPetalOpen] ceiling instead of
    // by starving the motion itself.
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

    // Rev. 5 (founder follow-up: "the wings animation looks good [on
    // speaking], make it apply to both [listening and speaking]"): until now
    // the swell above only ever moved [flare] (scale), which
    // [_softFlareGrow] soft-limits to +-8% growth — far too little to read
    // as comparably lively next to speaking's real petal-opening rotation.
    // This adds an actual open-and-close ROTATION at the same slow,
    // synchronised pulse frequency (both wings open together, then close
    // together — unlike flutter's alternating/out-of-phase pair below), so
    // listening gets genuine liveliness through the same soft-limited
    // opening-angle mechanism speaking already uses. The calmer character
    // stays intentionally distinct purely from frequency (1.3x speed here vs
    // flutter's 9.5x) and phase (synchronised, not alternating) — closing the
    // "how lively does it read" gap doesn't erase that contrast.
    final pulseOpen =
        math.sin(t * 1.3 * speed) *
        (0.12 + amplitude * 0.22) *
        p.pulseAmount *
        motionScale;

    final voiceFlare = 1 + amplitude * voiceAmount * 0.06;
    // Opening rotation is soft-limited (see [_softOpen]); positive angle
    // opens the right petal, negative opens the left one. `pulseOpen` is
    // added with the same sign convention to both wings (open together,
    // close together) — see the comment above.
    final rightAngle = _softOpen(idleSway + rightFlutter + pulseOpen);
    final leftAngle =
        -_softOpen(-(-idleSway * 0.9 + leftFlutter) + pulseOpen);
    // Rev. 4: growth above 1.0 is soft-limited the same way angle is (see
    // [_softFlareGrow]) — this was the biggest single source of rim
    // clipping (listening's loud-mic swell could reach ~1.3x unclamped) and
    // is shared by both wings, same as before.
    final rawFlare = idleFlare * pulseFlare * voiceFlare;
    final flare = rawFlare >= 1
        ? 1 + _softFlareGrow(rawFlare - 1)
        : rawFlare;
    final rightFlare = flare;
    final leftFlare = flare;

    // Apex — near the sphere's bottom-center, each wing's own apex nudged a
    // touch toward the *other* side so the two lobes' bases interpenetrate,
    // reading as overlapping right at the meeting point (reference logo).
    // Convergence sits ~78% down the sphere and the two apexes are nudged
    // closer together than before — a tighter, narrower meeting point reads
    // more deliberate than a loose intersection. (0.52 -> 0.56: a small
    // extra nudge down from direct comparison against the founder's
    // reference image, rev. 2 — see `_rightWing`/`_leftWing` doc comment.)
    // Rev. 3: apex 0.74 -> 0.774 and cross-over nudge 0.018 -> 0.051, part of
    // the same reference fit as `_rightWing`/`_leftWing` (this is what sizes
    // the central teardrop to match the reference).
    final apexY = center.dy + radius * 0.774;
    final rightApex = Offset(center.dx - radius * 0.051, apexY);
    final leftApex = Offset(center.dx + radius * 0.051, apexY);

    // Rev. 4: the wings themselves are painted at a shrunk [_wingInset] of
    // the sphere's radius — apex position above is untouched, so this only
    // pulls each petal's own reach in slightly, buying the clearance
    // [_maxPetalOpen]/[_maxFlareGrow] spend back at rest.
    final wingRadius = radius * _wingInset;

    _paintWing(
      canvas: canvas,
      apex: rightApex,
      radius: wingRadius,
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
          0.58 + p.brightness * 0.12 - legibilityT * 0.10 + liveBoost * 0.08,
      // Lower than before (was 0.88) — frosted glass, not an opaque
      // sticker: the cherry sphere underneath should visibly read through
      // the petal via real alpha compositing (spec: "Petal material").
      alpha: ((0.82 + legibilityT * 0.16) * staticDetail).clamp(0, 1),
      accent: material,
      angelicGlow: connectedGlow,
      compact: compact,
    );
    _paintWing(
      canvas: canvas,
      apex: leftApex,
      radius: wingRadius,
      def: _leftWing,
      angle: leftAngle,
      flare: leftFlare,
      tintAmount:
          0.58 + p.brightness * 0.12 - legibilityT * 0.10 + liveBoost * 0.08,
      alpha: ((0.82 + legibilityT * 0.16) * staticDetail).clamp(0, 1),
      accent: material,
      angelicGlow: connectedGlow,
      compact: compact,
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
      _wingPath(rightApex, wingRadius, _rightWing, rightAngle, rightFlare),
      _wingPath(leftApex, wingRadius, _leftWing, leftAngle, leftFlare),
    );
    canvas.drawPath(
      overlap,
      Paint()
        ..color = _shade(_tint(material, 0.42), 0.16).withValues(
          // Faded out while speaking: the stacked-glass darkening would
          // otherwise read as a dim outlined loop in the lit teardrop.
          alpha: ((0.18 + legibilityT * 0.08) * staticDetail * (1 - connectedGlow))
              .clamp(0, 1),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.035),
    );

    // 5c. Connected: the lower central teardrop becomes the brightest,
    // most dimensional point — magenta energy pooled at its base, a soft
    // lavender halo, and a white-hot core filling it (not an outline). Full
    // intensity speaking; a dimmer, warmer version through listening/thinking.
    if (connectedGlow > 0.001) {
      final g = connectedGlow;
      final b = overlap.getBounds();
      final poolC = Offset(b.center.dx, b.bottom - b.height * 0.22);
      final poolR = radius * 0.50;
      canvas.drawCircle(
        poolC,
        poolR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              _glowMagenta.withValues(alpha: 0.70 * g),
              _glowMagenta.withValues(alpha: 0.28 * g),
              _glowMagenta.withValues(alpha: 0),
            ],
            stops: const [0, 0.5, 1],
          ).createShader(Rect.fromCircle(center: poolC, radius: poolR))
          ..blendMode = compact ? BlendMode.srcOver : BlendMode.screen,
      );
      canvas.drawPath(
        overlap,
        _glowStroke(_glowLavender.withValues(alpha: 0.60 * g), radius * 0.08,
            radius * 0.06, compact),
      );
      final coreC = Offset(b.center.dx, b.top + b.height * 0.62);
      final coreR = math.max(b.width, b.height) * 0.55;
      canvas.save();
      canvas.clipPath(overlap);
      // Lavender-magenta body so the teardrop reads as its own lit glass
      // drop rather than washing out to the same white as the petals.
      canvas.drawPath(
        overlap,
        Paint()..color = _glowTeardrop.withValues(alpha: 0.50 * g),
      );
      canvas.drawCircle(
        coreC,
        coreR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: 0.95 * g),
              _glowLavenderWhite.withValues(alpha: 0.55 * g),
              _glowLavenderWhite.withValues(alpha: 0.10 * g),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: coreC, radius: coreR))
          ..blendMode = compact ? BlendMode.srcOver : BlendMode.screen,
      );
      canvas.restore();
      canvas.drawPath(
        overlap,
        _glowStroke(_glowPearl.withValues(alpha: 0.75 * g), radius * 0.045,
            radius * 0.025, compact),
      );
      // Soft white-hot rim on the drop, matching the petals' own edge.
      canvas.drawPath(
        overlap,
        _glowStroke(Colors.white.withValues(alpha: 0.95 * g),
            math.max(1.0, radius * 0.016), radius * 0.006, compact),
      );
    }

    // 6. Soft reflection across the upper-left (rev. 3: smaller and tilted
    // further than rev. 2's 0.27-radius patch, which read as a pale wash in
    // the direct comparison against the state sheet). Elongated via a canvas
    // transform so gradient and circle stretch together into one ellipse.
    final hlDrift = restingWings ? 0.0 : math.sin(t * 0.12) * 0.03;
    final hlCenter =
        center + Offset(-radius * (0.46 + hlDrift), -radius * (0.50 - hlDrift));
    final hlFade = 1 - legibilityT * 0.65;
    canvas.save();
    canvas.translate(hlCenter.dx, hlCenter.dy);
    canvas.rotate(-0.75);
    canvas.scale(2.2, 1.0);
    final hlR = radius * 0.20;
    canvas.drawCircle(
      Offset.zero,
      hlR,
      Paint()
        ..shader = _memoShader(
          // Drawn at Offset.zero in a translated frame: hlR derives from
          // radius, the alphas from brightness and legibilityT (hlFade);
          // highlightWhite is const.
          ('highlight', radius, p.brightness, legibilityT),
          () => RadialGradient(
            colors: [
              highlightWhite.withValues(
                alpha: (0.38 + p.brightness * 0.08) * hlFade,
              ),
              highlightWhite.withValues(alpha: 0.12 * hlFade),
              highlightWhite.withValues(alpha: 0),
            ],
            stops: const [0, 0.5, 1],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: hlR)),
        ),
    );
    canvas.restore();

    // 7. Glass rim: a thin light line right at the silhouette plus a faint
    // second line just inside it (the glass's thickness). While connected
    // the rim itself also glows hot pink from the inside (full while
    // speaking, dimmer through listening/thinking).
    final rimColor = _tint(Color.lerp(material, _glowSphereHot, 0.6)!, 0.25);
    canvas.drawCircle(
      center,
      radius * 0.992,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.018
        ..color = rimColor.withValues(alpha: 0.55 + 0.35 * connectedGlow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.008),
    );
    canvas.drawCircle(
      center,
      radius * 0.935,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.010
        ..color = rimColor.withValues(alpha: 0.16 + 0.16 * connectedGlow)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.008),
    );
    if (connectedGlow > 0.001) {
      canvas.drawCircle(
        center,
        radius,
        _glowStroke(_glowSphereHot.withValues(alpha: 0.95 * connectedGlow),
            radius * 0.12, radius * 0.05, compact),
      );
    }

    canvas.restore();

    // 7b. Connected rim bloom just outside the silhouette (glow tiers only).
    if (connectedGlow > 0.001 &&
        showGlow &&
        (tier == _Tier.medium || tier == _Tier.large)) {
      canvas.drawCircle(
        center,
        radius * 1.005,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.03
          ..color = _glowSphereHot.withValues(alpha: 0.45 * connectedGlow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.025)
          ..blendMode = BlendMode.screen,
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = radius * 0.012
          ..color = _tint(_glowSphereHot, 0.55)
              .withValues(alpha: 0.55 * connectedGlow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.006)
          ..blendMode = BlendMode.screen,
      );
    }

    // 8. Specular: one elongated streak hugging the upper-left rim, soft all
    // the way to its core (no hard "eye glint" dot). Skipped on tiny and
    // faded out toward ~40px, as before.
    if (tier != _Tier.tiny && legibilityT < 1) {
      final specFade = 1 - legibilityT * 0.8;
      final specCenter = center + Offset(-radius * 0.56, -radius * 0.60);
      final specR = radius * 0.09;
      canvas.save();
      canvas.translate(specCenter.dx, specCenter.dy);
      canvas.rotate(-0.80);
      canvas.scale(2.6, 1.0);
      canvas.drawCircle(
        Offset.zero,
        specR,
        Paint()
          ..shader = _memoShader(
            // Offset.zero frame again: specR from radius, specFade from
            // legibilityT.
            ('specular', radius, legibilityT),
            () => RadialGradient(
              colors: [
                highlightWhite.withValues(alpha: 0.80 * specFade),
                highlightWhite.withValues(alpha: 0.35 * specFade),
                highlightWhite.withValues(alpha: 0),
              ],
              stops: const [0, 0.45, 1],
            ).createShader(
                Rect.fromCircle(center: Offset.zero, radius: specR)),
          ),
      );
      canvas.restore();
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
      old.staticDetail != staticDetail ||
      old.voiceLive != voiceLive ||
      old.wingMotion != wingMotion;
}
