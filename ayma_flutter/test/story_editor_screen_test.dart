import 'dart:async';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/photo_gallery.dart';
import 'package:ayma_flutter/widgets/selectable_markdown.dart';
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

  Future<AppearanceReportResult> Function()? runAppearance;
  bool failNotes = false;
  @override
  Future<AppearanceReportResult> runAppearanceReport({
    List<String> imagePaths = const [], bool wantFace = true, bool wantBody = true,
  }) async {
    calls.add('run_appearance');
    return runAppearance!();
  }
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
    if (failNotes) throw StateError('notes unavailable');
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
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
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
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
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
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

void main() {

  List<StorySection> appearance({String visibility = 'private', String? reportId = 'current',
      bool edited = false, String? body}) => [
    for (final id in ['face-analysis', 'body-analysis', 'physical-profile'])
      StorySection(pageId: id, pageType: 'misc', title: id,
          body: body ?? 'Summary for $id.\nSecond paragraph kept in full.',
          visibility: visibility, isSkill: true, reportId: reportId, userEdited: edited),
  ];

  for (final notes in [false, true]) {
    testWidgets('Appearance groups three pages and one link notes=$notes', (tester) async {
      final rows = appearance(edited: true);
      final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
      await _pumpWithRouter(tester, api);
      if (notes) {
        await tester.tap(find.text("Ayma's notes"));
        await tester.pumpAndSettle();
      }
      for (final label in ['FACE', 'PHYSIQUE', 'PROFILE']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.textContaining('Second paragraph kept in full.'), findsNWidgets(3));
      expect(find.text('VIEW FULL REPORT'), findsOneWidget);
      await tester.tap(find.text('VIEW FULL REPORT'));
      await tester.pumpAndSettle();
      expect(find.text('APPEARANCE current'), findsOneWidget);
    });
  }

  for (final visibility in ['private', 'ai', 'ai_only', 'unknown']) {
    testWidgets('Appearance $visibility stays out of Public view', (tester) async {
      final rows = appearance(visibility: visibility);
      final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
      await _pumpWithRouter(tester, api);
      if (visibility != 'private') expect(find.text('FACE'), findsNothing);
      await tester.tap(find.text('Public view'));
      await tester.pumpAndSettle();
      expect(find.text('FACE'), findsNothing);
      expect(find.text('VIEW FULL REPORT'), findsNothing);
      await tester.tap(find.text("Ayma's notes"));
      await tester.pumpAndSettle();
      expect(find.text('FACE'), findsOneWidget);
    });
  }

  testWidgets('Public Appearance has no owner report or provenance actions', (tester) async {
    final api = _FakeApi()..data = StoryData(sections: appearance(visibility: 'public'));
    await _pumpWithRouter(tester, api);
    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();
    expect(find.text('FACE'), findsOneWidget);
    expect(find.text('VIEW FULL REPORT'), findsNothing);
    expect(find.text('Why Ayma believes this'), findsNothing);
    expect(find.text('Run it'), findsNothing);
  });

  testWidgets('Public Appearance hides a card containing private passages', (tester) async {
    final api = _FakeApi()..data = StoryData(sections: appearance(
        visibility: 'public', body: '{{private}}Secret score{{/private}}'));
    await _pumpWithRouter(tester, api);
    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Secret score'), findsNothing);
    expect(find.text('FACE'), findsNothing);
  });

  testWidgets('Mixed visibility Appearance stays private and finds a later report id', (tester) async {
    final rows = [
      appearance(visibility: 'public', reportId: ' ').first,
      appearance()[1],
      appearance(visibility: 'public')[2],
    ];
    final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
    await _pumpWithRouter(tester, api);
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();
    expect(find.text('FACE'), findsNothing);
    await tester.tap(find.text("Ayma's notes"));
    await tester.pumpAndSettle();
    expect(find.text('PRIVATE'), findsOneWidget);
    await tester.tap(find.text('VIEW FULL REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE current'), findsOneWidget);
  });

  testWidgets('Run it refreshes both views with a single in-flight request', (tester) async {
    final rows = appearance(reportId: null);
    final pending = Completer<AppearanceReportResult>();
    final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows
      ..runAppearance = () => pending.future;
    await _pumpWithRouter(tester, api);
    await tester.tap(find.text("Ayma's notes"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run it'));
    await tester.pump();
    expect(find.text('Run it'), findsNothing);
    expect(api.calls.where((c) => c == 'run_appearance'), hasLength(1));
    api.data = StoryData(sections: appearance());
    api.aiSections = appearance();
    pending.complete(const AppearanceReportResult(usageCapped: false, reportId: 'current', report: null));
    await tester.pumpAndSettle();
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
    await tester.tap(find.text('Story'));
    await tester.pumpAndSettle();
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
  });

  for (final failure in ['run', 'refresh', 'credits']) {
    testWidgets('Appearance handles $failure and restores Run it', (tester) async {
      final rows = appearance(reportId: null, body: '');
      final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
      api.runAppearance = () async {
        if (failure == 'run') throw StateError('failed');
        if (failure == 'refresh') api.failNotes = true;
        return AppearanceReportResult(usageCapped: failure == 'credits', reportId: '', report: null);
      };
      await _pumpWithRouter(tester, api);
      await tester.tap(find.text('Run it'));
      await tester.pumpAndSettle();
      expect(find.text('Run it'), findsOneWidget);
      if (failure != 'credits') expect(find.text("Couldn't run that — try again."), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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

  testWidgets(
      'tapping an already-public sentence goes straight to Edit with Ayma, '
      'offering Make private (no Make public, no floating toolbar)',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    // No intermediate step: one tap on the sentence, and the sheet is up.
    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    // The fixture's "career" sentence carries no {{private}} span — it's
    // public — so the toggle that would be a no-op (Make public) is hidden.
    expect(find.text('Make private'), findsOneWidget);
    expect(find.text('Make public'), findsNothing);
  });

  testWidgets(
      'Public view tab: tapping a sentence also goes straight to Edit with '
      'Ayma, same as Story', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();

    // Same public-only sentence, now tapped from the Public view tab instead
    // of Story — it must behave identically: straight to the sheet, and
    // since this passage is by definition public (that's why it's visible in
    // Public view at all), the privacy action offered is "Make private", not
    // "Make public".
    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Make private'), findsOneWidget);
    expect(find.text('Make public'), findsNothing);
  });

  testWidgets(
      'tapping an already-private sentence goes straight to Edit with Ayma, '
      'offering Make public (no Make private)',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
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
          // A {{private}} span is what `isPrivateAt` actually keys off —
          // the section-level `visibility` field is a separate concept.
          body: '{{private}}Close with my sister.{{/private}}',
          visibility: 'private',
        ),
      ]);
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('Close with my sister'));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Make public'), findsOneWidget);
    expect(find.text('Make private'), findsNothing);
  });

  testWidgets(
      'the Make private quick suggestion sends "Make private" through the '
      'same chat path as any other request', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();

    // There is no local direct-save path any more — the privacy toggle is
    // just another chat request Ayma's own tools act on, same as any typed
    // instruction or the Delete chip below.
    expect(api.calls.any((c) => c.startsWith('save:')), isFalse);
    expect(api.chatCalls, isNotEmpty);
    final call = api.chatCalls.last;
    expect(call['message'], 'Make private');
    expect(call['page_id'], 'career');
    expect(call['passage'], contains('I lead the analytics team'));
  });

  testWidgets(
      'tapping a sentence opens Edit with Ayma directly — no floating '
      'toolbar ever renders — keeps it highlighted while the sheet is open, '
      'clearing once it closes', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    SelectableMarkdown careerMarkdown() =>
        tester.widgetList<SelectableMarkdown>(find.byType(SelectableMarkdown))
            .firstWhere((w) => w.raw.contains('I lead the analytics team'));

    expect(careerMarkdown().selectedRange, isNull);
    // Never rendered at any point, including before this tap.
    expect(find.text('Ask Ayma'), findsNothing);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    // Still nowhere — "Ask Ayma" was the old toolbar button; it's gone along
    // with the toolbar itself.
    expect(find.text('Ask Ayma'), findsNothing);
    // The sentence underneath stays lit while the sheet is open.
    expect(careerMarkdown().selectedRange, isNotNull);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Edit with Ayma'), findsNothing);
    expect(careerMarkdown().selectedRange, isNull);
  });

  testWidgets('the sheet quotes the selected text', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.textContaining('I lead the analytics team'), findsWidgets);
  });

  testWidgets('sending a message in the overlay calls chat with the right story context',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
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

    await tester.enterText(find.byType(TextField).last, 'Change this to say I lead systems integration.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // Close the sheet -> the document underneath re-fetches and shows the change.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    // Flush the flash-clear timer the exchange above scheduled, so it doesn't
    // leak past this test.
    await tester.pump(const Duration(milliseconds: 950));

    // Two matches now: the document body itself, and the "Changed to" toast
    // (see below) that also quotes the new text.
    expect(find.textContaining('I lead systems integration'), findsWidgets);
    expect(find.textContaining('I lead the analytics team'), findsNothing);
  });

  testWidgets(
      'an Ask-Ayma edit that actually changes the body shows a "Changed to" toast',
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

    await tester.enterText(
        find.byType(TextField).last, 'Change this to say I lead systems integration.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('Changed to "I lead systems integration'),
        findsOneWidget);

    // Flush the flash-clear timer this exchange scheduled, so it doesn't
    // leak past this test (pumpAndSettle can settle before a bare
    // Future.delayed this far out actually fires).
    await tester.pump(const Duration(milliseconds: 950));
  });

  testWidgets(
      'no "Changed to" toast when the Ask-Ayma exchange leaves the body unchanged',
      (tester) async {
    final api = _FakeApi(); // default onChatSent leaves `data` untouched
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'Make this less formal.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('Changed to'), findsNothing);
  });

  testWidgets(
      'the Delete quick suggestion sends "Delete" through the same chat path as any other',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.textContaining('I lead the analytics team'));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(api.chatCalls, isNotEmpty);
    final call = api.chatCalls.last;
    expect(call['message'], 'Delete');
    expect(call['page_id'], 'career');
    expect(call['passage'], contains('I lead the analytics team'));
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

  testWidgets(
      "Ayma's notes tab: tapping a sentence also goes straight to Edit with "
      'Ayma, with the same sticky highlight and privacy-aware quick chip as '
      'Story/Public view', (tester) async {
    final api = _FakeApi()
      ..aiSections = const [
        StorySection(
          pageId: 'values', pageType: 'values', title: 'Values',
          // `isPrivateAt` keys off an explicit `{{private}}` span, not the
          // section-level `visibility` field — same rule as Story/Public
          // view — so the fixture needs one to exercise "Make public".
          body: '{{private}}Family matters most to me.{{/private}}',
          visibility: 'private',
        ),
      ];
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text("Ayma's notes"));
    await tester.pumpAndSettle();

    SelectableMarkdown valuesMarkdown() =>
        tester.widgetList<SelectableMarkdown>(find.byType(SelectableMarkdown))
            .firstWhere((w) => w.raw.contains('Family matters most'));
    expect(valuesMarkdown().selectedRange, isNull);

    await tester.tap(find.textContaining('Family matters most'));
    await tester.pumpAndSettle();

    // Straight to the sheet, no floating toolbar, same as the other tabs.
    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Ask Ayma'), findsNothing);
    // This note is private, so the sheet offers "Make public" — proof the
    // Ayma's notes tab resolves privacy context exactly like Story does,
    // not always defaulting to one side.
    expect(find.text('Make public'), findsOneWidget);
    expect(find.text('Make private'), findsNothing);
    expect(valuesMarkdown().selectedRange, isNotNull);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(valuesMarkdown().selectedRange, isNull);
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

  // Network images fail to load in a widget test (there's no real photo
  // host) — that's expected noise from every photo-section test below, not
  // a fresh mystery to debug each time.
  void silenceImageLoadErrors() {
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {};
    addTearDown(() => FlutterError.onError = originalOnError);
  }

  List<AiNotePhoto> mixedSourcePhotos() => const [
        AiNotePhoto(url: 'https://example.com/profile.jpg', source: 'profile'),
        AiNotePhoto(url: 'https://example.com/chat.jpg', source: 'chat'),
        AiNotePhoto(url: 'https://example.com/web.jpg', source: 'web'),
        AiNotePhoto(url: 'https://example.com/deleted.jpg', source: 'chat', deleted: true),
      ];

  testWidgets('the Photos section renders inline, grouped, with no "view all" link',
      (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    expect(find.text('A few glimpses into my world.'), findsOneWidget);
    expect(find.textContaining('3 photos'), findsOneWidget); // deleted excluded
    expect(find.text('PROFILE PHOTOS (1)'), findsOneWidget);
    expect(find.text('FROM CHAT & SKILLS (1)'), findsOneWidget);
    expect(find.text('FOUND ON THE INTERNET (1)'), findsOneWidget);
    expect(find.textContaining('DELETED BY YOU'), findsNothing);
    expect(find.textContaining('VIEW ALL PHOTOS'), findsNothing);
  });

  testWidgets('the Photos section renders before narrative sections', (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    final photosTop = tester.getTopLeft(find.text('01  PHOTOS')).dy;
    final careerTop = tester.getTopLeft(find.textContaining('CAREER')).dy;
    expect(photosTop, lessThan(careerTop));
  });

  testWidgets('tapping a photo thumbnail opens the photo detail sheet', (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(find.byType(PhotoDetailSheet), findsOneWidget);
  });

  testWidgets('Public view only shows profile photos — no chat/web/deleted groups',
      (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);
    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();

    expect(find.text('PROFILE PHOTOS (1)'), findsOneWidget);
    expect(find.textContaining('FROM CHAT & SKILLS'), findsNothing);
    expect(find.textContaining('FOUND ON THE INTERNET'), findsNothing);
    expect(find.textContaining('DELETED BY YOU'), findsNothing);
  });

  testWidgets("Ayma's notes shows every group, including deleted", (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);
    await tester.tap(find.text("Ayma's notes"));
    await tester.pumpAndSettle();

    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('PROFILE PHOTOS (1)'), findsOneWidget);
    expect(find.text('FROM CHAT & SKILLS (1)'), findsOneWidget);
    expect(find.text('FOUND ON THE INTERNET (1)'), findsOneWidget);
    expect(find.text('DELETED BY YOU (1)'), findsOneWidget);
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

  testWidgets('web-findings has no report link before any self-dive report exists',
      (tester) async {
    // Mirrors the Appearance card's own "no report yet" case — the link only
    // ever renders once the backend hands back a real `reportId`.
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'career', pageType: 'career', title: 'Career',
          body: 'I build things.', visibility: 'public',
        ),
        StorySection(
          pageId: 'web-findings', pageType: 'misc', title: 'Web findings',
          body: 'Overall confidence: high.', visibility: 'private',
          isSkill: true, reportId: null,
        ),
      ]);
    await _pumpWithRouter(tester, api);
    await tester.pumpAndSettle();

    expect(find.text('What Ayma found online.'), findsOneWidget);
    expect(find.text('VIEW WEB FINDINGS'), findsNothing);
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

    expect(find.text('Edit with Ayma'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, "that's wrong, I left in 2023");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    final call = api.chatCalls.last;
    expect(call['page_id'], 'career');
    expect(call['timeline_entry_id'], 'e1');
  });
}
