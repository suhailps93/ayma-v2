import 'package:flutter/material.dart';

/// Ayma's own action-rail icon language (founder spec, 2026-09-15/2026-09-22)
/// — replacing the generic Material icons the public-profile action rail
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
///
/// ---------------------------------------------------------------------
/// 2026-09-22, 3rd-round rendering rewrite ("so out of place... does not
/// match the vibe of the app"). Diagnosis, from direct-image comparison
/// against `AymaOrbPainter` (the app's one real signature visual — soft,
/// rounded, translucent glass petals) and against how this exact glyph set
/// already reads *well* elsewhere (`notification_center_screen.dart`'s
/// `_Leading`, always `filled: true`, small, inside a card-colour circle):
/// the "not done" state was the actual problem. It drew a bare stroked
/// outline — flat, single-width, single-tone, no gradient, no light — which
/// is a completely different rendering *grammar* from the orb (which never
/// once strokes a line; it is fills, gradients and soft light, always) and
/// from every other filled-glass surface in the app. Since a viewer sees the
/// "not done" state on almost every rail button most of the time (most
/// profiles aren't already liked/chatted/searched/matched), that flat
/// stroke *was* the rail's dominant visual impression — reading as generic
/// clip-art regardless of how much glass polish the "done" state carried.
/// The "done" state's own glow was also a tell: `_glowPath`/`_glowCircle`
/// blurred a copy of the exact same silhouette behind itself, which is a
/// drop-shadow trick, not light — `AymaOrbPainter` never does this; its own
/// external glow is a soft `RadialGradient` disc fading to transparent.
///
/// Fix: both states now render through the same filled-glass technique
/// (below), borrowed directly from `AymaOrbPainter`'s own layering —
/// gradient fill, `richDeepen`'s HSV-based rich-shadow toning (not a flat
/// lerp-to-black, which stays desaturated no matter how far it's pushed), a
/// diagonal bright rim sweep standing in for the orb's rim-light arc, a
/// soft diffused specular blob, and a genuine ambient `RadialGradient` glow
/// — never a stroke, never a blurred silhouette copy. "Not done" and "done"
/// differ in *tone* (a paler, quieter frosted glass vs. a fuller, richer,
/// glowing one) exactly the way the orb itself varies by state
/// (`_StateParams.brightness`/`ringOpacity`), not in rendering technique.
class AymaGlyphs {
  const AymaGlyphs._();
}

/// Lightens [c] toward white by fraction [t] (0..1).
Color tintAccent(Color c, double t) => Color.lerp(c, Colors.white, t)!;

/// Darkens [c] toward black by fraction [t] (0..1).
Color shadeAccent(Color c, double t) => Color.lerp(c, Colors.black, t)!;

/// A richer, more saturated darkening than [shadeAccent]: lerping straight
/// toward black keeps HSV saturation constant, which reads as a flat,
/// desaturated grey-tinge rather than "deeper glass". Pushing saturation up
/// *and* value down (in HSV space) is the exact technique
/// `AymaOrbPainter._richDeepen` uses for its own sphere's lower shadow —
/// ported here so a glyph's shaded stop reads as the same material.
Color richDeepen(Color c, double amt) {
  final hsv = HSVColor.fromColor(c);
  final sat =
      (hsv.saturation + (1 - hsv.saturation) * amt * 0.7).clamp(0.0, 1.0);
  final val = (hsv.value * (1 - amt * 0.55)).clamp(0.0, 1.0);
  return hsv.withSaturation(sat).withValue(val).toColor();
}

// ---------------------------------------------------------------------------
// Shared glass-rendering helpers — every glyph below is built from these, so
// "not done" and "done" are the same material at different intensities, and
// every glyph reads as one family rather than four independently-styled
// icons. Directly modelled on `AymaOrbPainter`'s own layers: ambient glow
// (its external soft-glow disc), rich gradient fill (its sphere-base
// radial), a diagonal bright sweep (its rim-light arc, adapted for an
// arbitrary silhouette rather than a circle), and a diffused specular blob
// (its glassy catchlight) — never a stroke, never a blurred-copy shadow.
// ---------------------------------------------------------------------------

/// Soft ambient light bleeding out from a glyph's own bounds — a diffused
/// `RadialGradient` disc fading to nothing, the same construction
/// `AymaOrbPainter` uses for its external glow. Deliberately *not* a blurred
/// copy of the glyph's silhouette (the old `_glowPath`/`_glowCircle`
/// technique) — that reads as a drop-shadow sitting behind a flat sticker;
/// this reads as the shape itself giving off light.
void _ambientGlow(Canvas canvas, Rect bounds, Color accent,
    {required double strength}) {
  if (strength <= 0.01) return;
  final center = bounds.center;
  final r = bounds.longestSide * 0.82;
  canvas.drawCircle(
    center,
    r,
    Paint()
      ..shader = RadialGradient(colors: [
        accent.withValues(alpha: (0.50 * strength).clamp(0, 1)),
        accent.withValues(alpha: 0),
      ]).createShader(Rect.fromCircle(center: center, radius: r)),
  );
}

