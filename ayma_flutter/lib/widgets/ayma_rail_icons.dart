import 'package:flutter/material.dart';

/// Ayma's action-rail icon family (founder spec, Nov 2026 restyle) — the
/// four vertical profile-rail glyphs for Like / Message / Web search / Match
/// (`_RailButton` in `public_profile_screen.dart`): [AymaHeartGlyph],
/// [AymaChatGlyph], [AymaSearchGlyph] and [AymaMatchGlyph]. Each is a
/// `CustomPainter` vector glyph (not a raster asset, not a Material font
/// glyph — the search+sparkle and double-heart shapes don't exist in the
/// Material set at all, and the heart/bubble are drawn here too so all four
/// share one geometry language).
///
/// Quiet outlines in the neutral color (Instagram model):
/// * Rail icons render as clean stroked OUTLINES in `context.ac.fg`
///   (dark theme #EDE9DE, light theme #1A1714) — one consistent stroke
///   thickness across all four ([_strokeFor]), rounded caps/joins, no fill,
///   no circular background, no label, no bloom.
/// * ONLY THE HEART FILLS, AND IT FILLS RED: unliked = outline in `ac.fg`;
///   liked = filled FLAT with `ac.likeRed` (#FF3040). No bloom, no highlight,
///   no gradient.
/// * Message, web research, match: NO filled state on the rail in any state —
///   `hasChatted` / report exists / score exists do not change the rendering;
///   the glyph is the same outline always.
/// * Outside the rail (notification center), glyphs keep rendering as flat
///   fills in the account accent.
///
/// All glyphs carry a very small, tight neutral contact shadow ([_groundShadow])
/// purely so a thin outline stays legible when the rail floats over a bright photo.
class AymaGlyphs {
  const AymaGlyphs._();
}

// ---------------------------------------------------------------------------
// Shared family constants + rendering passes — every glyph below goes through
// these same helpers, which is what makes the four read as ONE family: same
// stroke thickness, same shadow, flat fill treatment.
// ---------------------------------------------------------------------------

/// The family's one stroke thickness, proportional to the glyph's own box —
/// ~2.4 logical px at the rail's 32px artwork size, the weight of a standard
/// outline icon set.
double _strokeFor(Size size) => size.shortestSide * 0.075;

Paint _strokePaint(Color color, double sw) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = sw
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..color = color;

/// A tight, quiet neutral contact shadow so a thin outline never
/// vanishes into a bright photo behind the floating rail. Deliberately
/// small: blur radius on the order of the stroke width itself, low alpha,
/// barely offset — the opposite of the old oversized silhouette glow.
void _groundShadow(Canvas canvas, Path path, double sw,
    {required bool filled}) {
  final paint = filled
      ? (Paint()..color = Colors.black.withValues(alpha: 0.30))
      : (_strokePaint(Colors.black.withValues(alpha: 0.30), sw));
  paint.maskFilter = MaskFilter.blur(BlurStyle.normal, sw * 0.55);
  canvas.save();
  canvas.translate(0, sw * 0.40);
  canvas.drawPath(path, paint);
  canvas.restore();
}

/// The full shared treatment for a single-silhouette glyph: contact shadow,
/// then flat fill if [filled], followed by the same-geometry outline stroke.
void _paintSilhouette(
    Canvas canvas, Path path, Color color, double sw,
    {required bool filled}) {
  _groundShadow(canvas, path, sw, filled: filled);
  if (filled) {
    canvas.drawPath(path, Paint()..color = color);
  }
  canvas.drawPath(path, _strokePaint(color, sw));
}

/// A four-point sparkle (concave-sided star) — the shared "Ayma intelligence"
/// mark the Web-search and Match glyphs both carry, so it reads as one
/// recurring motif rather than two ad-hoc decorations. Small enough that it
/// is drawn solid in BOTH states (a stroked star this tiny would clog).
Path _sparklePath(Offset c, double r) {
  return Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx + r * 0.18, c.dy - r * 0.18, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx + r * 0.18, c.dy + r * 0.18, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx - r * 0.18, c.dy + r * 0.18, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx - r * 0.18, c.dy - r * 0.18, c.dx, c.dy - r)
    ..close();
}

void _paintSparkle(Canvas canvas, Offset c, double r, Color color, double sw,
    {bool filled = false}) {
  final path = _sparklePath(c, r);
  _groundShadow(canvas, path, sw * 0.6, filled: true);
  canvas.drawPath(path, Paint()..color = color);
}

/// A smooth symmetric heart fitted into [rect] — shared by the Like glyph
/// (one big heart) and the Match glyph (two smaller overlapping ones), so
/// "heart" means exactly one shape everywhere on the rail.
Path _heartPathIn(Rect rect) {
  final w = rect.width, h = rect.height;
  final l = rect.left, t = rect.top;
  return Path()
    ..moveTo(l + w * 0.50, t + h * 0.88)
    ..cubicTo(l + w * 0.17, t + h * 0.64, l + w * 0.04, t + h * 0.46,
        l + w * 0.04, t + h * 0.30)
    ..cubicTo(l + w * 0.04, t + h * 0.135, l + w * 0.165, t + h * 0.04,
        l + w * 0.31, t + h * 0.04)
    ..cubicTo(l + w * 0.395, t + h * 0.04, l + w * 0.465, t + h * 0.085,
        l + w * 0.50, t + h * 0.16)
    ..cubicTo(l + w * 0.535, t + h * 0.085, l + w * 0.605, t + h * 0.04,
        l + w * 0.69, t + h * 0.04)
    ..cubicTo(l + w * 0.835, t + h * 0.04, l + w * 0.96, t + h * 0.135,
        l + w * 0.96, t + h * 0.30)
    ..cubicTo(l + w * 0.96, t + h * 0.46, l + w * 0.83, t + h * 0.64,
        l + w * 0.50, t + h * 0.88)
    ..close();
}

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

  /// The color used to render this glyph: `context.ac.fg` for quiet neutral
  /// outlines on the profile rail, `context.ac.likeRed` for the liked heart,
  /// or `context.ac.accent` in notification center.
  final Color accent;

  /// `true` = filled flat with [accent]; `false` = clean stroked outline.
  /// On the profile action rail, only the heart ever fills.
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
// 1. LIKE — one heart. Outline in neutral fg → flat fill in likeRed when liked.
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

