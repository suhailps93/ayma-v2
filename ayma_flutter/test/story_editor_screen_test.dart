import 'dart:async';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/screens/story_photos_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];
  final List<Map<String, String>> chatCalls = [];

  StoryData data = const StoryData(sections: [
    StorySection(
      pageId: 'career',
      pageType: 'career',
      title: 'Career',
      body: 'I lead the analytics team in Lisbon. It has been a wild ride.',
      visibility: 'public',
    ),
    StorySection(
      pageId: 'family',
      pageType: 'family',
      title: 'Family',
      body: 'Close with my sister.',
      visibility: 'private',
    ),
  ]);

  List<StorySection> aiSections = const [];
  List<AiNotePhoto> photos = const [];

  CareerTimeline careerTimelineResult =
      const CareerTimeline(entries: [], overallConfidence: 'none', showTimeline: false);

  SectionProvenance provenanceResult = const SectionProvenance(
    pageId: 'career',
    conversationCount: 3,
    updatedAt: '2026-09-01T00:00:00+00:00',
    sources: [ProvenanceSource(date: '2026-08-19T00:00:00+00:00')],
  );

  DeepDiveReport? deepDiveReportResult;

  /// Called (with the sent message) right before the fake chat reply is
  /// returned — a test sets this to mutate [data], simulating the backend
  /// side-effect a real tool call would have had.
  void Function(String message)? onChatSent;
  ChatResult chatReply = const ChatResult(reply: "Done — made that private.");

  @override
  Future<StoryData> storyGet() async {
    calls.add('get');
    return data;
  }

  @override
  Future<String> storySaveSection({
    required String pageId,
    required String body,
    String? visibility,
  }) async {
    calls.add('save:$pageId:$body');
    return 'v2';
  }

  @override
  Future<String> storySetVisibility({
    required String pageId,
    required String visibility,
  }) async {
    calls.add('vis:$pageId:$visibility');
    return 'v2';
  }

  @override
  Future<void> storyRemoveSection(String pageId) async {
    calls.add('remove:$pageId');
  }

  @override
  Future<List<StoryVersion>> storySectionVersions(String pageId) async {
    calls.add('versions:$pageId');
    return const [];
  }

  @override
  Future<List<StorySection>> storyAiNotes() async {
    calls.add('ai_notes');
    return aiSections;
  }

  @override
  Future<AiNotes> aiNotes() async {
    calls.add('photos');
    return AiNotes(text: '', photos: photos);
  }

  @override
  Future<void> photoHide(String url, {required String source}) async {
    calls.add('photo_hide:$url:$source');
  }

  @override
  Future<void> photoPublish(String url, {required String source}) async {
    calls.add('photo_publish:$url:$source');
  }

  @override
  Future<CareerTimeline> careerTimeline() async {
    calls.add('career_timeline');
    return careerTimelineResult;
  }

  @override
  Future<CareerTimeline> refreshCareerTimeline() async {
    calls.add('career_timeline_refresh');
    return careerTimelineResult;
  }

  @override
  Future<String> setLinkedinUrl(String url) async {
    calls.add('set_linkedin:$url');
    return url;
  }

  @override
  Future<SectionProvenance> storyProvenance(String pageId) async {
    calls.add('provenance:$pageId');
    return provenanceResult;
  }

  /// So a provenance-source tap that opens [ChatScreen] resolves its history
  /// load instantly instead of hitting the network in a test.
  @override
  Future<({List<ChatMessage> messages, String? nextBefore})> chatHistory({
    String? before,
    int limit = 40,
  }) async {
    calls.add('chatHistory');
    return (messages: const <ChatMessage>[], nextBefore: null);
  }

  @override
  Future<DeepDiveReport> deepDiveReport(String id) async {
    calls.add('deep_dive_report:$id');
    return deepDiveReportResult ??
        DeepDiveReport(
          name: 'Me', summary: '', confidence: 'high', caveats: '',
          isSelf: true, otherUid: '', subjectImage: '', createdAt: null,
          facts: const [], links: const [], webImages: const [],
        );
  }

  @override
  Stream<ChatEvent> chatStream(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
  }) async* {
    chatCalls.add({
      'message': message,
      'page_id': storyPageId,
      'passage': storyPassage,
      'timeline_entry_id': storyTimelineEntryId,
    });
    onChatSent?.call(message);
    yield ChatReplyEvent(chatReply);
  }

  @override
  Future<ChatResult> chat(
    String message, {
    String sessionId = '',
    String viewingProfileUid = '',
    List<Map<String, String>> recentTurns = const [],
    String imagePath = '',
    String storyPageId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
  }) async {
    chatCalls.add({
      'message': message,
      'page_id': storyPageId,
      'passage': storyPassage,
      'timeline_entry_id': storyTimelineEntryId,
    });
    onChatSent?.call(message);
    return chatReply;
  }
}

