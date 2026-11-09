import 'package:flutter/material.dart';

import '../theme.dart';

/// A thin horizontal bar visualizing `value` against `max` as a filled
/// fraction of the track.
///
/// Two visual modes, chosen by whether [colorFor] is given:
/// - Flat (default): a single fill color ([color], defaulting to the theme
///   accent) — used where the score is not meant to read as a judgment
///   (e.g. a beauty/physique rating on Face/Body reports).
/// - Banded: [colorFor] computes the fill color per value (e.g. green/amber/
///   red) — used where the bar should let a user gauge quality at a glance
///   (e.g. Match report compatibility dimensions).
///
/// `value`/`max` are not pre-normalized by callers — pass the raw score and
/// its scale (e.g. `ScoreBar(value: 7.1, max: 10)` or
/// `ScoreBar(value: 62, max: 100)`).
class ScoreBar extends StatelessWidget {
  const ScoreBar({
    super.key,
    required this.value,
    this.max = 10,
    this.height = 8,
    this.color,
    this.trackColor,
    this.colorFor,
  });

  /// The current score, on a scale of [0, max].
  final double value;

  /// The upper bound of the scale `value` is measured against.
  final double max;

  /// Bar thickness.
  final double height;

  /// Flat fill color, used when [colorFor] is not given. Defaults to the
  /// theme accent color.
  final Color? color;

  /// Track (unfilled) color. Defaults to the theme's soft line color.
  final Color? trackColor;

  /// When given, computes the fill color from `value`/`max` (banded mode)
  /// instead of using a flat [color].
  final Color Function(BuildContext context, double value, double max)?
      colorFor;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    final fill = colorFor != null
        ? colorFor!(context, value, max)
        : (color ?? ac.accent);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(
        children: [
          Container(height: height, color: trackColor ?? ac.lineSoft),
          FractionallySizedBox(
            widthFactor: frac,
            child: Container(height: height, color: fill),
          ),
        ],
      ),
    );
  }
}
