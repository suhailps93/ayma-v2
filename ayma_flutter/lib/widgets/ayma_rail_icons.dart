import 'package:flutter/material.dart';

/// Ayma's own action-rail icon language (founder spec, 2026-09-22) —
/// replacing the generic Material icons the public-profile action rail
/// (`_RailButton` in `public_profile_screen.dart`) used to draw for Like /
/// Chat / Web search / Match. Four vector glyphs, each a `CustomPainter`
/// (not a raster asset, not a Material `Icon` font glyph): [AymaHeartGlyph],
/// [AymaChatGlyph], [AymaSearchGlyph] and [AymaMatchGlyph].
///
/// Colour rule (non-negotiable per spec): none of these paint a hardcoded
/// colour literal. Every glyph takes the live accent [Color] as a
/// constructor argument — callers pass `context.ac.accent`, which already
/// repaints instantly app-wide whenever `AccentColorController` changes (see
/// `main.dart`'s `AnimatedBuilder` over `accentColorControllerGlobal`, and
/// `theme.dart`'s `AymaTheme.lightWithAccent`/`darkWithAccent`) — so these
/// glyphs recolour live with zero code here that knows about that plumbing.
/// Any lighter/darker variant a glyph needs (a highlight, a shadow, a
/// translucent overlap) is derived from that same accent via [tintAccent]/
/// [shadeAccent], the same lerp-toward-white/black technique
/// `AymaOrbPainter` already uses — never a second named colour.
///
/// Each glyph takes a [filled] flag: `false` draws a thin rounded outline
/// (the "not done yet" state), `true` draws a solid silhouette with a soft
/// tonal gradient and a small specular highlight (the "done" state) — the
/// same glass-highlight technique `AymaOrbPainter` uses for its sphere, so a
/// filled glyph still reads on top of an accent-coloured button circle via
/// luminance rather than needing a second hue for contrast.

/// Lightens [c] toward white by fraction [t] (0..1).
Color tintAccent(Color c, double t) => Color.lerp(c, Colors.white, t)!;

/// Darkens [c] toward black by fraction [t] (0..1).
Color shadeAccent(Color c, double t) => Color.lerp(c, Colors.black, t)!;

/// Shared sizing/paint base for the four glyphs — reads [IconTheme]'s size
/// the same way a plain `Icon` would when no explicit [size] is given, so
/// swapping one of these in for `Icon(...)` inside an `IconTheme` (as
/// `_RailButton` already does) needs no other change at the call site.
abstract class AymaGlyph extends StatelessWidget {
  const AymaGlyph({
    super.key,
    required this.accent,
    required this.filled,
    this.size,
  });

  /// The live selected accent colour (`context.ac.accent`) — never a literal.
  final Color accent;

  /// `true` = solid "done" silhouette, `false` = thin "not done" outline.
  final bool filled;

  /// Overrides the ambient [IconTheme] size when given.
  final double? size;

  /// Builds this glyph's painter directly — exposed (rather than kept
  /// private) so the offline PNG verification tool
  /// (`tool/generate_rail_icons_test.dart`) can rasterize each glyph without
  /// a widget tree.
  CustomPainter buildPainter();

  @override
  Widget build(BuildContext context) {
    final s = size ?? IconTheme.of(context).size ?? 22;
    return SizedBox(
      width: s,
      height: s,
      child: CustomPaint(painter: buildPainter()),
    );
  }
}

// ---------------------------------------------------------------------------
// 1. LIKE — heart
// ---------------------------------------------------------------------------

class AymaHeartGlyph extends AymaGlyph {
  const AymaHeartGlyph({
    super.key,
    required super.accent,
    required super.filled,
    super.size,
  });

  @override
  CustomPainter buildPainter() =>
      _HeartPainter(accent: accent, filled: filled);
}

Path _heartPath(Size size) {
  final w = size.width, h = size.height;
  return Path()
    ..moveTo(w * 0.50, h * 0.86)
    ..cubicTo(w * 0.10, h * 0.60, w * 0.00, h * 0.28, w * 0.28, h * 0.14)
    ..cubicTo(w * 0.40, h * 0.07, w * 0.50, h * 0.15, w * 0.50, h * 0.27)
    ..cubicTo(w * 0.50, h * 0.15, w * 0.60, h * 0.07, w * 0.72, h * 0.14)
    ..cubicTo(w * 1.00, h * 0.28, w * 0.90, h * 0.60, w * 0.50, h * 0.86)
    ..close();
}