class _HeartPainter extends CustomPainter {
  _HeartPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = _strokeFor(size);
    // Inset so the stroke's outer edge stays inside the box.
    final rect = Rect.fromLTWH(
        sw * 0.7, size.height * 0.06, size.width - sw * 1.4,
        size.height * 0.86);
    _paintSilhouette(canvas, _heartPathIn(rect), accent, sw, filled: filled);
  }

  @override
  bool shouldRepaint(covariant _HeartPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// 2. MESSAGE — rounded speech bubble, same visual weight as the heart.
// Outline on the rail; flat accent fill when used in notification center.
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

/// Bubble body + a smoothly curved tail sweeping to the lower-left, unioned
/// into ONE silhouette so the outline state is a single continuous stroke
/// (no seam where the tail meets the body).
Path _chatPath(Size size) {
  final w = size.width, h = size.height;
  final sw = _strokeFor(size);
  final rect = Rect.fromLTWH(
      sw * 0.7, h * 0.12, w - sw * 1.4, h * 0.62);
  final body = Path()
    ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(h * 0.20)));
  final tail = Path()
    ..moveTo(w * 0.24, h * 0.56) // safely inside the body
    ..lineTo(w * 0.48, h * 0.56)
    ..quadraticBezierTo(w * 0.46, h * 0.79, w * 0.18, h * 0.92)
    ..quadraticBezierTo(w * 0.27, h * 0.79, w * 0.24, h * 0.66)
    ..close();
  return Path.combine(PathOperation.union, body, tail);
}

class _ChatPainter extends CustomPainter {
  _ChatPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    _paintSilhouette(canvas, _chatPath(size), accent, _strokeFor(size),
        filled: filled);
  }

  @override
  bool shouldRepaint(covariant _ChatPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// 3. WEB SEARCH ("run web research on this person") — a clean magnifying
// glass that immediately reads as SEARCH, plus the small shared sparkle at
// the upper-right marking it as Ayma-run research. Outline on the rail;
// flat accent fill when used in notification center.
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
    final sw = _strokeFor(size);

    final lensCenter = Offset(w * 0.42, h * 0.48);
    final lensR = w * 0.26;
    final lens = Path()
      ..addOval(Rect.fromCircle(center: lensCenter, radius: lensR));

    // Handle: from the lens rim along the 45° diagonal to the lower-right
    // corner — as a stroked line with round caps, the same stroke width as
    // everything else in the family.
    const diag = 0.7071; // cos/sin 45°
    final handleStart = lensCenter + Offset(lensR * diag, lensR * diag);
    final handleEnd = Offset(w * 0.86, h * 0.92);
    final handle = Path()
      ..moveTo(handleStart.dx, handleStart.dy)
      ..lineTo(handleEnd.dx, handleEnd.dy);

    _groundShadow(canvas, lens, sw, filled: filled);
    _groundShadow(canvas, handle, sw * 1.25, filled: false);

    if (filled) {
      canvas.drawPath(lens, Paint()..color = accent);
    }
    canvas.drawPath(lens, _strokePaint(accent, sw));
    // The handle stays a stroke in both states (it has no interior to fill);
    // marginally wider than the family stroke so it reads as the sturdy grip
    // of the glass rather than a stray line, matching how outline icon sets
    // weight magnifier handles.
    canvas.drawPath(handle, _strokePaint(accent, sw * 1.25));

    _paintSparkle(canvas, Offset(w * 0.80, h * 0.16), w * 0.125, accent, sw,
        filled: filled);
  }

  @override
  bool shouldRepaint(covariant _SearchPainter old) =>
      old.accent != accent || old.filled != filled;
}

// ---------------------------------------------------------------------------
// 4. MATCH (compatibility score) — two elegant overlapping hearts, with the
// same small sparkle above-right. Outline pair → flat fill.
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

class _MatchPainter extends CustomPainter {
  _MatchPainter({required this.accent, required this.filled});

  final Color accent;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final sw = _strokeFor(size);

    // Two same-size hearts, upper-left and lower-right, overlapping in the
    // middle.
    final back = _heartPathIn(Rect.fromLTWH(w * 0.03, h * 0.17, w * 0.56, h * 0.56));
    final front = _heartPathIn(Rect.fromLTWH(w * 0.38, h * 0.40, w * 0.56, h * 0.56));
    final union = Path.combine(PathOperation.union, back, front);

    _groundShadow(canvas, union, sw, filled: filled);

    if (filled) {
      canvas.drawPath(union, Paint()..color = accent);
    }
    canvas.drawPath(back, _strokePaint(accent, sw));
    canvas.drawPath(front, _strokePaint(accent, sw));

    _paintSparkle(canvas, Offset(w * 0.82, h * 0.15), w * 0.115, accent, sw,
        filled: filled);
  }

  @override
  bool shouldRepaint(covariant _MatchPainter old) =>
      old.accent != accent || old.filled != filled;
}
