import 'package:flutter/material.dart';

/// Ayma's action-rail icon family (founder spec, 2026-09-26 redesign) — the
/// four vertical profile-rail glyphs for Like / Message / Web search / Match
/// (`_RailButton` in `public_profile_screen.dart`): [AymaHeartGlyph],
/// [AymaChatGlyph], [AymaSearchGlyph] and [AymaMatchGlyph]. Each is a
/// `CustomPainter` vector glyph (not a raster asset, not a Material font
/// glyph — the search+sparkle and double-heart shapes don't exist in the
/// Material set at all, and the heart/bubble are drawn here too so all four
/// share one geometry language).
///
/// ONE coherent outline→filled system (this file's whole reason to exist —
/// it replaces the previous 3D/sticker "filled glass" rendering, rejected
/// 2026-09-26):
///
/// * INACTIVE = the glyph as a clean stroked OUTLINE — one consistent stroke
///   thickness across all four ([_strokeFor]), rounded caps/joins, no fill,
///   no circular background, no label, and effectively no glow.
/// * COMPLETED = the SAME exact geometry, FILLED with the accent — never a
///   different icon, no checkmarks/badges/extra circles. Slightly more
///   prominent, never larger: a subtle lighter internal highlight
///   ([_innerHighlight]) plus a small, tight accent bloom hugging the
///   silhouette ([_bloom]) — deliberately restrained, never a big fuzzy
///   cloud behind the icon.
///
/// Both states also carry a very small, tight neutral contact shadow
/// ([_groundShadow]) purely so a thin accent stroke stays legible when the
/// rail floats over a bright photo — it is not part of the colour story and
/// is nothing like the old oversized glow.
///
/// Colour rule (non-negotiable): no hardcoded colour literal anywhere here.
/// Every glyph takes the live accent [Color] as a constructor argument —
/// callers pass `context.ac.accent`, which repaints app-wide whenever
/// `AccentColorController` changes — so the family recolours live under any
/// accent pick and either theme. The only other colours used are
/// `Colors.white`/`Colors.black` at low alpha for the internal highlight and
/// the contact shadow, both derived overlays rather than palette choices.
class AymaGlyphs {
  const AymaGlyphs._();
}

// ---------------------------------------------------------------------------
// Shared family constants + rendering passes — every glyph below goes through
// these same helpers, which is what makes the four read as ONE family: same
// stroke thickness, same shadow, same completed-state fill/highlight/bloom.
// ---------------------------------------------------------------------------

/// The family's one stroke thickness, proportional to the glyph's own box —
/// ~2.4 logical px at the rail's 32px artwork size, the weight of a standard
/// outline icon set.
double _strokeFor(Size size) => size.shortestSide * 0.075;

/// Lightens [c] toward white by fraction [t] (0..1) — used only for the
/// completed state's internal highlight tint, never as a standalone colour.
Color _tint(Color c, double t) => Color.lerp(c, Colors.white, t)!;

Paint _strokePaint(Color color, double sw) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = sw
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..color = color;

/// A tight, quiet neutral contact shadow so a thin accent outline never
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

/// The completed state's restrained accent bloom — a small, tight blur of
/// the glyph's own filled silhouette, hugging its edge. Never a big soft
/// cloud: the blur radius stays within ~1.5 stroke widths.
void _bloom(Canvas canvas, Path path, Color accent, double sw) {
  canvas.drawPath(
    path,
    Paint()
      ..color = accent.withValues(alpha: 0.40)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, sw * 1.5),
  );
}

/// The completed state's subtle lighter internal highlight — a soft radial
/// white wash near the glyph's upper-left, clipped to the silhouette so it
/// reads as light on the filled shape, not a separate mark.
void _innerHighlight(Canvas canvas, Path path, {double strength = 1.0}) {
  final b = path.getBounds();
  final hl = Offset(b.left + b.width * 0.36, b.top + b.height * 0.30);
  final r = b.shortestSide * 0.62;
  canvas.save();
  canvas.clipPath(path);
  canvas.drawCircle(
    hl,
    r,
    Paint()
      ..shader = RadialGradient(colors: [
        Colors.white.withValues(alpha: 0.34 * strength),
        Colors.white.withValues(alpha: 0.0),
      ]).createShader(Rect.fromCircle(center: hl, radius: r)),
  );
  canvas.restore();
}

