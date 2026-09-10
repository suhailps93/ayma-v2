import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// A full-bleed bar whose top and bottom edges ripple as sine waves driven by
/// real audio amplitude — the bottom edge follows the user's mic level, the top
/// edge follows Ayma's output level. Used as the composer surface while a voice
/// call is live.
///
/// Two edges go deliberately flat:
///  * the **bottom** edge when the user's mic is [muted] (no wave, whatever the
///    mic level reads), and
///  * the **top** edge when Ayma is not [speaking] (and her level is ~0).
/// Both ease back to a wave rather than snapping.
///
/// Honours reduced-motion: when animations are disabled it renders a static bar
/// with two thin level meters instead of animating.
class VoiceWaveBar extends StatefulWidget {
  const VoiceWaveBar({
    super.key,
    required this.micLevel,
    required this.aymaLevel,
    required this.height,
    this.muted = false,
    this.speaking = false,
    this.child,
  });

  /// 0..1, smoothed. Bottom edge amplitude / speed.
  final ValueListenable<double> micLevel;

  /// 0..1, smoothed. Top edge amplitude / speed.
  final ValueListenable<double> aymaLevel;

  final double height;

  /// The user's mic is muted — the bottom edge holds flat.
  final bool muted;

  /// Ayma is speaking — gates the top edge (with [aymaLevel]).
  final bool speaking;

  /// The controls (mic, stop, …) laid over the bar.
  final Widget? child;

  @override
  State<VoiceWaveBar> createState() => _VoiceWaveBarState();
}

