/// Regression test for Scout NOTE 232 / Board row 306:
/// Rapid story flings (26-swipe loop at 0.5s intervals) previously triggered an
/// Android input dispatching timeout (ANR) because [BulletSectionsEditor] was
/// repeatedly destroyed and re-instantiated by [ListView], causing re-fetch storms
/// and synchronous rebuilding of 15 canonical sections and >300 widgets during
/// active fling animations.
///
/// With [AutomaticKeepAliveClientMixin] on [_BulletSectionsEditorState], the editor
/// is preserved across flings, fetching exactly once and avoiding main-thread frame stalls.
library;

import 'dart:io';

import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
      : file = const LocalFileSystem().file(ioFile.path);

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
  }) async =>
      file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];

  @override
  Future<List<BulletSection>> profileBullets() async {
    calls.add('bullets_get');
    return [
      for (var i = 0; i < 15; i++)
        BulletSection(
          pageType: i == 14 ? 'misc' : 'sec_$i',
          title: i == 14 ? 'Little Extras' : 'Section $i',
          subtitle: 'Subtitle for section $i',
          order: i,
          pageId: i == 14 ? 'misc' : 'sec_$i',
          bullets: [
            for (var b = 0; b < (i == 14 ? 2 : 6); b++)
              StoryBullet(
                id: 'b_${i}_$b',
                text: 'This is bullet $b in section $i with some narrative text.',
                visibility: b % 2 == 0 ? 'public' : 'private',
              ),
            if (i == 14) ...[
              const StoryBullet(
                id: 'fact_milo',
                text: 'Daniel has a brown tabby cat named Milo',
                visibility: 'private',
              ),
              const StoryBullet(
                id: 'emergent.image.f3fa7d90',
                text: 'Milo the brown tabby cat',
                visibility: 'private',
                imageUrl: 'https://storage/milo.jpg',
              ),
            ],
          ],
        ),
    ];
  }

  @override
  Future<StoryData> storyGet() async {
    return StoryData(
      sections: [
        for (var i = 0; i < 15; i++)
          StorySection(
            pageId: 'sec_$i',
            pageType: 'sec_$i',
            title: 'Section $i',
            body: 'Body text for section $i',
            visibility: 'public',
          ),
      ],
    );
  }

  @override
  Future<AiNotes> aiNotes() async {
    return AiNotes(
      text: 'Sample notes',
      photos: [
        for (var i = 0; i < 18; i++)
          AiNotePhoto(
            id: 'p_$i',
            url: 'https://example.com/photo_$i.jpg',
            source: i < 6 ? 'profile' : (i < 12 ? 'chat' : 'web'),
            isUser: 'yes',
          ),
      ],
    );
  }

  @override
  Future<CareerTimeline> careerTimeline() async {
    return const CareerTimeline(
      showTimeline: true,
      linkedinUrl: 'https://linkedin.com/in/test',
      entries: [
        TimelineEntry(id: 'c1', org: 'Company 1', titleOrDegree: 'Role 1', confidence: 'high', kind: 'work'),
        TimelineEntry(id: 'c2', org: 'Company 2', titleOrDegree: 'Role 2', confidence: 'high', kind: 'work'),
      ],
    );
  }
}

void main() {
  setUp(() {
    AymaPhoto.debugCacheManager = _FakeCacheManager(File('test/fixtures/tiny.png'));
  });
  tearDown(() {
    AymaPhoto.debugCacheManager = null;
  });

  testWidgets('26-swipe rapid fling loop completes smoothly without re-fetch storm (NOTE 232)', (tester) async {
    final api = _FakeApi();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: StoryEditorScreen(api: api, myUid: 'u1'),
      ),
    );
    await tester.pumpAndSettle();

    final times = <int>[];
    // Scout NOTE 232 reproduction: 26-swipe loop at 0.5s intervals
    for (var i = 0; i < 26; i++) {
      final sw = Stopwatch()..start();
      final dy = (i % 2 == 0) ? -900.0 : 900.0;
      await tester.fling(find.byType(ListView), Offset(0, dy), 2000);
      await tester.pump(const Duration(milliseconds: 500));
      sw.stop();
      times.add(sw.elapsedMilliseconds);
    }

    final bulletFetches = api.calls.where((c) => c.contains('bullets')).length;
    expect(bulletFetches, 1, reason: 'profileBullets must not re-fetch repeatedly during rapid flings');
    // Verify all flings completed
    expect(times.length, 26);
  });

  testWidgets(
      '9-swipe slow scroll with image bullet renders immediately below fact '
      'without stall or re-fetch storm (NOTE 237)', (tester) async {
    final api = _FakeApi();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: StoryEditorScreen(api: api, myUid: 'u1'),
        ),
      );
      await tester.pumpAndSettle();

      // Scout NOTE 237 reproduction: 9 half-screen swipes at pauses
      for (var i = 0; i < 9; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    // Keep-alive invariant: must not re-fetch bullets during slow scrolling
    final bulletFetches = api.calls.where((c) => c.contains('bullets')).length;
    expect(bulletFetches, 1,
        reason: 'profileBullets must not re-fetch during slow scroll passes');

    // Milo fact bullet and its inline image bullet are present in the story
    final factFinder = find.text('Daniel has a brown tabby cat named Milo');
    final imageTextFinder = find.text('Milo the brown tabby cat');
    expect(factFinder, findsOneWidget);
    expect(imageTextFinder, findsOneWidget);

    // Image sits immediately below its fact bullet
    expect(tester.getTopLeft(factFinder).dy,
        lessThan(tester.getTopLeft(imageTextFinder).dy));

    // The image must be rendered through AymaPhoto (with capped decode and
    // disk caching), NOT a bare Image.network which causes main-thread ANR.
    final photoFinder = find.byWidgetPredicate(
      (w) => w is AymaPhoto && w.url == 'https://storage/milo.jpg',
    );
    expect(photoFinder, findsOneWidget,
        reason: 'Story image bullet must use AymaPhoto, not bare Image.network');

    final photo = tester.widget<AymaPhoto>(photoFinder);
    expect(photo.displayWidth, lessThanOrEqualTo(400),
        reason: 'decode width must be capped to prevent main-thread stall');

    final cached = tester.widget<CachedNetworkImage>(
      find.byWidgetPredicate(
        (w) => w is CachedNetworkImage && w.imageUrl == 'https://storage/milo.jpg',
      ),
    );
    expect(cached.memCacheWidth, isNotNull,
        reason: 'memCacheWidth must be set to prevent full-resolution decode');
    expect(cached.memCacheWidth!, lessThanOrEqualTo(400 * 4));
  });
}
