import 'package:flutter/material.dart';

import '../env.dart';

/// Renders a visible STAGING corner ribbon over [child] when running in the
/// staging build configuration (`--dart-define=ENV=staging`).
///
/// In production ([Env.isStaging] is false and [enabled] is not explicitly true),
/// [child] is returned directly without any extra widget overhead or
/// visual change.
class StagingBanner extends StatelessWidget {
  const StagingBanner({
    super.key,
    required this.child,
    this.enabled,
    this.message = 'STAGING',
    this.location = BannerLocation.topEnd,
    this.color = const Color(0xFFE65100),
  });

  final Widget child;

  /// Optional override for testing. Defaults to [Env.isStaging].
  final bool? enabled;

  /// Text displayed inside the banner ribbon.
  final String message;

  /// Corner location for the ribbon. Defaults to [BannerLocation.topEnd].
  final BannerLocation location;

  /// Background color for the ribbon. Defaults to distinct staging amber/orange.
  final Color color;

  @override
  Widget build(BuildContext context) {
    final show = enabled ?? Env.isStaging;
    if (!show) return child;

    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: Banner(
        message: message,
        location: location,
        color: color,
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.0,
          height: 1.0,
        ),
        child: child,
      ),
    );
  }
}