/// The full shared treatment for a single-silhouette glyph: contact shadow,
/// then either the outline stroke (inactive) or bloom + accent fill +
/// internal highlight + same-geometry stroke (completed — the stroke is kept
/// in both states so the optical size never changes between them).
void _paintSilhouette(
    Canvas canvas, Path path, Color accent, double sw,
    {required bool filled}) {
  _groundShadow(canvas, path, sw, filled: filled);
  if (filled) {
    _bloom(canvas, path, accent, sw);
    canvas.drawPath(path, Paint()..color = accent);
    _innerHighlight(canvas, path);
  }
  canvas.drawPath(path, _strokePaint(accent, sw));
}

/// A four-point sparkle (concave-sided star) — the shared "Ayma intelligence"
/// mark the Web-search and Match glyphs both carry, so it reads as one
/// recurring motif rather than two ad-hoc decorations. Small enough that it
/// is drawn solid in BOTH states (a stroked star this tiny would clog); the
/// completed state brightens it slightly via [_paintSparkle]'s `filled` tint.
Path _sparklePath(Offset c, double r) {
  return Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx + r * 0.18, c.dy - r * 0.18, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx + r * 0.18, c.dy + r * 0.18, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx - r * 0.18, c.dy + r * 0.18, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx - r * 0.18, c.dy - r * 0.18, c.dx, c.dy - r)
    ..close();
}

void _paintSparkle(Canvas canvas, Offset c, double r, Color accent, double sw,
    {required bool filled}) {
  final path = _sparklePath(c, r);
  _groundShadow(canvas, path, sw * 0.6, filled: true);
  if (filled) _bloom(canvas, path, accent, sw * 0.8);
  canvas.drawPath(
      path, Paint()..color = filled ? _tint(accent, 0.22) : accent);
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

  /// The live selected accent colour (`context.ac.accent`) — never a literal.
  final Color accent;

  /// `true` = the action already happened: the SAME geometry, solid accent
  /// fill, subtle internal highlight, small tight bloom. `false` = not yet:
  /// the clean stroked outline.
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
// 1. LIKE — one heart. Outline → solid accent heart with a lighter internal
// highlight and a very restrained accent glow.
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
// Outline → solid accent fill with the same subtle internal highlight.
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
// the upper-right marking it as Ayma-run research. Outline lens → filled/
// brighter lens; the sparkle stays in both states.
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
      _bloom(canvas, lens, accent, sw);
      canvas.drawPath(lens, Paint()..color = accent);
      // Slightly quieter than the family default on this one silhouette — a
      // full-strength round highlight on a plain disc starts reading as a
      // glossy balloon rather than a brighter magnifier.
      _innerHighlight(canvas, lens, strength: 0.75);
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
// 4. MATCH (compatibility score) — two elegant overlapping hearts, their
// venn-style overlap subtly echoing the Ayma orb's overlapping-petal
// language, with the same small sparkle above-right. Outline pair → both
// filled, the overlap slightly luminous, restrained glow.
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
    // middle — a genuine venn overlap (both outlines complete, crossing),
    // the same translucent-overlap read as the orb's petals.
    final back = _heartPathIn(Rect.fromLTWH(w * 0.03, h * 0.17, w * 0.56, h * 0.56));
    final front = _heartPathIn(Rect.fromLTWH(w * 0.38, h * 0.40, w * 0.56, h * 0.56));
    final union = Path.combine(PathOperation.union, back, front);
    final overlap = Path.combine(PathOperation.intersect, back, front);

    _groundShadow(canvas, union, sw, filled: filled);

    if (filled) {
      _bloom(canvas, union, accent, sw);
      canvas.drawPath(union, Paint()..color = accent);
      // The overlap centre glows slightly luminous — the one place the two
      // filled hearts visibly interpenetrate, echoing petal translucency.
      canvas.drawPath(
          overlap, Paint()..color = _tint(accent, 0.30).withValues(alpha: 0.9));
      _innerHighlight(canvas, union, strength: 0.8);
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
