import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A circular progress ring for a 0–100 profile-completeness [score]. The centre
/// shows the percentage, or a check mark once the profile is complete. Shared by
/// the Profile-tab card and the "Complete your profile" screen header.
class CompletenessRing extends StatelessWidget {
  const CompletenessRing({
    super.key,
    required this.score,
    this.complete = false,
    this.size = 56,
    this.stroke = 5,
  });

  final int score;

  /// Everything in today's question set is answered — shows a check mark
  /// instead of the percentage. [score] itself never reaches a literal 100
  /// (see `completeness._score`), so this is the real "done for now" signal.
  final bool complete;
  final double size;
  final double stroke;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final clamped = score.clamp(0, 100);
    final done = complete || clamped >= 100;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          pct: clamped / 100.0,
          track: ac.track,
          fill: ac.accent,
          stroke: stroke,
        ),
        child: Center(
          child: done
              ? Icon(Icons.check_rounded, size: size * 0.44, color: ac.accent)
              : Text(
                  '$clamped%',
                  style: AymaType.mono(size: size * 0.24, color: ac.fg)
                      .copyWith(letterSpacing: 0),
                ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.pct,
    required this.track,
    required this.fill,
    required this.stroke,
  });

  final double pct;
  final Color track;
  final Color fill;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - stroke) / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    if (pct <= 0) return;
    final fillPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = fill;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2, // start at 12 o'clock
      2 * math.pi * pct.clamp(0.0, 1.0),
      false,
      fillPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.pct != pct ||
      old.track != track ||
      old.fill != fill ||
      old.stroke != stroke;
}
