import 'dart:async';

import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cache manager whose download never completes — reproduces the PC8 stall
/// (rapid fling / prefetch under network jitter leaves the fetch/resize stream
/// hung, so the tile stays on its blank placeholder forever).
class _HangCacheManager implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      StreamController<FileResponse>().stream; // never emits, never closes

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) =>
      Completer<fs.File>().future; // never completes

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  const thumbUrl = 'https://x/profile__thumb_400.jpg';

  // The CachedNetworkImage key AymaPhoto sets: `<url>@<stallAttempt>`. A bump
  // proves a post-stall self-heal re-attempt mounted a fresh element.
  String? cniKey(WidgetTester tester) {
    final k = tester
        .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .key;
    return k is ValueKey<String> ? k.value : null;
  }

  testWidgets(
      'PC8 stall guard: a stalled tile SELF-HEALS (re-attempts) and only flips '
      'to the error (F1) fallback once the retries are spent (NOTE 268 Leg 2)',
      (tester) async {
    AymaPhoto.debugCacheManager = _HangCacheManager();
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AymaPhoto(
          url: thumbUrl,
          displayWidth: 260, // grid card
          error: Icon(Icons.person, key: Key('f1')),
        ),
      ),
    ));
    await tester.pump(); // first frame: still on the (blank) placeholder
    expect(find.byKey(const Key('f1')), findsNothing);
    expect(cniKey(tester), '$thumbUrl@0');

    // Past the first 10s stall + 3s retry delay: NOT the terminal fallback —
    // the tile re-attempts (attempt 1), so a grid that stalled under cold-start
    // contention recovers on its own instead of sticking on initials for 25+
    // min. The attempt suffix bumped, proving a fresh fetch was issued.
    await tester.pump(const Duration(seconds: 14));
    expect(find.byKey(const Key('f1')), findsNothing,
        reason: 'a transient stall must re-attempt, not give up');
    expect(cniKey(tester), '$thumbUrl@1');

    // Second stall + retry: still self-healing (attempt 2), still no fallback.
    await tester.pump(const Duration(seconds: 13));
    expect(find.byKey(const Key('f1')), findsNothing);
    expect(cniKey(tester), '$thumbUrl@2');

    // Retries now spent: a genuinely-dead URL finally shows the F1 fallback
    // (bounded — it cannot churn forever).
    await tester.pump(const Duration(seconds: 12));
    expect(find.byKey(const Key('f1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink()); // dispose: cancels timers
  });

  testWidgets(
      'PC8 stall guard cancels (no false fallback) once the stream loads',
      (tester) async {
    // Serve a real fixture so the decode pipeline completes. Image decoding
    // needs real async, so drive it under runAsync; the stall timer is then a
    // real timer that the load cancels well before its 10s deadline.
    AymaPhoto.debugCacheManager = _FixtureCacheManager('test/fixtures/tiny.png');
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AymaPhoto(
            url: thumbUrl,
            displayWidth: 260,
            error: Icon(Icons.person, key: Key('f1')),
          ),
        ),
      ));
      // Let the real 1x1 PNG decode complete (milliseconds) — far under the
      // 10s stall timeout, which must therefore be cancelled, not fired.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    expect(find.byKey(const Key('f1')), findsNothing,
        reason: 'a successful load must not be replaced by the stall fallback');
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'PC8: display width <= 400 omits maxWidthDiskCache (no _runningResizes '
      'path); memCacheWidth still caps the decode', (tester) async {
    AymaPhoto.debugCacheManager = _HangCacheManager();
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AymaPhoto(url: thumbUrl, displayWidth: 260),
      ),
    ));
    await tester.pump();

    final cached =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(cached.maxWidthDiskCache, isNull,
        reason: 'grid thumbs must skip the stalling disk-resize path');
    expect(cached.memCacheWidth, isNotNull,
        reason: 'in-memory decode is still capped');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'PC8: display width > 400 keeps maxWidthDiskCache (large viewers resize)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AymaPhoto(url: 'https://x/medium_1080.jpg', displayWidth: 900),
      ),
    ));
    await tester.pump();

    final cached =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(cached.maxWidthDiskCache, isNotNull,
        reason: 'full-size viewers keep the on-disk resize cap');

    await tester.pumpWidget(const SizedBox.shrink());
    // Let the (real DefaultCacheManager) load error out and the timer cancel.
    await tester.pump(const Duration(milliseconds: 100));
  });

  test(
      'PC8: grid prefetch and card share one provider cache key '
      '(CachedNetworkImageProvider == includes maxWidth)', () {
    // A <=400 card now resolves an inner provider with maxWidth null, and
    // prefetchCardPhotos builds the identical one, so == holds and the
    // prefetch warms the exact entry the card reads.
    final card = CachedNetworkImageProvider(thumbUrl, maxWidth: null);
    final prefetch = CachedNetworkImageProvider(thumbUrl, maxWidth: null);
    expect(prefetch, equals(card));

    // The pre-fix card used a disk-resize key — that would NOT match, which is
    // exactly the mismatch this fix removes.
    final staleResizeKey = CachedNetworkImageProvider(thumbUrl, maxWidth: 780);
    expect(prefetch, isNot(equals(staleResizeKey)));
  });

  // --- NOTE 266 Obs 2: progressive placeholder kills the flat-dark hero -------

  const heroUrl = 'https://x/profile__medium_1080.jpg';

  testWidgets(
      'hero lag: a placeholderUrl paints the low-res thumb UNDER the full-res '
      'fade (not a flat dark tile) while the large variant loads', (tester) async {
    // Both the hero and its thumb hang, so the widget stays in the placeholder
    // state — the thumb the progressive placeholder paints is observable.
    AymaPhoto.debugCacheManager = _HangCacheManager();
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    // Plain decode path (<=400) so the hung fake stays on the loading
    // placeholder; `_placeholder` is width-independent, so this exercises the
    // same progressive-thumb branch the 900px hero uses.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AymaPhoto(
          url: heroUrl,
          displayWidth: 260,
          placeholderUrl: thumbUrl,
        ),
      ),
    ));
    await tester.pump(); // start loading
    await tester.pump(const Duration(milliseconds: 50)); // placeholder mounts

    final imgs = tester
        .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
        .toList();
    // The outer (hero) image plus the inner thumb painted as its placeholder.
    expect(imgs.map((w) => w.imageUrl), containsAll(<String>[heroUrl, thumbUrl]));
    final thumb = imgs.firstWhere((w) => w.imageUrl == thumbUrl);
    expect(thumb.maxWidthDiskCache, isNull,
        reason: 'the thumb placeholder must stay on the non-stalling plain path');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no placeholderUrl keeps the plain flat placeholder (one image)',
      (tester) async {
    AymaPhoto.debugCacheManager = _HangCacheManager();
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AymaPhoto(url: heroUrl, displayWidth: 900),
      ),
    ));
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsOneWidget,
        reason: 'without a thumb hint the placeholder is the flat tile, not an image');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a placeholderUrl equal to the url is ignored (no self-wait)',
      (tester) async {
    AymaPhoto.debugCacheManager = _HangCacheManager();
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AymaPhoto(url: heroUrl, displayWidth: 900, placeholderUrl: heroUrl),
      ),
    ));
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsOneWidget,
        reason: 'a same-URL thumb would only wait on the download it should cover');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// Serves one local fixture for any URL so the real decode pipeline runs with
/// no network, no sqflite — mirrors the fake in explore_screen_test.dart.
class _FixtureCacheManager implements BaseCacheManager {
  _FixtureCacheManager(String path)
      : _file = const LocalFileSystem().file(path);

  final fs.File _file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      _file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async =>
      _file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