class _HeartPainter extends CustomPainter {
  _HeartPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _heartPath(size);
    if (filled) {
      _fillGlyph(canvas, path, accent);
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.shortestSide * 0.10
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HeartPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// 2. CHAT — rounded speech bubble
// ---------------------------------------------------------------------------

class AymaChatGlyph extends AymaGlyph {
  const AymaChatGlyph({
    super.key,
    required super.accent,
    required super.filled,
    super.size,
  });

  @override
  CustomPainter buildPainter() => _ChatPainter(accent: accent, filled: filled);
}

Path _chatPath(Size size) {
  final w = size.width, h = size.height;
  final rect = Rect.fromLTWH(w * 0.06, h * 0.10, w * 0.88, h * 0.58);
  final body = Path()
    ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(h * 0.18)));
  final tail = Path()
    ..moveTo(w * 0.22, h * 0.64)
    ..lineTo(w * 0.36, h * 0.64)
    ..lineTo(w * 0.36, h * 0.80)
    ..lineTo(w * 0.14, h * 0.92)
    ..close();
  return Path.combine(PathOperation.union, body, tail);
}

class _ChatPainter extends CustomPainter {
  _ChatPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _chatPath(size);
    if (filled) {
      _fillGlyph(canvas, path, accent);
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.shortestSide * 0.10
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChatPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// 3. WEB SEARCH — magnifying glass + four-point sparkle
// ---------------------------------------------------------------------------

class AymaSearchGlyph extends AymaGlyph {
  const AymaSearchGlyph({
    super.key,
    required super.accent,
    required super.filled,
    super.size,
  });

  @override
  CustomPainter buildPainter() =>
      _SearchPainter(accent: accent, filled: filled);
}

class _SearchPainter extends CustomPainter {
  _SearchPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final center = Offset(w * 0.40, h * 0.44);
    final r = w * 0.23;
    final strokeW = size.shortestSide * 0.11;
    final handleStart = center + Offset(r * 0.70, r * 0.70);
    final handleEnd = Offset(w * 0.88, h * 0.90);

    if (filled) {
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.35),
            colors: [
              tintAccent(accent, 0.55),
              accent,
              shadeAccent(accent, 0.20),
            ],
            stops: const [0, 0.55, 1],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (r * 0.09).clamp(0.6, 4.0)
          ..color = shadeAccent(accent, 0.34).withValues(alpha: 0.55),
      );
      final hl = center + Offset(-r * 0.32, -r * 0.34);
      canvas.drawCircle(
        hl,
        r * 0.36,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.65),
            Colors.white.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: hl, radius: r * 0.36)),
      );
    } else {
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..color = accent,
      );
    }

    canvas.drawLine(
      handleStart,
      handleEnd,
      Paint()
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..color = filled ? shadeAccent(accent, 0.28) : accent,
    );

    final sparkleCenter = Offset(w * 0.80, h * 0.20);
    final sparkleR = w * 0.17;
    if (filled) {
      _paintSparkle(canvas, sparkleCenter, sparkleR, tintAccent(accent, 0.35));
      canvas.drawPath(
        _sparklePath(sparkleCenter, sparkleR),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (sparkleR * 0.09).clamp(0.5, 3.0)
          ..strokeJoin = StrokeJoin.round
          ..color = shadeAccent(accent, 0.30).withValues(alpha: 0.5),
      );
    } else {
      _paintSparkle(canvas, sparkleCenter, sparkleR, accent);
    }
  }

  static Path _sparklePath(Offset c, double r) {
    return Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + r * 0.16, c.dy - r * 0.16, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + r * 0.16, c.dy + r * 0.16, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - r * 0.16, c.dy + r * 0.16, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - r * 0.16, c.dy - r * 0.16, c.dx, c.dy - r)
      ..close();
  }

  static void _paintSparkle(Canvas canvas, Offset c, double r, Color color) {
    canvas.drawPath(_sparklePath(c, r), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _SearchPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// 4. MATCH — two person heads whose bodies combine into one heart
// ---------------------------------------------------------------------------

class AymaMatchGlyph extends AymaGlyph {
  const AymaMatchGlyph({
    super.key,
    required super.accent,
    required super.filled,
    super.size,
  });

  @override
  CustomPainter buildPainter() =>
      _MatchPainter(accent: accent, filled: filled);
}

/// One "body" lobe's shape — a rounded shield/petal, wide near its own head
/// and tapering to a point at the shared bottom apex — the same
/// apex-to-outer-bulge-to-shared-point construction `AymaOrbPainter`'s
/// wing/petal lobes use (`_WingDef`/`_wingPath`), adapted here per the
/// founder's own steer ("check ayma_orb.dart's petal-overlap/translucency
/// technique"). Defined once for the right-hand lobe in plain 0..1 icon
/// space (not apex-relative, unlike the orb's wings — easier to reason about
/// for a shape this simple) and mirrored via [mirror] for the left, so the
/// two are a genuine reflection of each other, per the spec's "symmetrical".
/// The inner edge deliberately crosses past the icon's own centreline so the
/// mirrored pair overlap near the bottom, reading as one merged heart.
Path _personBodyPath(Size size, {required bool mirror}) {
  final w = size.width, h = size.height;
  double mx(double x) => mirror ? w - x : x;
  return Path()
    ..moveTo(mx(w * 0.50), h * 0.87)
    ..cubicTo(mx(w * 0.60), h * 0.80, mx(w * 0.82), h * 0.74, mx(w * 0.89), h * 0.56)
    ..cubicTo(mx(w * 0.93), h * 0.41, mx(w * 0.81), h * 0.30, mx(w * 0.66), h * 0.32)
    ..cubicTo(mx(w * 0.53), h * 0.34, mx(w * 0.39), h * 0.46, mx(w * 0.41), h * 0.60)
    ..cubicTo(mx(w * 0.43), h * 0.70, mx(w * 0.46), h * 0.80, mx(w * 0.50), h * 0.87)
    ..close();
}

class _MatchPainter extends CustomPainter {
  _MatchPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rightLobe = _personBodyPath(size, mirror: false);
    final leftLobe = _personBodyPath(size, mirror: true);

    final headR = w * 0.115;
    final rightHead = Offset(w * 0.66, h * 0.205);
    final leftHead = Offset(w * 0.34, h * 0.205);

    if (filled) {
      // Each lobe painted as its own soft accent-tinted fill at partial
      // opacity — where they overlap near the shared bottom point, the
      // alpha compositing itself produces the richer "translucent overlap"
      // tone the spec asks for, without a second hardcoded colour.
      canvas.drawPath(
        rightLobe,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [tintAccent(accent, 0.45), accent],
          ).createShader(rightLobe.getBounds())
          ..color = accent.withValues(alpha: 0.88),
      );
      canvas.drawPath(
        leftLobe,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tintAccent(accent, 0.30), shadeAccent(accent, 0.10)],
          ).createShader(leftLobe.getBounds())
          ..color = accent.withValues(alpha: 0.88),
      );
      _edgeDefine(canvas, rightLobe, accent);
      _edgeDefine(canvas, leftLobe, accent);
      for (final c in [leftHead, rightHead]) {
        canvas.drawCircle(
          c,
          headR,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.3, -0.4),
              colors: [tintAccent(accent, 0.5), accent],
            ).createShader(Rect.fromCircle(center: c, radius: headR)),
        );
        canvas.drawCircle(
          c,
          headR,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (headR * 0.12).clamp(0.6, 3.0)
            ..color = shadeAccent(accent, 0.34).withValues(alpha: 0.5),
        );
      }
      // Small shared specular highlight, echoing the orb's glass glint.
      final hl = Offset(w * 0.40, h * 0.52);
      canvas.drawCircle(
        hl,
        w * 0.13,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: hl, radius: w * 0.13)),
      );
    } else {
      final strokeW = size.shortestSide * 0.075;
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = accent;
      canvas.drawPath(rightLobe, stroke);
      canvas.drawPath(leftLobe, stroke);
      for (final c in [leftHead, rightHead]) {
        canvas.drawCircle(c, headR, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatchPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// Shared fill helper (heart + chat — a plain silhouette, unlike search's
// circle+handle+sparkle or match's two independently-graded lobes).
// ---------------------------------------------------------------------------

void _fillGlyph(Canvas canvas, Path path, Color accent) {
  final rect = path.getBounds();
  canvas.drawPath(
    path,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          tintAccent(accent, 0.50),
          accent,
          shadeAccent(accent, 0.22),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(rect),
  );
  _edgeDefine(canvas, path, accent);
  final hl = Offset(rect.left + rect.width * 0.34, rect.top + rect.height * 0.30);
  final r = rect.shortestSide * 0.32;
  canvas.drawCircle(
    hl,
    r,
    Paint()
      ..shader = RadialGradient(colors: [
        Colors.white.withValues(alpha: 0.62),
        Colors.white.withValues(alpha: 0),
      ]).createShader(Rect.fromCircle(center: hl, radius: r)),
  );
}

/// A thin `shadeAccent`-derived rim stroked just inside a filled glyph's own
/// silhouette — pure luminance, no second hue — so a "filled" glyph still
/// reads as a distinct shape when the button circle behind it is *also*
/// accent-coloured (the active rail-button state): without this, a flat
/// accent-on-accent fill all but disappears except for its highlight dot.
void _edgeDefine(Canvas canvas, Path path, Color accent) {
  final side = path.getBounds().shortestSide;
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (side * 0.045).clamp(0.6, 4.0)
      ..strokeJoin = StrokeJoin.round
      ..color = shadeAccent(accent, 0.34).withValues(alpha: 0.55),
  );
}
