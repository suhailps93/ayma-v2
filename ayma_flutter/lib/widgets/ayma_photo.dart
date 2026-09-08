import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// A network photo with disk caching, a decode/store cap, and a gentle fade —
/// so a photo that's been seen once (Explore card, profile, match report,
/// chat) shows instantly and never pops in blank.
///
/// [displayWidth] is the on-screen width in logical pixels; the image is
/// decoded and cached on disk at roughly that size (× devicePixelRatio),
/// which is the main lever on how much is downloaded/held for list-heavy
/// screens like Explore.
class AymaPhoto extends StatelessWidget {
  const AymaPhoto({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.displayWidth = 1000,
    this.placeholderColor,
    this.error,
  });

  final String url;
  final BoxFit fit;
  final double displayWidth;
  final Color? placeholderColor;
  final Widget? error;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _fallback(context);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    final px = (displayWidth * dpr).round().clamp(48, 2000);
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 180),
      memCacheWidth: px,
      maxWidthDiskCache: px,
      placeholder: (_, __) => _placeholder(context),
      errorWidget: (_, __, ___) => error ?? _fallback(context),
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        color: placeholderColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
      );

  Widget _fallback(BuildContext context) => Container(
        color: placeholderColor ??
            Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: Icon(Icons.image_not_supported_outlined,
            color: Theme.of(context).colorScheme.outline, size: 20),
      );
}
