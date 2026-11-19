import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Display widths at or below this are served the backend's 400px `thumb_400`
/// variant (grid cards, avatars, small thumbnails), so they are cached as the
/// plain downloaded file rather than being resized on the fly. Above it (full
/// image viewers, profile headers) the on-disk resize still caps what's stored
/// and decoded.
///
/// Why it matters (PC8): a non-null `maxWidthDiskCache` routes the fetch
/// through `flutter_cache_manager`'s [ImageCacheManager.getImageFile] resize
/// path, tracked in its `_runningResizes` map. When that download/resize
/// stream stalls (rapid fling / prefetch under network jitter) the tile stays
/// on its blank placeholder indefinitely — and returning to the screen
/// re-attaches to the same hung in-memory stream instead of refetching.
/// Leaving `maxWidthDiskCache` null short-circuits `getImageFile` to the plain
/// [BaseCacheManager.getFileStream] download, which never enters that map;
/// `memCacheWidth` still caps the in-memory decode.
const double _kDiskResizeThreshold = 400;

/// If no frame has painted within this window while the placeholder is showing,
/// [AymaPhoto] treats the stream as stalled. The FIRST stalls are transient —
/// a cold-start backend or a grid of full-size downloads under network
/// contention — so rather than giving up permanently it re-attempts (see
/// [_kStallRetryDelay] / [_kMaxStallRetries]); only once the retries are spent
/// does it render its error fallback, so a card never sticks on the blank
/// placeholder forever (PC8) yet also self-heals once the network frees (Scout
/// NOTE 268 Leg 2 — Explore tiles stuck on initials for 25+ min, and the
/// NOTE 266/267 hero that "settled only after a scroll" re-mounted it).
const Duration _kStallTimeout = Duration(seconds: 10);

/// After a stall, wait this long before re-attempting the load (letting a cold
/// backend warm / the download queue drain) instead of bricking the tile.
const Duration _kStallRetryDelay = Duration(seconds: 3);

/// How many times a stalled tile re-attempts on its own before it finally falls
/// back to the error widget. Bounded so a genuinely-broken URL can't churn
/// forever — worst case ~36s (10s + 3s) × attempts to the terminal fallback.
const int _kMaxStallRetries = 2;

/// A network photo with disk caching, a decode/store cap, and a gentle fade —
/// so a photo that's been seen once (Explore card, profile, match report,
/// chat) shows instantly and never pops in blank.
///
/// [displayWidth] is the on-screen width in logical pixels; the image is
/// decoded (and, above [_kDiskResizeThreshold], cached on disk) at roughly
/// that size (× devicePixelRatio), which is the main lever on how much is
/// downloaded/held for list-heavy screens like Explore.
class AymaPhoto extends StatefulWidget {
  const AymaPhoto({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.displayWidth = 1000,
    this.placeholderColor,
    this.placeholderUrl,
    this.error,
    this.width,
    this.height,
  });

  final String url;
  final BoxFit fit;
  final double displayWidth;
  final Color? placeholderColor;

  /// Progressive-load hint: a small low-res variant of [url] (a `thumb_400`)
  /// painted *under* the full-res fade while the large image downloads, so a
  /// cold full-size photo (the profile hero) never shows as a flat dark tile.
  /// Null (every caller but the hero) keeps the plain flat placeholder. Ignored
  /// when empty or equal to [url] — a same-URL "thumb" would only wait on the
  /// very download it is meant to cover.
  final String? placeholderUrl;
  final Widget? error;
  final double? width;
  final double? height;

  /// Test seam: the cache manager backing the [CachedNetworkImage]. Production
  /// leaves this null and uses the shared [DefaultCacheManager] (the same disk
  /// cache every photo in the app fills). Widget tests inject a fake that
  /// serves a local fixture file, so the real decode pipeline runs with no
  /// platform channels, no sqflite database, and no network.
  @visibleForTesting
  static BaseCacheManager? debugCacheManager;

  @override
  State<AymaPhoto> createState() => _AymaPhotoState();
}

class _AymaPhotoState extends State<AymaPhoto> {
  Timer? _stallTimer;
  bool _stalled = false;
  bool _settled = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Bumped on each self-heal re-attempt after a stall; also the suffix of the
  /// [CachedNetworkImage] key so a re-attempt mounts a FRESH element and
  /// re-fetches, rather than re-attaching to the same hung stream.
  int _stallAttempt = 0;

  bool get _diskResize => widget.displayWidth > _kDiskResizeThreshold;

  int _px() {
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    return (widget.displayWidth * dpr).round().clamp(48, 2000);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(covariant AymaPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.displayWidth != widget.displayWidth) {
      _stallTimer?.cancel();
      _detachListener();
      _stalled = false;
      _settled = false;
      _stallAttempt = 0;
      _attach();
    }
  }

