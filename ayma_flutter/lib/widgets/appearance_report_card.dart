import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/appearance_card.dart';
import '../theme.dart';

/// The shareable Appearance report card (founder-approved design B,
/// "collage"): a fixed 360x640 logical-pixel (9:16) layout so the on-screen
/// card and the exported 1080x1920 PNG (`report_card_share.dart`, 3x) are
/// pixel-for-pixel the same picture.
///
/// Draws only what is safe to share: the analysed photos, the Face and Body
/// scores with their verdicts, and positive findings ([AppearanceCardData]
/// already filters those). Recommendations never appear here.
///
/// Its own colours are fixed (a light paper card in either app theme); the
/// live [accent] is used for the glow, the mark, the Face sticker and the
/// accent text, darkened where needed so text keeps WCAG AA contrast on the
/// paper for any accent the user picks.
class AppearanceReportCard extends StatelessWidget {
  const AppearanceReportCard({
    super.key,
    required this.data,
    required this.name,
    required this.accent,
    required this.photos,
  });

  static const width = 360.0;
  static const height = 640.0;
  static const size = Size(width, height);

  final AppearanceCardData data;

  /// The user's first name; "You" when unknown.
  final String name;
  final Color accent;

  /// The photos that actually loaded, each with its accessibility label
  /// (never an empty frame for one that didn't).
  final List<(ImageProvider, String)> photos;

  static const _paper = ReportCardColors.paper;
  static const _ink = ReportCardColors.ink;
  static const _mute = ReportCardColors.mute;
  static const _dim = ReportCardColors.dim;
  static const _chipLine = ReportCardColors.chipLine;
  static const _rule = ReportCardColors.rule;
  static const _shadow = ReportCardColors.shadow;
  static const _peach = ReportCardColors.peach;

  /// Polaroid slots from the mock: left, top, width, height, degrees.
  static const _slots = [
    (18.0, 112.0, 188.0, 222.0, -3.5),
    (200.0, 104.0, 144.0, 166.0, 4.0),
    (208.0, 262.0, 136.0, 168.0, -2.5),
    (26.0, 328.0, 120.0, 124.0, 3.0),
  ];

