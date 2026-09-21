import 'dart:async';

import 'package:ayma_flutter/models/living_report.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/photo_gallery.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The four page ids with their own dedicated report/card (§ Living Report
/// migration) — mirrors `story_editor_screen.dart`'s own `_reportLinkedPageIds`
/// and the real backend's `story.REPORT_LINKED_PAGE_IDS` / `report_adapters
/// ._narrative_pages`. Kept out of this fake's `GET /report/story_*` payload
/// the same way the real adapters now are.
const _fakeReportLinkedPageIds = {
  'face-analysis', 'body-analysis', 'physical-profile', 'web-findings',
};

List<String> _fakeSplitSentences(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return const [];
  return trimmed
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];
  final List<Map<String, String>> chatCalls = [];

  /// Every `POST /report/{type}/{id}/correct` this fake received — same
  /// rigor the file already applies to `chatCalls`/`chatStream`, now also
  /// covering the block-model tap-to-correct path `LivingReportView` uses.
  final List<Map<String, dynamic>> correctCalls = [];

  /// `GET /report/{report_type}/{report_id}` for `story_private` /
  /// `story_public` / `story_ai_notes` — built straight from [data]/
  /// [aiSections], the exact same sentence-splitting + report-linked-page
  /// exclusion the real `report_adapters.py` Story adapters apply, so a test
  /// against this fake stays honest about what block ids/content actually
  /// reach `LivingReportView`.
  LivingReport _storyReport(String reportType) {
    final source = switch (reportType) {
      'story_private' => data.sections,
      'story_ai_notes' => aiSections,
      'story_public' =>
        data.sections.where((s) => s.visibility == 'public').toList(),
      _ => const <StorySection>[],
    };
    final sections = <ReportSection>[];
    for (final s in source) {
      if (_fakeReportLinkedPageIds.contains(s.pageId)) continue;
      final sentences = _fakeSplitSentences(s.body);
      final blocks = sentences.isEmpty
          ? [
              ReportBlock({
                'block_id': 'page:${s.pageId}:empty',
                'type': 'section_head',
                'editable': false,
                'text': '(empty)',
              })
            ]
          : [
              for (var i = 0; i < sentences.length; i++)
                ReportBlock({
                  'block_id': 'page:${s.pageId}:sent:$i',
                  'type': 'text',
                  'editable': true,
                  'text': sentences[i],
                }),
            ];
      sections.add(ReportSection(heading: s.title, blocks: blocks));
    }
    final title = switch (reportType) {
      'story_public' => 'Story',
      'story_ai_notes' => "Ayma's Notes",
      _ => 'Your Story',
    };
    return LivingReport(
      title: title,
      sections: sections,
      meta: const ReportMeta(ownerUid: 'u1', viewerCanEdit: true),
    );
  }

  @override
  Future<LivingReport> getReport(String reportType, String reportId) async {
    calls.add('get_report:$reportType:$reportId');
    return _storyReport(reportType);
  }

  @override
  Future<ReportCorrectResult> correctReport(
    String reportType,
    String reportId, {
    required List<String> blockIds,
    required String scope,
    required String message,
  }) async {
    correctCalls.add({
      'report_type': reportType,
      'report_id': reportId,
      'block_ids': blockIds,
      'scope': scope,
      'message': message,
    });
    return ReportCorrectResult(
      ok: true,
      results: [
        for (final id in blockIds)
          ReportCorrectItem(blockId: id, ok: true, reply: 'Got it — updated.'),
      ],
    );
  }

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
      GoRoute(
        path: '/story',
        builder: (_, __) => StoryEditorScreen(api: api, myUid: 'u1'),
      ),
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

  testWidgets(
      'Story tab: narrative wiki pages render via the shared Living Report '
      'renderer (story_private), sentence-level block ids and no numbered '
      'eyebrow (§ Living Report migration)', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    expect(api.calls, contains('get_report:story_private:u1'));
    expect(find.textContaining('Your Story'), findsOneWidget);
    // Section headings are the ONE shared renderer's own uppercase style now
    // — no more per-section "01 " numbering (that convention belonged to the
    // old bespoke narrative widget; the shared renderer never numbers
    // sections, same as Appearance/deep-dive).
    expect(find.text('CAREER'), findsOneWidget);
    expect(find.textContaining('I lead the analytics team in Lisbon.'),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('livingReportBlock:page:career:sent:0')),
        findsOneWidget);
  });

  testWidgets('Public view tab fetches story_public and shows only public sections',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Public view'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('get_report:story_public:u1'));
    expect(find.textContaining('I lead the analytics team'), findsOneWidget);
    expect(find.textContaining('Close with my sister'), findsNothing);
  });

  testWidgets(
      'a bare short tap on a Story sentence does nothing — the fragile-tap '
      'guard applies here exactly like every other report type; only '
      'long-press resolves to anything', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.tap(
        find.byKey(const ValueKey('livingReportBlock:page:career:sent:0')));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsNothing);
  });

  testWidgets(
      'long-pressing one Story sentence selects it; "Chat about these" opens '
      'Edit with Ayma scoped to just that block id — the quick-action label '
      'now reflects the REPORT TYPE ("story_private" -> "Make public"), not '
      'the individual passage\'s own real privacy the way the old '
      'per-sentence mechanism did', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.longPress(
        find.byKey(const ValueKey('livingReportBlock:page:career:sent:0')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.text('Chat about these'));
    await tester.pumpAndSettle();

    expect(find.text('Edit with Ayma'), findsOneWidget);
    expect(find.text('Make public'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Make public'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.correctCalls, hasLength(1));
    final call = api.correctCalls.single;
    expect(call['report_type'], 'story_private');
    expect(call['report_id'], 'u1');
    expect(call['scope'], 'block');
    expect(call['block_ids'], ['page:career:sent:0']);
    expect(call['message'], 'Make public');
  });

  testWidgets(
      'multi-select bundles two Story sentence block ids under scope '
      '"block" and sends a free-text correction for both at once',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester.longPress(
        find.byKey(const ValueKey('livingReportBlock:page:career:sent:0')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey('livingReportBlock:page:career:sent:1')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Chat about these'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField).last, 'Combine these into one line.');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.correctCalls, hasLength(1));
    final call = api.correctCalls.single;
    expect(call['scope'], 'block');
    expect(call['block_ids'],
        unorderedEquals(<String>['page:career:sent:0', 'page:career:sent:1']));
    expect(call['message'], 'Combine these into one line.');
  });

  testWidgets(
      'tapping a section heading sends scope "section" with every sentence '
      'in that page', (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    await tester
        .tap(find.byKey(const ValueKey('livingReportSection:Career')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, "that's wrong");
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.correctCalls, hasLength(1));
    final call = api.correctCalls.single;
    expect(call['scope'], 'section');
    expect(call['block_ids'],
        unorderedEquals(<String>['page:career:sent:0', 'page:career:sent:1']));
  });

  testWidgets(
      "Ayma's Notes tab: narrative wiki pages render via story_ai_notes, "
      'with no invented per-passage confidence figure', (tester) async {
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

    expect(api.calls, contains('get_report:story_ai_notes:u1'));
    expect(find.text('VALUES'), findsOneWidget);
    expect(find.textContaining('Family matters most to me.'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
  });

  // "Why Ayma believes this" no longer lives on ordinary narrative passages
  // (§ Living Report migration — tap-to-chat, "why do you think this?", is
  // the new provenance mechanism for those, per the founder's own framing).
  // It's still reachable exactly where the bespoke, not-yet-block-modeled
  // Appearance card lives, in every tab — these three tests now exercise it
  // there instead of on a bare narrative section.
  List<StorySection> appearanceFixture() => const [
        StorySection(
          pageId: 'face-analysis', pageType: 'misc', title: 'face-analysis',
          body: 'Overall 8/10 — strong jawline.', visibility: 'private',
          isSkill: true, reportId: 'current',
        ),
      ];

  testWidgets(
      'tapping "Why Ayma believes this" on the Appearance card shows '
      'resolved provenance', (tester) async {
    final api = _FakeApi()..data = StoryData(sections: appearanceFixture());
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Why Ayma believes this'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('provenance:face-analysis'));
    expect(find.textContaining('Learned across 3 conversations'), findsOneWidget);
    expect(find.textContaining('Aug 19'), findsOneWidget);
  });

  testWidgets('a provenance source with a session id is tappable and opens the chat',
      (tester) async {
    final api = _FakeApi()
      ..data = StoryData(sections: appearanceFixture())
      ..provenanceResult = const SectionProvenance(
        pageId: 'face-analysis',
        conversationCount: 1,
        sources: [
          ProvenanceSource(
            date: '2026-08-19T00:00:00+00:00',
            sessionId: 's1',
          ),
        ],
      );
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Why Ayma believes this'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.textContaining('Conversation ·'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(api.calls, contains('chatHistory'));
  });

  testWidgets('a provenance source with no session id renders as a plain, non-tappable row',
      (tester) async {
    final api = _FakeApi()..data = StoryData(sections: appearanceFixture());
    await _pumpWithRouter(tester, api); // default fixture's source has no sessionId

    await tester.tap(find.text('Why Ayma believes this'));
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
    // Exact match, not `textContaining` — the standalone "CAREER & EDUCATION"
    // section (§ Living Report migration) now also contains the substring
    // "CAREER", so a loose match here would hit two widgets.
    final careerTop = tester.getTopLeft(find.text('CAREER')).dy;
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