Future<void> _pumpWithRouter(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/story',
    routes: [
      GoRoute(path: '/story', builder: (_, __) => StoryEditorScreen(api: api)),
      GoRoute(
        path: '/appearance/:id',
        builder: (_, state) => Scaffold(body: Text('APPEARANCE ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/deep-dive/:id',
        builder: (_, state) => Scaffold(body: Text('DEEP DIVE ${state.pathParameters['id']}')),
      ),
      GoRoute(path: '/skills', builder: (_, __) => const Scaffold(body: Text('SKILLS SCREEN'))),
      GoRoute(
        path: StoryPhotosScreen.path,
        builder: (_, __) => StoryPhotosScreen(api: api),
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the document with numbered narrative sections', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    expect(find.textContaining('Your Story'), findsOneWidget);
    expect(find.textContaining('01'), findsWidgets);
    expect(find.textContaining('CAREER'), findsOneWidget);
    expect(find.textContaining('I lead the analytics team'), findsOneWidget);
  });

  testWidgets('Public view tab shows only public sections', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();

    expect(find.textContaining('I lead the analytics team'), findsOneWidget);
    expect(find.textContaining('Close with my sister'), findsNothing);
  });

  testWidgets('tapping a sentence shows the floating toolbar', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    expect(find.text('Make public'), findsOneWidget);
    expect(find.text('Make private'), findsOneWidget);
    expect(find.text('Ask Ayma'), findsOneWidget);
  });

  testWidgets('Make private persists a {{private}} span for that sentence',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();

    final saved = api.calls.firstWhere((c) => c.startsWith('save:career:'));
    expect(saved, contains('{{private}}'));
    expect(saved, contains('I lead the analytics team'));
  });

  testWidgets('tapping outside the toolbar dismisses it', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();
    expect(find.text('Ask Ayma'), findsOneWidget);

    // Tap far away, on the transparent full-screen barrier behind the toolbar.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('Ask Ayma'), findsNothing);
  });

  testWidgets('Ask Ayma opens the overlay with the selected text quoted',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask Ayma'));
    await tester.pumpAndSettle();

    expect(find.text('Chat with Ayma'), findsOneWidget);
    expect(find.textContaining('I lead the analytics team'), findsWidgets);
  });

  testWidgets('sending a message in the overlay calls chat with the right story context',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask Ayma'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Make this less formal.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.chatCalls, isNotEmpty);
    final call = api.chatCalls.last;
    expect(call['page_id'], 'career');
    expect(call['passage'], contains('I lead the analytics team'));
    expect(find.textContaining('Done — made that private'), findsOneWidget);
  });

  testWidgets('a live update from Ayma is reflected back into the document',
      (tester) async {
    final api = _FakeApi();
    api.onChatSent = (_) {
      api.data = const StoryData(sections: [
        StorySection(
          pageId: 'career',
          pageType: 'career',
          title: 'Career',
          body: 'I lead systems integration in Lisbon. It has been a wild ride.',
          visibility: 'public',
        ),
        StorySection(
          pageId: 'family', pageType: 'family', title: 'Family',
          body: 'Close with my sister.', visibility: 'private',
        ),
      ]);
    };
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask Ayma'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Change this to say I lead systems integration.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // Close the sheet -> the document underneath re-fetches and shows the change.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.textContaining('I lead systems integration'), findsOneWidget);
    expect(find.textContaining('I lead the analytics team'), findsNothing);
  });

  testWidgets("Ayma's Notes tab shows sections with a provenance action and no invented confidence",
      (tester) async {
    final api = _FakeApi()
      ..aiSections = const [
        StorySection(
          pageId: 'values', pageType: 'values', title: 'Values',
          body: 'Family matters most to me.', visibility: 'private',
        ),
      ];
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text("Ayma's notes"));
    await tester.pumpAndSettle();

    expect(find.text('Values'), findsOneWidget);
    expect(find.textContaining('Family matters most'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('Why Ayma believes this'), findsWidgets);
  });

  testWidgets('tapping "Why Ayma believes this" shows resolved provenance',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Why Ayma believes this').first);
    await tester.pumpAndSettle();

    expect(api.calls, contains('provenance:career'));
    expect(find.textContaining('Learned across 3 conversations'), findsOneWidget);
    expect(find.textContaining('Aug 19'), findsOneWidget);
  });

  testWidgets('a provenance source with a session id is tappable and opens the chat',
      (tester) async {
    final api = _FakeApi()
      ..provenanceResult = const SectionProvenance(
        pageId: 'career',
        conversationCount: 1,
        sources: [
          ProvenanceSource(
            date: '2026-08-19T00:00:00+00:00',
            sessionId: 's1',
          ),
        ],
      );
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Why Ayma believes this').first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.textContaining('Conversation ·'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(api.calls, contains('chatHistory'));
  });

  testWidgets('a provenance source with no session id renders as a plain, non-tappable row',
      (tester) async {
    final api = _FakeApi(); // default fixture's source has no sessionId
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Why Ayma believes this').first);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chevron_right), findsNothing);
    await tester.tap(find.textContaining('Conversation ·'));
    await tester.pumpAndSettle();

    // No navigation happened — still looking at the provenance sheet.
    expect(find.byType(ChatScreen), findsNothing);
    expect(find.textContaining('Learned across'), findsOneWidget);
  });

  testWidgets('the photos interlude renders a mosaic and links to the full gallery',
      (tester) async {
    final api = _FakeApi()
      ..photos = List.generate(
        8,
        (i) => AiNotePhoto(url: 'https://example.com/$i.jpg', source: 'profile'),
      );
    // The thumbnails are real `Image.network` widgets with an `errorBuilder`
    // that already handles a failed load visually — this test only cares
    // about the mosaic's structure and navigation, not the pixels, so the
    // network failures themselves (there's no real photo host in tests) are
    // expected noise, not a fresh mystery to debug.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {};
    addTearDown(() => FlutterError.onError = originalOnError);

    await _pumpWithRouter(tester, api);

    expect(find.text('A few glimpses into my world.'), findsOneWidget);
    expect(find.textContaining('8 photos'), findsOneWidget);

    await tester.tap(find.text('VIEW ALL PHOTOS'));
    await tester.pumpAndSettle();
    expect(find.byType(StoryPhotosScreen), findsOneWidget);
  });

  testWidgets('the web-findings interlude renders counts from the real digest',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'career', pageType: 'career', title: 'Career',
          body: 'I build things.', visibility: 'public',
        ),
        StorySection(
          pageId: 'web-findings', pageType: 'misc', title: 'Web findings',
          body: 'Overall confidence: high.', visibility: 'private',
          isSkill: true, reportId: 'dive1',
        ),
      ])
      ..deepDiveReportResult = DeepDiveReport(
        name: 'Me', summary: '', confidence: 'high', caveats: '',
        isSelf: true, otherUid: '', subjectImage: '', createdAt: null,
        facts: const [
          DeepDiveFact(id: 'f1', claim: 'Works at Acme', category: 'work',
              sourceUrl: '', confidence: 'high'),
          DeepDiveFact(id: 'f2', claim: 'Maybe gave a talk', category: 'press',
              sourceUrl: '', confidence: 'medium'),
        ],
        links: const [], webImages: const [],
      );
    await _pumpWithRouter(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('What Ayma found online.'), findsOneWidget);
    expect(find.textContaining('2 findings'), findsOneWidget);
    expect(find.textContaining('1 confirmed'), findsOneWidget);
    expect(find.textContaining('1 needs review'), findsOneWidget);

    await tester.tap(find.text('VIEW WEB FINDINGS'));
    await tester.pumpAndSettle();
    expect(find.text('DEEP DIVE dive1'), findsOneWidget);
  });

  testWidgets('the career timeline renders only when confidence is decent',
      (tester) async {
    final api = _FakeApi()
      ..careerTimelineResult = const CareerTimeline(
        entries: [
          TimelineEntry(id: 'e1', kind: 'work', org: 'Figure AI',
              titleOrDegree: 'Software Integration Engineer',
              start: '2025', end: 'Present', confidence: 'high'),
        ],
        overallConfidence: 'high',
        showTimeline: true,
      );
    await _pumpWithRouter(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('Figure AI'), findsOneWidget);
    expect(find.textContaining('Software Integration Engineer'), findsOneWidget);
  });

  testWidgets('a low-confidence timeline falls back to prose only (no LinkedIn nudge either)',
      (tester) async {
    final api = _FakeApi()
      ..careerTimelineResult = const CareerTimeline(
        entries: [], overallConfidence: 'low', showTimeline: false,
        linkedinUrl: 'https://www.linkedin.com/in/me/',
      );
    await _pumpWithRouter(tester, api);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.work_outline), findsNothing);
    expect(find.textContaining('Add your LinkedIn'), findsNothing);
  });

  testWidgets('no LinkedIn on file nudges the user to add one, under Career & Education',
      (tester) async {
    final api = _FakeApi()
      ..careerTimelineResult = const CareerTimeline(
        entries: [], overallConfidence: 'none', showTimeline: false, linkedinUrl: '',
      );
    await _pumpWithRouter(tester, api);
    await tester.pumpAndSettle();

    expect(find.textContaining('Add your LinkedIn'), findsOneWidget);

    await tester.tap(find.textContaining('Add your LinkedIn'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'https://www.linkedin.com/in/me/');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('set_linkedin:https://www.linkedin.com/in/me/'));
    expect(api.calls, contains('career_timeline_refresh'));
  });

  testWidgets('tapping a timeline entry opens Ask Ayma scoped to that entry',
      (tester) async {
    final api = _FakeApi()
      ..careerTimelineResult = const CareerTimeline(
        entries: [
          TimelineEntry(id: 'e1', kind: 'work', org: 'Figure AI',
              titleOrDegree: 'Engineer', start: '2025', end: 'Present',
              confidence: 'high'),
        ],
        overallConfidence: 'high', showTimeline: true,
      );
    await _pumpWithRouter(tester, api);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Figure AI'));
    await tester.pumpAndSettle();

    expect(find.text('Chat with Ayma'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, "that's wrong, I left in 2023");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    final call = api.chatCalls.last;
    expect(call['page_id'], 'career');
    expect(call['timeline_entry_id'], 'e1');
  });
}
