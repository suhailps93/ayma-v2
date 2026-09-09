import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// A full-bleed bar whose top and bottom edges ripple as sine waves driven by
/// real audio amplitude — the bottom edge follows the user's mic level, the top
/// edge follows Ayma's output level. Used as the composer surface while a voice
/// call is live.
///
/// Honours reduced-motion: when animations are disabled it renders a static bar
/// with two thin level meters instead of animating.
class VoiceWaveBar extends StatefulWidget {
  const VoiceWaveBar({
    super.key,
    required this.micLevel,
    required this.aymaLevel,
    required this.height,
    this.child,
  });

  /// 0..1, smoothed. Bottom edge amplitude / speed.
  final ValueListenable<double> micLevel;

  /// 0..1, smoothed. Top edge amplitude / speed.
  final ValueListenable<double> aymaLevel;

  final double height;

  /// The controls (mic, stop, …) laid over the bar.
  final Widget? child;

  @override
  State<VoiceWaveBar> createState() => _VoiceWaveBarState();
}

class _VoiceWaveBarState extends State<VoiceWaveBar>
    with SingleTickerProviderStateMixin {
  AnimationController? _phase;

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
                    line: ac.lineSoft,
                    mic: ac.accent,
                    ayma: ac.fg,
                    bg: ac.bgElev,
                  )
                : AnimatedBuilder(
                    animation: Listenable.merge(
                        [phase, widget.micLevel, widget.aymaLevel]),
                    builder: (context, _) => CustomPaint(
                      painter: _WavePainter(
                        phase: phase.value,
                        micLevel: widget.micLevel.value,
                        aymaLevel: widget.aymaLevel.value,
                        fill: ac.bgElev,
                        micColor: ac.accent,
                        aymaColor: ac.fg.withValues(alpha: 0.55),
                      ),
                    ),
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
    required this.micLevel,
    required this.aymaLevel,
    required this.fill,
    required this.micColor,
    required this.aymaColor,
  });

  final double phase; // 0..1
  final double micLevel;
  final double aymaLevel;
  final Color fill;
  final Color micColor;
  final Color aymaColor;

  Path _edge(Size size, {required bool top, required double level}) {
    // Idle baseline so the edge never goes fully flat.
    final amp = (2.0 + level * (size.height * 0.42)).clamp(2.0, size.height / 2);
    final speed = 1.0 + level * 3.0;
    final baseY = top ? amp + 1 : size.height - amp - 1;
    final dir = top ? -1.0 : 1.0;
    const waves = 2.2;
    final path = Path()..moveTo(0, top ? 0 : size.height);
    path.lineTo(0, baseY);
    const step = 6.0;
    for (double x = 0; x <= size.width; x += step) {
      final t = x / size.width;
      final y = baseY +
          dir *
              amp *
              math.sin(
                  (t * waves * 2 * math.pi) + phase * speed * 2 * math.pi);
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, top ? 0 : size.height)
      ..close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = fill);
    canvas.drawPath(
      _edge(size, top: true, level: aymaLevel),
      Paint()..color = aymaColor,
    );
    canvas.drawPath(
      _edge(size, top: false, level: micLevel),
      Paint()..color = micColor.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.phase != phase ||
      old.micLevel != micLevel ||
      old.aymaLevel != aymaLevel;
}

class _StaticMeter extends StatelessWidget {
  const _StaticMeter({
    required this.micLevel,
    required this.aymaLevel,
    required this.line,
    required this.mic,
    required this.ayma,
    required this.bg,
  });

  final ValueListenable<double> micLevel;
  final ValueListenable<double> aymaLevel;
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
          _Meter(level: aymaLevel, color: ayma),
          const Spacer(),
          _Meter(level: micLevel, color: mic),
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.level, required this.color});
  final ValueListenable<double> level;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: level,
      builder: (context, v, _) => Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: v.clamp(0.02, 1.0),
          child: Container(height: 2, color: color),
        ),
      ),
    );
  }
}