class _VoiceWaveBarState extends State<VoiceWaveBar>
    with SingleTickerProviderStateMixin {
  AnimationController? _phase;

  // Eased pixel amplitudes + wave speeds for the two edges. Stepped once per
  // animation tick toward their targets so a mute / stop-speaking lands as a
  // smooth flatten, and coming back is an equally smooth swell.
  double _topAmp = 0;
  double _botAmp = 0;
  double _topSpeed = 1;
  double _botSpeed = 1;

  // Idle ripple so an un-muted, quiet edge still has life. The suppressed
  // edges (muted bottom / silent top) target a true 0 instead.
  static const _idleAmp = 3.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _phase?.dispose();
      _phase = null;
    } else {
      _phase ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 4),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _phase?.dispose();
    super.dispose();
  }

  double _targetAmp(double level, {required bool flat, bool speaking = false}) {
    if (flat) return 0;
    final l = level.clamp(0.0, 1.0);
    if (speaking) {
      // Ayma talking: a bold, lazy roll that can reach ~half the bar's height
      // when she's loud — much taller than the mic's fine ripple, still capped
      // so the crest never clips the bar.
      final swell = l * (widget.height * 0.46);
      return (_idleAmp + swell).clamp(0.0, widget.height * 0.48);
    }
    final swell = l * (widget.height * 0.30);
    return (_idleAmp + swell).clamp(0.0, widget.height / 3);
  }

  /// One easing step toward the current targets. Called from the paint builder,
  /// which the repeating [_phase] controller already rebuilds each frame — so
  /// this needs no `setState` of its own.
  void _step() {
    final micFlat = widget.muted;
    final aymaFlat = !widget.speaking && widget.aymaLevel.value < 0.02;
    final topTarget = _targetAmp(widget.aymaLevel.value,
        flat: aymaFlat, speaking: widget.speaking);
    final botTarget = _targetAmp(widget.micLevel.value, flat: micFlat);
    // Ayma's edge rolls slowly — a lazy cadence, not a busy ripple — and only
    // creeps up a touch when she's genuinely loud (the squared term keeps it
    // slow until the very top of the range).
    final aymaL = widget.aymaLevel.value.clamp(0.0, 1.0);
    final topSpeedTarget = 0.6 + aymaL * aymaL * 1.0;
    final botSpeedTarget = 0.9 + widget.micLevel.value.clamp(0.0, 1.0) * 3.0;
    const k = 0.12; // per-frame lerp — ~300ms to converge, no hard snap
    _topAmp = lerpDouble(_topAmp, topTarget, k)!;
    _botAmp = lerpDouble(_botAmp, botTarget, k)!;
    _topSpeed = lerpDouble(_topSpeed, topSpeedTarget, k)!;
    _botSpeed = lerpDouble(_botSpeed, botSpeedTarget, k)!;
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final phase = _phase;

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: Stack(
        children: [
          Positioned.fill(
            child: phase == null
                ? _StaticMeter(
                    micLevel: widget.micLevel,
                    aymaLevel: widget.aymaLevel,
                    muted: widget.muted,
                    speaking: widget.speaking,
                    line: ac.lineSoft,
                    mic: ac.accent,
                    ayma: ac.fg,
                    bg: ac.bgElev,
                  )
                : AnimatedBuilder(
                    animation: Listenable.merge(
                        [phase, widget.micLevel, widget.aymaLevel]),
                    builder: (context, _) {
                      _step();
                      return CustomPaint(
                        painter: _WavePainter(
                          phase: phase.value,
                          topAmp: _topAmp,
                          botAmp: _botAmp,
                          topSpeed: _topSpeed,
                          botSpeed: _botSpeed,
                          fill: ac.bgElev,
                          micColor: ac.accent,
                          aymaColor: ac.fg.withValues(alpha: 0.55),
                        ),
                      );
                    },
                  ),
          ),
          if (widget.child != null) Positioned.fill(child: widget.child!),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.phase,
    required this.topAmp,
    required this.botAmp,
    required this.topSpeed,
    required this.botSpeed,
    required this.fill,
    required this.micColor,
    required this.aymaColor,
  });

  final double phase; // 0..1
  final double topAmp; // eased pixels
  final double botAmp; // eased pixels
  final double topSpeed;
  final double botSpeed;
  final Color fill;
  final Color micColor;
  final Color aymaColor;

  // Ayma's edge is the low-frequency roller — ~2 broad humps across the bar.
  // The mic edge keeps its slightly finer ripple.
  static const _topWaves = 2.0;
  static const _botWaves = 2.2;
  static const _step = 4.0;

  // The speaking crest is drawn as one confident stroke on top of its band.
  static const _topStroke = 2.75;

  double _waveY(double x, double width, double baseY, double dir, double amp,
          double speed, double waves) =>
      baseY +
      dir *
          amp *
          math.sin((x / width * waves * 2 * math.pi) +
              phase * speed * 2 * math.pi);

  Path _edge(Size size,
      {required bool top,
      required double amp,
      required double speed,
      required double waves}) {
    final flat = amp < 0.4;
    final baseY = top ? amp + 1 : size.height - amp - 1;
    final dir = top ? -1.0 : 1.0;
    final path = Path()..moveTo(0, top ? 0 : size.height);
    path.lineTo(0, baseY);
    if (flat) {
      path.lineTo(size.width, baseY);
    } else {
      for (double x = 0; x <= size.width; x += _step) {
        path.lineTo(x, _waveY(x, size.width, baseY, dir, amp, speed, waves));
      }
      path.lineTo(size.width, baseY);
    }
    path
      ..lineTo(size.width, top ? 0 : size.height)
      ..close();
    return path;
  }

  /// The bare sine curve as an open polyline — for stroking the speaking crest.
  Path _crest(Size size, double amp, double speed, double waves) {
    final baseY = amp + 1;
    final path = Path()..moveTo(0, _waveY(0, size.width, baseY, -1.0, amp, speed, waves));
    for (double x = _step; x <= size.width; x += _step) {
      path.lineTo(x, _waveY(x, size.width, baseY, -1.0, amp, speed, waves));
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = fill);
    canvas.drawPath(
      _edge(size, top: true, amp: topAmp, speed: topSpeed, waves: _topWaves),
      Paint()..color = aymaColor,
    );
    if (topAmp >= 0.4) {
      canvas.drawPath(
        _crest(size, topAmp, topSpeed, _topWaves),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _topStroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = aymaColor,
      );
    }
    canvas.drawPath(
      _edge(size, top: false, amp: botAmp, speed: botSpeed, waves: _botWaves),
      Paint()..color = micColor.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.phase != phase ||
      old.topAmp != topAmp ||
      old.botAmp != botAmp ||
      old.topSpeed != topSpeed ||
      old.botSpeed != botSpeed;
}

class _StaticMeter extends StatelessWidget {
  const _StaticMeter({
    required this.micLevel,
    required this.aymaLevel,
    required this.muted,
    required this.speaking,
    required this.line,
    required this.mic,
    required this.ayma,
    required this.bg,
  });

  final ValueListenable<double> micLevel;
  final ValueListenable<double> aymaLevel;
  final bool muted;
  final bool speaking;
  final Color line;
  final Color mic;
  final Color ayma;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, border: Border.all(color: line)),
      child: Column(
        children: [
          _Meter(level: aymaLevel, color: ayma, flat: !speaking),
          const Spacer(),
          _Meter(level: micLevel, color: mic, flat: muted),
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.level, required this.color, this.flat = false});
  final ValueListenable<double> level;
  final Color color;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: level,
      builder: (context, v, _) => Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: flat ? 0.02 : v.clamp(0.02, 1.0),
          child: Container(height: 2, color: color),
        ),
      ),
    );
  }
}
