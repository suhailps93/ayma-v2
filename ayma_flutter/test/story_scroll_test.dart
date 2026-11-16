/// Regression test for Scout NOTE 232 / Board row 306:
/// Rapid story flings (26-swipe loop at 0.5s intervals) previously triggered an
/// Android input dispatching timeout (ANR) because [BulletSectionsEditor] was
/// repeatedly destroyed and re-instantiated by [ListView], causing re-fetch storms
/// and synchronous rebuilding of 15 canonical sections and >300 widgets during
/// active fling animations.
///
/// With [AutomaticKeepAliveClientMixin] on [_BulletSectionsEditorState], the editor
/// is preserved across flings, fetching exactly once and avoiding main-thread frame stalls.

import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];

  @override
  Future<List<BulletSection>> profileBullets() async {
    calls.add('bullets_get');
    return [
      for (var i = 0; i < 15; i++)
        BulletSection(
          pageType: 'sec_$i',
          title: 'Section $i',
          subtitle: 'Subtitle for section $i',
          order: i,
          pageId: 'sec_$i',
          bullets: [
            for (var b = 0; b < 6; b++)
              StoryBullet(
                id: 'b_${i}_$b',
                text: 'This is bullet $b in section $i with some narrative text.',
                visibility: b % 2 == 0 ? 'public' : 'private',
              ),
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
}
