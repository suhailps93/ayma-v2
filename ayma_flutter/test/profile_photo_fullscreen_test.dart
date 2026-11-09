// Tapping the highlighted (main) photo on a profile opens it full screen in
// the shared image viewer, gallery mode (founder ask, Nov 8, 2026): pinch /
// double-tap zoom works, swiping moves between the profile's photos, and
// closing lands the profile carousel on the photo last viewed. The filmstrip
// keeps its old behaviour — a thumbnail tap only jumps the carousel.
import 'dart:io';

import 'package:ayma_flutter/screens/public_profile_screen.dart';
import 'package:ayma_flutter/services/photo_carousel_registry.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/image_viewer.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one local fixture file for any URL — both [AymaPhoto] (the header
/// carousel + filmstrip) and [AymaImageViewer] run their real decode pipeline
/// against it, with no platform channels and no network.
class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
    : file = const LocalFileSystem().file(ioFile.path);

  // flutter_cache_manager's API speaks package:file's File type.
  final fs.File file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      file,
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
  }) async => file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _photos = [
  'https://example.com/p1.jpg',
  'https://example.com/p2.jpg',
  'https://example.com/p3.jpg',
];

Future<void> _pumpHeader(WidgetTester tester) async {
  // Tall surface so the square hero AND the filmstrip below it both lay out
  // on-screen (the default 800x600 pushes the strip off the bottom).
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fake = _FakeCacheManager(File('test/fixtures/tiny.png'));
  AymaPhoto.debugCacheManager = fake;
  AymaImageViewer.debugCacheManager = fake;
  addTearDown(() {
    AymaPhoto.debugCacheManager = null;
    AymaImageViewer.debugCacheManager = null;
  });
  PhotoCarouselRegistry.instance.clear();
  addTearDown(PhotoCarouselRegistry.instance.clear);

  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProfilePhotoHeader(
            photos: _photos,
            seed: 'her',
            name: 'Dana',
            age: 30,
            location: 'Berlin',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

int get _page => PhotoCarouselRegistry.instance.active!.currentPage();

/// The filmstrip thumbnails are the small AymaPhotos (the hero fills the
/// square header, ~800 wide; a thumbnail renders at 48).
List<Finder> _thumbs(WidgetTester tester) {
  final all = find.byType(AymaPhoto).evaluate().toList();
  return [
    for (var i = 0; i < all.length; i++)
      if (tester.getSize(find.byType(AymaPhoto).at(i)).width < 100)
        find.byType(AymaPhoto).at(i),
  ];
}

void main() {
  testWidgets('tapping the main photo opens the full-screen viewer, and '
      'double-tap zooms the photo', (tester) async {
    await _pumpHeader(tester);
    expect(find.byType(AymaImageViewer), findsNothing);

    await tester.tap(find.byType(PageView).first);
    await tester.pumpAndSettle();

    expect(find.byType(AymaImageViewer), findsOneWidget);
    // The zoom container is present on the opened photo.
    final viewers = find.descendant(
      of: find.byType(AymaImageViewer),
      matching: find.byType(InteractiveViewer),
    );
    expect(viewers, findsWidgets);

    // Double-tap actually engages the zoom, not just shows the container
    // (two quick taps — this Flutter's WidgetTester has no doubleTap).
    final center = tester.getCenter(find.byType(AymaImageViewer));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    final controller = tester
        .widget<InteractiveViewer>(viewers.first)
        .transformationController!;
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.5));
  });

  testWidgets('the viewer opens on the highlighted photo, and closing '
      'returns the profile to the photo last viewed in it', (tester) async {
    await _pumpHeader(tester);

    // Highlight the second photo via the filmstrip first.
    await tester.tap(_thumbs(tester)[1]);
    await tester.pumpAndSettle();
    expect(_page, 1);
    expect(find.byType(AymaImageViewer), findsNothing);

    // Open the viewer from the highlighted (second) photo.
    await tester.tap(find.byType(PageView).first);
    await tester.pumpAndSettle();
    expect(find.byType(AymaImageViewer), findsOneWidget);

    // One swipe in the viewer: had it opened on photo 1 instead of the
    // highlighted photo 2, it would sit on page 1 now, not page 2. (The
    // profile carousel itself is offstage under the opaque viewer and only
    // catches up when the viewer closes — asserted below.)
    await tester.fling(
      find.byType(AymaImageViewer),
      const Offset(-400, 0),
      1000,
    );
    await tester.pumpAndSettle();
    final gallery = find.descendant(
      of: find.byType(AymaImageViewer),
      matching: find.byType(PageView),
    );
    expect(tester.widget<PageView>(gallery).controller!.page, 2.0);

    // Close: back on the profile, on the photo last viewed.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AymaImageViewer), findsNothing);
    expect(_page, 2);
  });

  testWidgets('a filmstrip tap still only jumps the carousel — no viewer', (
    tester,
  ) async {
    await _pumpHeader(tester);

    await tester.tap(_thumbs(tester)[2]);
    await tester.pumpAndSettle();

    expect(find.byType(AymaImageViewer), findsNothing);
    expect(_page, 2);
  });
}
