import 'package:flutter/material.dart';

/// The staggered fade + slide-up entrance used across the app (§14.1). Wrap a
/// list item in [FadeSlideIn] with an index-derived [delay]; it animates once,
/// on first build, then holds.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 12,
    this.duration = const Duration(milliseconds: 320),
  });

  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final totalMs = delay.inMilliseconds + duration.inMilliseconds;
    final d = delay.inMilliseconds / totalMs;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: totalMs),
      curve: Curves.linear,
      builder: (context, t, child) {
        // Hold invisible for the `delay` fraction, then ease in the rest.
        final raw = t <= d ? 0.0 : ((t - d) / (1 - d)).clamp(0.0, 1.0);
        final p = Curves.easeOutCubic.transform(raw);
        return Opacity(
          opacity: p,
          child: Transform.translate(
            offset: Offset(0, offset * (1 - p)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// [FadeSlideIn] delay for the item at [index] — ramps up then caps so long
/// lists don't animate for seconds.
Duration staggerDelay(int index, {int stepMs = 40, int maxMs = 320}) =>
    Duration(milliseconds: (index * stepMs).clamp(0, maxMs));