  /// [accent] darkened (lightness only) until it reaches [minRatio] contrast
  /// against the card's paper.
  static Color inkAccent(Color accent, {double minRatio = 4.5}) {
    var hsl = HSLColor.fromColor(accent);
    var c = accent;
    while (contrast(c, _paper) < minRatio && hsl.lightness > 0) {
      hsl = hsl.withLightness(math.max(0, hsl.lightness - 0.04));
      c = hsl.toColor();
    }
    return c;
  }

  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  @override
  Widget build(BuildContext context) {
    final ink = inkAccent(accent);
    final mono = AymaType.mono(
      size: 9.5,
      color: _mute,
    ).copyWith(letterSpacing: 1.3);
    final serif = AymaType.serif(color: _ink);
    final verdicts = [
      if (data.faceVerdict.isNotEmpty)
        'Face: ${data.faceVerdict.toLowerCase()}',
      if (data.bodyVerdict.isNotEmpty)
        'Body: ${data.bodyVerdict.toLowerCase()}',
    ].join(' · ');

    return MediaQuery.withNoTextScaling(
      child: DefaultTextStyle(
        style: AymaType.sans(size: 12, color: _ink),
        child: SizedBox.fromSize(
          size: size,
          child: ClipRect(
            child: ColoredBox(
              color: _paper,
              child: Stack(
                children: [
                  _glow(
                    right: -80,
                    top: -70,
                    size: 280,
                    color: accent,
                    alpha: 0x44,
                  ),
                  _glow(
                    left: -100,
                    top: 330,
                    size: 260,
                    color: _peach,
                    alpha: 0x55,
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    top: 18,
                    child: Row(
                      children: [
                        _mark(22),
                        const SizedBox(width: 8),
                        Text(
                          'ayma',
                          style: serif.copyWith(fontSize: 22, height: 1),
                        ),
                        const Spacer(),
                        Text('APPEARANCE REPORT', style: mono),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    top: 50,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            key: const ValueKey('reportCardName'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: serif.copyWith(fontSize: 50, height: 1.05),
                          ),
                        ),
                        Text(
                          '.',
                          style: serif.copyWith(
                            fontSize: 50,
                            height: 1.05,
                            color: ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (var i = 0; i < photos.length && i < _slots.length; i++)
                    _polaroid(i),
                  _sticker(
                    left: 150,
                    top: 276,
                    size: 84,
                    angle: -6,
                    fill: accent,
                    text: AymaColors.onAccentFor(accent),
                    score: data.faceScore,
                    label: 'FACE',
                    scoreSize: 40,
                  ),
                  _sticker(
                    left: 146,
                    top: 368,
                    size: 78,
                    angle: 5,
                    fill: _ink,
                    text: Colors.white,
                    score: data.bodyScore,
                    label: 'BODY',
                    scoreSize: 36,
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    top: 476,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (data.standOuts.isNotEmpty)
                              Text(
                                'STANDS OUT',
                                style: mono.copyWith(color: ink),
                              ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                verdicts,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: AymaType.sans(size: 11, color: _dim),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 7,
                          runSpacing: 7,
                          children: [for (final s in data.standOuts) _chip(s)],
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 18,
                    child: Container(
                      padding: const EdgeInsets.only(top: 12),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: _rule)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      const TextSpan(
                                        text: 'Get your report on ',
                                      ),
                                      TextSpan(
                                        text: 'Ayma',
                                        style: TextStyle(color: ink),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  style: serif.copyWith(
                                    fontSize: 24,
                                    height: 1,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'AI estimates from photos. An opinion, not a fact.',
                                  maxLines: 1,
                                  style: AymaType.sans(size: 9, color: _mute),
                                ),
                              ],
                            ),
                          ),
                          _mark(30),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _glow({
    double? left,
    double? right,
    required double top,
    required double size,
    required Color color,
    required int alpha,
  }) => Positioned(
    left: left,
    right: right,
    top: top,
    width: size,
    height: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withAlpha(alpha), color.withAlpha(0)],
          stops: const [0, 0.66],
        ),
      ),
    ),
  );

  /// The Ayma mark: an accent orb with a soft highlight.
  Widget _mark(double d) {
    final deep = HSLColor.fromColor(accent);
    final shade = deep.withLightness(deep.lightness * 0.6).toColor();
    return SizedBox(
      width: d,
      height: d,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(0.2, 0.4),
            colors: [shade, accent],
            stops: const [0, 0.72],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.36, -0.44),
              colors: [
                ReportCardColors.highlight,
                ReportCardColors.highlight.withAlpha(0),
              ],
              stops: const [0, 0.38],
            ),
          ),
        ),
      ),
    );
  }

  Widget _polaroid(int i) {
    final (left, top, w, h, deg) = _slots[i];
    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: Transform.rotate(
        angle: deg * math.pi / 180,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: _shadow.withAlpha(0x33),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: _shadow.withAlpha(0x33),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Image(
              image: photos[i].$1,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              semanticLabel: photos[i].$2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sticker({
    required double left,
    required double top,
    required double size,
    required double angle,
    required Color fill,
    required Color text,
    required String score,
    required String label,
    required double scoreSize,
  }) => Positioned(
    left: left,
    top: top,
    width: size,
    height: size,
    child: Transform.rotate(
      angle: angle * math.pi / 180,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fill,
          boxShadow: [
            BoxShadow(
              color: fill.withAlpha(0x66),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              score,
              maxLines: 1,
              style: AymaType.serif(
                size: scoreSize,
                color: text,
              ).copyWith(height: 0.95),
            ),
            Text(
              label,
              style: AymaType.mono(
                size: 9,
                color: text,
              ).copyWith(letterSpacing: 1.1),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _chip(String text) => ConstrainedBox(
    // Two chips always fit a row, so four never take more than two rows.
    constraints: const BoxConstraints(maxWidth: 156),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: _chipLine),
        boxShadow: [
          BoxShadow(
            color: _shadow.withAlpha(0x1A),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AymaType.sans(size: 12, color: _ink),
      ),
    ),
  );
}