  /// Watches the exact [ImageStream] the [CachedNetworkImage] below resolves —
  /// same key: `ResizeImage(memCacheWidth)` wrapping a
  /// [CachedNetworkImageProvider] with the same `maxWidth` — so when the real
  /// render loads or errors we cancel the stall timer, and when it hangs the
  /// timer fires and flips to the error fallback. Shares the in-memory cache
  /// entry, so this adds a listener, not a second download.
  void _attach() {
    if (widget.url.isEmpty || _settled || _stalled) return;
    final px = _px();
    final ImageProvider effective = ResizeImage.resizeIfNeeded(
      px,
      null,
      CachedNetworkImageProvider(
        widget.url,
        maxWidth: _diskResize ? px : null,
        cacheManager: AymaPhoto.debugCacheManager,
      ),
    );
    final stream = effective.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (_, __) => _onSettled(),
      onError: (_, __) => _onSettled(),
    );
    _detachListener();
    _stream = stream..addListener(listener);
    _listener = listener;
    _stallTimer?.cancel();
    _stallTimer = Timer(_kStallTimeout, _onStall);
  }

  void _onSettled() {
    if (!mounted) return;
    _settled = true;
    _stallTimer?.cancel();
  }

  void _onStall() {
    if (!mounted || _settled) return;
    if (_stallAttempt < _kMaxStallRetries) {
      // Transient stall (cold-start backend, or the Explore grid pulling many
      // full-size originals at once under contention). Don't give up: detach
      // the hung stream, wait a beat, then re-attach with a bumped attempt so
      // the CachedNetworkImage key changes and a FRESH fetch is issued — the
      // tile self-heals once the network frees instead of sticking on the
      // fallback until it's scrolled away and back (Scout NOTE 268 Leg 2; the
      // NOTE 266/267 hero that only "settled after a scroll" is the same
      // re-mount, now automatic).
      _stallAttempt++;
      _detachListener();
      _stallTimer?.cancel();
      _stallTimer = Timer(_kStallRetryDelay, () {
        if (!mounted || _settled) return;
        setState(_attach);
      });
      return;
    }
    setState(() => _stalled = true);
  }

  void _detachListener() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    _detachListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) return _fallback(context);
    if (_stalled) return widget.error ?? _fallback(context);
    final px = _px();
    return CachedNetworkImage(
      // The attempt suffix makes a post-stall re-attempt rebuild this as a
      // fresh element (new ImageStream subscription) rather than re-binding to
      // the stalled one — so the self-heal in [_onStall] actually re-fetches.
      key: ValueKey('${widget.url}@$_stallAttempt'),
      imageUrl: widget.url,
      width: widget.width,
      height: widget.height,
      cacheManager: AymaPhoto.debugCacheManager,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 180),
      memCacheWidth: px,
      maxWidthDiskCache: _diskResize ? px : null,
      placeholder: (_, __) => _placeholder(context),
      errorWidget: (_, __, ___) => widget.error ?? _fallback(context),
    );
  }

  Widget _placeholder(BuildContext context) {
    final flat = Container(
      width: widget.width,
      height: widget.height,
      color: widget.placeholderColor ??
          Theme.of(context).colorScheme.surfaceContainerHighest,
    );
    final low = widget.placeholderUrl;
    if (low == null || low.isEmpty || low == widget.url) return flat;
    // The thumb variant is small (fast to fetch cold, usually already on disk
    // from the filmstrip/grid), so it fills the gap while the full-res loads
    // and the real image fades in over it. Kept on the plain download path
    // (`maxWidthDiskCache` null — see PC8) and falling back to the flat tile if
    // it can't load, so the placeholder can never itself stall a tile.
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    final thumbPx = (_kDiskResizeThreshold * dpr).round().clamp(48, 2000);
    return CachedNetworkImage(
      imageUrl: low,
      width: widget.width,
      height: widget.height,
      cacheManager: AymaPhoto.debugCacheManager,
      fit: widget.fit,
      fadeInDuration: Duration.zero,
      memCacheWidth: thumbPx,
      placeholder: (_, __) => flat,
      errorWidget: (_, __, ___) => flat,
    );
  }

  Widget _fallback(BuildContext context) => Container(
        width: widget.width,
        height: widget.height,
        color: widget.placeholderColor ??
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
  // Match AymaPhoto's effective ImageProvider key exactly so a prefetch warms
  // the very entry the card resolves. CachedNetworkImageProvider `==` includes
  // maxWidth, and OctoImage wraps the provider in ResizeImage(memCacheWidth):
  //  - disk resize only above the thumb threshold (grid/avatar stay null,
  //    matching AymaPhoto) — and only with an ImageCacheManager, else
  //    cached_network_image asserts on a resize it can't perform;
  //  - the ResizeImage(px) in-memory decode wrap is always applied.
  final diskResize = displayWidth > _kDiskResizeThreshold &&
      (cm == null || cm is ImageCacheManager);
  final pending = <Future<void>>[];
  for (final url in urls.where((u) => u != null && u.isNotEmpty).take(count)) {
    final ImageProvider provider = ResizeImage.resizeIfNeeded(
      px,
      null,
      CachedNetworkImageProvider(
        url!,
        maxWidth: diskResize ? px : null,
        cacheManager: cm,
      ),
    );
    pending.add(precacheImage(provider, context).then((_) {}).catchError((_) {}));
  }
  if (pending.isNotEmpty) await Future.wait(pending);
}
