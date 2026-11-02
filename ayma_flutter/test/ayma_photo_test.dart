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

  testWidgets(
      'PC8 stall guard: a placeholder that never gets a frame flips to the '
      'error (F1) fallback after the stall timeout', (tester) async {
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

    // Pre-fix this stuck here forever; the F1 fallback must not show yet.
    expect(find.byKey(const Key('f1')), findsNothing);

    // Advance past the 10s interactive stall timeout.
    await tester.pump(const Duration(seconds: 11));

    // The card now falls back to the F1 initial-avatar instead of sticking on
    // the darkBgCard placeholder.
    expect(find.byKey(const Key('f1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink()); // dispose: cancels timer
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
