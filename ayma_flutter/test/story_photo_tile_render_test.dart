// NOTE 252 (Chunk 2) — Your Story photo tiles showed the broken-image glyph
// because the server served a frozen, stale image-node URL. The render side is
// correct: given a resolvable image_url, the shared [NodeImage] renderer paints
// the photo, NOT the broken-glyph fallback. This pins that contract (so a
// future renderer change can't silently reintroduce the glyph) and emits a
// golden as the visual proof the four tiles load.
import 'dart:async';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one local fixture for any URL so the real decode pipeline runs with
/// no network. It is an [ImageCacheManager] (not just a [BaseCacheManager]) so
/// the production disk-resize path — which NodeImage's 480px display width takes
/// — resolves, exactly as the real DefaultCacheManager does on-device.
class _FixtureCacheManager implements ImageCacheManager {
  _FixtureCacheManager(String path) : _file = const LocalFileSystem().file(path);

  final fs.File _file;

  Stream<FileResponse> _serve(String url) async* {
    yield FileInfo(
      _file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      _serve(url);

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) =>
      _serve(url);

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

void main() {
  // The four Story photo tiles — each an image node carrying a (re-minted,
  // loadable) Storage URL, exactly what /story/photos now returns.
  final tiles = [
    for (var i = 1; i <= 4; i++)
      StoryNode.image(
        id: 'tile$i',
        imageUrl: 'https://firebasestorage.example/o/seed_$i.png?token=FRESH',
      ),
  ];

  testWidgets('a resolvable image node renders the photo, not the broken glyph',
      (tester) async {
    AymaPhoto.debugCacheManager = _FixtureCacheManager('test/fixtures/tiny.png');
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: NodeImage(node: tiles.first)),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // The fixture decoded through the real CachedNetworkImage pipeline…
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    // …and the broken-image glyph (the _fallback shown on empty/errored URLs)
    // is NOT present.
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
  });

  testWidgets('all four Story tiles load (golden proof)', (tester) async {
    AymaPhoto.debugCacheManager = _FixtureCacheManager('test/fixtures/tiny.png');
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final n in tiles) NodeImage(node: n)],
            ),
          ),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });

    expect(find.byType(CachedNetworkImage), findsNWidgets(4));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/story_photo_tiles_loaded.png'),
    );
  });

  testWidgets('an empty image_url shows the honest broken-glyph fallback',
      (tester) async {
    // The negative control: with no URL, NodeImage paints its fallback — so the
    // positive tests above are meaningful, not vacuously green.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: AymaPhoto(url: '', displayWidth: 240),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });
}
