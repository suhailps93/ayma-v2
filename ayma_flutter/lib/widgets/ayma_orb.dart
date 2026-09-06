import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// What Ayma is doing — drives the spark's motion.
enum OrbState { idle, listening, speaking, thinking }

/// The Ayma brand mark: an 8-ray asterisk "spark" in Ember with a soft glow.
/// Still when [OrbState.idle], turns slowly while listening or thinking, and
/// shimmers (scale pulse + faster spin) while Ayma is speaking.
///
/// [active] is the tab-bar shortcut — `true` → a lit, gently turning spark,
/// `false` → a dim static one. Pass [state] for the full range.
class AymaOrb extends StatefulWidget {
  const AymaOrb({
    super.key,
    this.size = 26,
    this.active = false,
    this.state,
  });

  final double size;
  final bool active;
  final OrbState? state;

  @override
  State<AymaOrb> createState() => _AymaOrbState();
}

class _AymaOrbState extends State<AymaOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 120),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  OrbState get _state =>
      widget.state ?? (widget.active ? OrbState.listening : OrbState.idle);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _SparkPainter(
            t: _c.value * 120,
            state: _state,
            accent: ac.accent,
            dim: ac.fgMute,
          ),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.t,
    required this.state,
    required this.accent,
    required this.dim,
  });

  final double t;
  final OrbState state;
  final Color accent;
  final Color dim;

  static const _rays = 8;

  double get _spin => switch (state) {
        OrbState.idle => 0,
        OrbState.listening => 0.35,
        OrbState.thinking => 0.22,
        OrbState.speaking => 0.9,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final unit = size.shortestSide;
    final lit = state != OrbState.idle;
    final col = lit ? accent : dim;

    final shimmer =
        state == OrbState.speaking ? 1 + math.sin(t * 6) * 0.035 : 1.0;
    final rayLen = unit * 0.46 * shimmer;
    final baseHalf = unit * 0.085; // ray half-width at the hub
    final rot = t * _spin;

    // Soft glow behind the mark.
    if (lit) {
      canvas.drawCircle(
        c,
        rayLen * 1.15,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent.withValues(alpha: 0.20),
              accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: rayLen * 1.15)),
      );
    }

    // Eight tapered rays.
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = col.withValues(alpha: lit ? 1 : 0.7);

    for (var i = 0; i < _rays; i++) {
      final a = rot + (i / _rays) * math.pi * 2;
      final tip = c + Offset(math.cos(a) * rayLen, math.sin(a) * rayLen);
      final left = c +
          Offset(
            math.cos(a + math.pi / 2) * baseHalf,
            math.sin(a + math.pi / 2) * baseHalf,
          );
      final right = c +
          Offset(
            math.cos(a - math.pi / 2) * baseHalf,
            math.sin(a - math.pi / 2) * baseHalf,
          );
      canvas.drawPath(
        Path()
          ..moveTo(left.dx, left.dy)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(right.dx, right.dy)
          ..close(),
        fill,
      );
    }

    // Warm hub.
    canvas.drawCircle(
      c,
      unit * 0.12,
      Paint()..color = Color.lerp(col, Colors.white, lit ? 0.5 : 0.15)!,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.t != t || old.state != state || old.accent != accent;
}