/// A quiet, neutral contact shadow directly behind the glyph — small and
/// low-alpha, present in both states. Not the glyph's colour story (that's
/// [_ambientGlow]'s job); purely the "this is a floating object, not part of
/// the photo" depth cue a real elevated button needs, since these glyphs
/// carry no card/disc of their own to imply elevation the way one would.
void _contactShadow(Canvas canvas, Path path, {required double radius}) {
  canvas.save();
  canvas.translate(0, radius * 0.35);
  canvas.drawPath(
    path,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.32)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius),
  );
  canvas.restore();
}

/// Fills [path] with the shared glass gradient — paler/quieter when `!filled`
/// (the "not done" frosted-glass read), fuller/richer when `filled` (the
/// "done" saturated-glass read) — plus a diagonal bright sweep standing in
/// for the orb's rim-light arc (a `LinearGradient`-shaded stroke, bright at
/// the upper-left, fading to nothing by the lower-right, rather than a
/// uniform all-around outline) and a soft diffused specular blob. Shared by
/// every glyph below so "not done" vs "done" is one material at two
/// intensities, never two different rendering techniques.
void _glassFillPath(Canvas canvas, Path path, Color accent,
    {required bool filled}) {
  final bounds = path.getBounds();
  final side = bounds.shortestSide;

  _contactShadow(canvas, path, radius: side * 0.10);
  _ambientGlow(canvas, bounds, accent, strength: filled ? 1.0 : 0.16);

  final fillAlpha = filled ? 1.0 : 0.82;
  canvas.drawPath(
    path,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          tintAccent(accent, filled ? 0.46 : 0.64)
              .withValues(alpha: fillAlpha),
          accent.withValues(alpha: fillAlpha * (filled ? 1.0 : 0.88)),
          richDeepen(accent, filled ? 1.0 : 0.35)
              .withValues(alpha: fillAlpha),
        ],
        stops: const [0, 0.52, 1],
      ).createShader(bounds),
  );

  _rimSweep(canvas, path, bounds, strength: filled ? 1.0 : 0.6);
  _specular(canvas, bounds, strength: filled ? 1.0 : 0.55);
}

/// The diagonal bright sweep along a glyph's own edge — a `LinearGradient`
/// applied to the *stroke* paint (bright near the top-left, transparent by
/// the bottom-right), the same "light catching one side of the glass" idea
/// as the orb's rim-light arc, adapted for a closed silhouette instead of a
/// circle (an arc needs a circle to sweep around; a gradient across the
/// stroke's own bounds reads the same way on any shape).
void _rimSweep(Canvas canvas, Path path, Rect bounds,
    {required double strength}) {
  final side = bounds.shortestSide;
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (side * 0.05).clamp(0.6, 3.2)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, side * 0.015)
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.75 * strength),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0, 0.65],
      ).createShader(bounds),
  );
}

