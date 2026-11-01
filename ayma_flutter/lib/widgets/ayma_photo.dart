import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

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

  /// Test seam: the cache manager backing the [CachedNetworkImage]. Production
  /// leaves this null and uses the shared [DefaultCacheManager] (the same disk
  /// cache every photo in the app fills). Widget tests inject a fake that
  /// serves a local fixture file, so the real decode pipeline runs with no
  /// platform channels, no sqflite database, and no network.
  @visibleForTesting
  static BaseCacheManager? debugCacheManager;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _fallback(context);
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    final px = (displayWidth * dpr).round().clamp(48, 2000);
    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: debugCacheManager,
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

/// Best-effort decode prefetch for upcoming card photos (Phase 2 pagination
/// design §4.3): warms the image cache for the first [count] non-empty [urls]
/// at [displayWidth] so cards scrolling into view paint without blank tiles.
/// Silent on failure — a missed prefetch just falls back to normal loading.
/// Honors [AymaPhoto.debugCacheManager] so widget tests stay offline.
Future<void> prefetchCardPhotos(
  BuildContext context,
  Iterable<String?> urls, {
  double displayWidth = 260,
  int count = 8,
}) async {
  final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
  final px = (displayWidth * dpr).round().clamp(48, 2000);
  final cm = AymaPhoto.debugCacheManager;
  // Resize-on-fetch needs an ImageCacheManager; a plain test fake gets the
  // unresized bytes (prefetch still warms the same cache entry Discord).
  final sized = cm == null || cm is ImageCacheManager;
  final pending = <Future<void>>[];
  for (final url in urls.where((u) => u != null && u.isNotEmpty).take(count)) {
    final provider = CachedNetworkImageProvider(
      url!,
      maxWidth: sized ? px : null,
      cacheManager: cm,
    );
    pending.add(precacheImage(provider, context).then((_) {}).catchError((_) {}));
  }
  if (pending.isNotEmpty) await Future.wait(pending);
}
