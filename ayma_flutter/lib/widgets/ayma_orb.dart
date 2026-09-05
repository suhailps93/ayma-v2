import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// What the orb is doing — drives its amplitude and speed (§14.1).
enum OrbState { idle, listening, speaking, thinking }

/// The living gradient "orb" brand motif: a soft liquid blob whose edge is
/// perturbed by layered sines, wrapped in faint halo rings and a warm glow.
/// It breathes when [OrbState.idle], ripples when listening, moves with Ayma's
/// voice when speaking, and slows (with three dots) when thinking.
///
/// [active] is the back-compat shortcut used by the tab bar — `true` maps to a
/// gently lit idle orb, `false` to a dim one. Pass [state] for the full range.
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

class _AymaOrbState extends State<AymaOrb>
    with SingleTickerProviderStateMixin {
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
      widget.state ?? (widget.active ? OrbState.speaking : OrbState.idle);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final lit = _state != OrbState.idle;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _OrbPainter(
            t: _c.value * 120,
            state: _state,
            accent: ac.accent,
            dim: ac.fgMute,
            bg: ac.bg,
            lit: lit,
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.t,
    required this.state,
    required this.accent,
    required this.dim,
    required this.bg,
    required this.lit,
  });

  final double t;
  final OrbState state;
  final Color accent;
  final Color dim;
  final Color bg;
  final bool lit;

  static const _points = 64;

  double get _amp => switch (state) {
        OrbState.listening => 0.10,
        OrbState.speaking => 0.14,
        OrbState.thinking => 0.06,
        OrbState.idle => 0.03,
      };

  double get _speed => switch (state) {
        OrbState.thinking => 0.6,
        OrbState.speaking => 1.8,
        _ => 1.0,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * 0.38;
    final amp = _amp;
    final speed = _speed;

    // Warm core the blob is filled from — a near-white centre falling to a
    // deep ember rim.
    final warmWhite = Color.lerp(accent, Colors.white, 0.7)!;
    final deepRim = Color.lerp(accent, Colors.black, 0.62)!;
    final midRim = Color.lerp(accent, Colors.black, 0.35)!;

    // Halo rings.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.006
      ..color = (lit ? accent : dim).withValues(alpha: 0.12);
    canvas.drawCircle(center, r * 1.5, ring..color = accent.withValues(alpha: 0.07));
    canvas.drawCircle(center, r * 1.28, ring..color = accent.withValues(alpha: 0.12));

    // Soft outer glow.
    final pulse = 1 + math.sin(t * 1.5) * 0.02;
    canvas.drawCircle(
      center,
      r * 1.16 * pulse,
      Paint()..color = accent.withValues(alpha: lit ? 0.09 : 0.035),
    );

    // The blob path.
    final path = _blobPath(center, r, amp, speed);

    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.16),
          radius: 0.62,
          colors: [warmWhite, accent, midRim, deepRim],
          stops: const [0, 0.42, 0.85, 1],
        ).createShader(Rect.fromCircle(center: center, radius: r * 1.2)),
    );

    // Top-left highlight.
    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.45),
          radius: 0.5,
          colors: [Colors.white.withValues(alpha: 0.45), Colors.white.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Inner depth ring.
    canvas.drawCircle(
      center,
      r * 0.85,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.006
        ..color = Colors.white.withValues(alpha: 0.08),
    );

    // Thinking dots.
    if (state == OrbState.thinking) {
      final dot = Paint()..color = Colors.white;
      final gap = size.shortestSide * 0.09;
      for (var i = 0; i < 3; i++) {
        final o = 0.3 + 0.7 * math.max(0, math.sin(t * 3 - i * 0.8));
        canvas.drawCircle(
          center + Offset((i - 1) * gap, 0),
          size.shortestSide * 0.022,
          dot..color = Colors.white.withValues(alpha: o.toDouble()),
        );
      }
    }
  }

  Path _blobPath(Offset c, double r, double amp, double speed) {
    final pts = <Offset>[];
    for (var i = 0; i < _points; i++) {
      final a = (i / _points) * math.pi * 2;
      final n = math.sin(a * 3 + t * speed) * amp +
          math.sin(a * 5 - t * speed * 1.3) * amp * 0.5 +
          math.sin(a * 2 + t * speed * 0.7) * amp * 0.8;
      final rr = r * (1 + n);
      pts.add(c + Offset(math.cos(a) * rr, math.sin(a) * rr));
    }
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < pts.length; i++) {
      final p0 = pts[i];
      final p1 = pts[(i + 1) % pts.length];
      final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.t != t || old.state != state || old.accent != accent;
}
