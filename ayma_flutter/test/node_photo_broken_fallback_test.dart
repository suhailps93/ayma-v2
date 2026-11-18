// Leg 33 — a web-research report photo that can't be loaded (a host that
// blocks hotlinking / 403s a client, or a URL that isn't really an image) must
// NEVER render the broken-image glyph. It falls back to a clean neutral tile
// with a tappable "View source" chip when the node knows its origin page.
import 'dart:async';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/node_photo_carousel.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cache manager whose download never completes — AymaPhoto's stall guard
/// then flips the tile to its error fallback (the real on-device outcome for a
/// host that stalls / is unreachable, without needing a live network error).
class _HangCacheManager implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      StreamController<FileResponse>().stream;

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) =>
      Completer<fs.File>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

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
    yield FileInfo(_file, FileSource.Cache,
        DateTime.now().add(const Duration(days: 1)), url);
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

StoryNode _webPhotoNode() => StoryNode.fromMap({
      'id': 'wp1',
      'answer_type': 'image',
      'visibility': NodeVis.public,
      'image_url': 'https://www.cockcroft.ac.uk/people/jane',
      'image_read': 'Photo found on https://www.cockcroft.ac.uk',
      'source_ref': 'https://www.cockcroft.ac.uk/people/jane',
    });

void main() {
  testWidgets(
      'a web-research photo that fails to load shows a clean source fallback, '
      'never the broken-image glyph', (tester) async {
    AymaPhoto.debugCacheManager = _HangCacheManager();
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NodePhotoCarousel(images: [_webPhotoNode()]),
      ),
    ));
    await tester.pump();
    // Advance past AymaPhoto's 10s stall timeout so the error fallback paints.
    await tester.pump(const Duration(seconds: 11));

    // The hard guarantee: the broken-image glyph never shows.
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    // The clean source fallback (tappable "View source") shows instead.
    expect(find.byKey(const Key('node_image_source_link_wp1')), findsOneWidget);
    expect(find.text('View source'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a valid image candidate still renders (no fallback)',
      (tester) async {
    AymaPhoto.debugCacheManager =
        _FixtureCacheManager('test/fixtures/tiny.png');
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: NodePhotoCarousel(images: [
            StoryNode.fromMap({
              'id': 'ok1',
              'answer_type': 'image',
              'visibility': NodeVis.public,
              'image_url': 'https://example.com/real.png',
            }),
          ]),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byKey(const Key('node_image_source_link_ok1')), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