/// A soft diffused highlight blob — never a hard bright dot (the orb's own
/// doc explicitly calls a hard catchlight "a sticker/cartoon eye glint");
/// this stays feathered all the way to its own centre, just brighter there.
void _specular(Canvas canvas, Rect bounds, {required double strength}) {
  final hl =
      Offset(bounds.left + bounds.width * 0.34, bounds.top + bounds.height * 0.30);
  final r = bounds.shortestSide * 0.34;
  canvas.drawCircle(
    hl,
    r,
    Paint()
      ..shader = RadialGradient(colors: [
        Colors.white.withValues(alpha: 0.60 * strength),
        Colors.white.withValues(alpha: 0.14 * strength),
        Colors.white.withValues(alpha: 0),
      ], stops: const [
        0,
        0.55,
        1,
      ]).createShader(Rect.fromCircle(center: hl, radius: r)),
  );
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

  /// `true` = fuller, richer, glowing "done" glass. `false` = a paler,
  /// quieter "not done" frosted glass — the *same* filled-glass rendering at
  /// lower intensity, not a different (stroked-outline) technique.
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
    _glassFillPath(canvas, _heartPath(size), accent, filled: filled);
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
    _glassFillPath(canvas, _chatPath(size), accent, filled: filled);
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
    final handleStart = center + Offset(r * 0.70, r * 0.70);
    final handleEnd = Offset(w * 0.88, h * 0.90);
    final sparkleCenter = Offset(w * 0.80, h * 0.20);
    final sparkleR = w * 0.17;
    final strokeW = size.shortestSide * (filled ? 0.11 : 0.095);

    // Overall bounds (glass + handle + sparkle) drive the shared ambient
    // glow/contact-shadow so they read as one glowing object, not three.
    final overallBounds = Rect.fromPoints(
      center - Offset(r, r),
      Offset(w, h),
    );
    _contactShadow(
      canvas,
      Path()..addOval(Rect.fromCircle(center: center, radius: r)),
      radius: w * 0.05,
    );
    _ambientGlow(canvas, overallBounds, accent, strength: filled ? 1.0 : 0.16);

    final fillAlpha = filled ? 1.0 : 0.80;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.35),
          colors: [
            tintAccent(accent, filled ? 0.55 : 0.68)
                .withValues(alpha: fillAlpha),
            accent.withValues(alpha: fillAlpha),
            richDeepen(accent, filled ? 1.0 : 0.4)
                .withValues(alpha: fillAlpha),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
    _rimSweep(
      canvas,
      Path()..addOval(Rect.fromCircle(center: center, radius: r)),
      Rect.fromCircle(center: center, radius: r),
      strength: filled ? 1.0 : 0.6,
    );

    // Handle — same glass tone as the glass itself, softly rounded, rather
    // than a bare flat-coloured line.
    canvas.drawLine(
      handleStart,
      handleEnd,
      Paint()
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..color = richDeepen(accent, filled ? 0.55 : 0.15)
            .withValues(alpha: fillAlpha),
    );

    _specular(canvas, Rect.fromCircle(center: center, radius: r),
        strength: filled ? 1.0 : 0.5);

    // Sparkle — a small soft-filled glass shape (never a flat dot), same
    // material family as the rest of the glyph.
    final sparklePath = _sparklePath(sparkleCenter, sparkleR);
    canvas.drawPath(
      sparklePath,
      Paint()
        ..shader = RadialGradient(colors: [
          tintAccent(accent, filled ? 0.55 : 0.72)
              .withValues(alpha: fillAlpha),
          richDeepen(accent, filled ? 0.7 : 0.25).withValues(alpha: fillAlpha),
        ]).createShader(sparklePath.getBounds()),
    );
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
    final fillAlpha = filled ? 1.0 : 0.80;

    final overallBounds = Rect.fromLTRB(
      leftHead.dx - headR,
      rightHead.dy - headR,
      rightHead.dx + headR,
      h * 0.90,
    );
    final combined = Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, rightLobe, leftLobe),
      Path.combine(
        PathOperation.union,
        Path()..addOval(Rect.fromCircle(center: rightHead, radius: headR)),
        Path()..addOval(Rect.fromCircle(center: leftHead, radius: headR)),
      ),
    );
    _contactShadow(canvas, combined, radius: w * 0.06);
    _ambientGlow(canvas, overallBounds, accent, strength: filled ? 1.0 : 0.16);

    // Each lobe painted as its own soft accent-tinted glass fill — where
    // they overlap near the shared bottom point, the alpha compositing
    // itself produces the richer "translucent overlap" tone the spec asks
    // for, without a second hardcoded colour.
    canvas.drawPath(
      rightLobe,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            tintAccent(accent, filled ? 0.45 : 0.64)
                .withValues(alpha: fillAlpha),
            richDeepen(accent, filled ? 0.4 : 0.15)
                .withValues(alpha: fillAlpha),
          ],
        ).createShader(rightLobe.getBounds()),
    );
    canvas.drawPath(
      leftLobe,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tintAccent(accent, filled ? 0.30 : 0.58)
                .withValues(alpha: fillAlpha),
            richDeepen(accent, filled ? 0.55 : 0.2)
                .withValues(alpha: fillAlpha),
          ],
        ).createShader(leftLobe.getBounds()),
    );
    _rimSweep(canvas, rightLobe, rightLobe.getBounds(),
        strength: filled ? 1.0 : 0.55);
    _rimSweep(canvas, leftLobe, leftLobe.getBounds(),
        strength: filled ? 1.0 : 0.55);

    for (final c in [leftHead, rightHead]) {
      canvas.drawCircle(
        c,
        headR,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.4),
            colors: [
              tintAccent(accent, filled ? 0.5 : 0.68)
                  .withValues(alpha: fillAlpha),
              richDeepen(accent, filled ? 0.5 : 0.15)
                  .withValues(alpha: fillAlpha),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: headR)),
      );
      _rimSweep(
        canvas,
        Path()..addOval(Rect.fromCircle(center: c, radius: headR)),
        Rect.fromCircle(center: c, radius: headR),
        strength: filled ? 1.0 : 0.55,
      );
    }

    // Small shared specular highlight, echoing the orb's glass glint.
    _specular(canvas, overallBounds, strength: filled ? 1.0 : 0.5);
  }

  @override
  bool shouldRepaint(covariant _MatchPainter old) =>
      old.accent != accent || old.filled != filled;
}
