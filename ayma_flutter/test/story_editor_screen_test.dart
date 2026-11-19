import 'dart:async';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/services/dev_panel_session.dart';
import 'package:ayma_flutter/widgets/ask_ayma_action.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
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

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];
  final List<Map<String, String>> chatCalls = [];

  /// The shared main-photo setting the Story cover now reads (the public
  /// profile's primary/order-0 photo). First url = the starred main.
  List<String> mainPhotos = const [];

  @override
  Future<PublicProfile> publicProfile(String otherUid) async {
    calls.add('public_profile');
    return PublicProfile.fromMap({'uid': otherUid, 'photos': mainPhotos});
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
    List<String>? faceMediaIds, List<String>? bodyMediaIds,
  }) async {
    calls.add('run_appearance');
    return runAppearance!();
  }
  List<StorySection> aiSections = const [];
  List<AiNotePhoto> photos = const [];

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

  final List<(String, List<StoryBullet>)> bulletSaves = [];
  final List<(String, List<StoryBullet>)> bulletCreates = [];
  List<BulletSection>? bulletSections;

  @override
  Future<List<BulletSection>> profileBullets() async {
    calls.add('bullets_get');
    return bulletSections ?? const [];
  }

  /// The Node-Visualiser story tree the body now renders (2o). Empty by
  /// default so the appearance / photos / web tests see a clean story body;
  /// the narrative test sets a populated tree.
  GraphTree storyTree = GraphTree.fromMap(const {
    'surface': 'story',
    'sections': [],
  });

  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async {
    calls.add('graph_tree:$surface');
    return storyTree;
  }

  /// `GET /report/{type}/{id}/tree` — Ayma's Notes now renders `story_ai_notes`
  /// through the shared Node-Visualiser (2o P6), the report tree fetched by
  /// reportType/reportId. Built straight from [aiSections] (report-linked /
  /// empty pages excluded, exactly as the real `report_tree` adapter does), so
  /// a test stays honest about what nodes actually reach the tree.
  @override
  Future<GraphTree> reportTree(String reportType, String reportId) async {
    calls.add('report_tree:$reportType:$reportId');
    final source = switch (reportType) {
      'story_ai_notes' => aiSections,
      _ => const <StorySection>[],
    };
    final sections = <Map<String, dynamic>>[];
    var order = 0;
    for (final s in source) {
      if (_fakeReportLinkedPageIds.contains(s.pageId)) continue;
      if (s.body.trim().isEmpty) continue;
      order++;
      sections.add({
        'page_type': s.pageType,
        'title': s.title,
        'order': order,
        'nodes': [
          {
            'id': '${s.pageId}_0',
            'section': s.pageId,
            'label': s.title,
            'text': s.body,
            'answer_type': 'text',
            'level': 1,
            'visibility': s.visibility,
            'subtree_visibility': s.visibility,
          }
        ],
      });
    }
    return GraphTree.fromMap({'surface': 'report', 'sections': sections});
  }

  @override
  Future<void> profileBulletsSave(String pageId, List<StoryBullet> bullets) async =>
      bulletSaves.add((pageId, bullets));

  @override
  Future<void> profileBulletsCreate(String pageType, List<StoryBullet> bullets) async =>
      bulletCreates.add((pageType, bullets));

  Object? failStoryGet;

  @override
  Future<StoryData> storyGet() async {
    calls.add('get');
    if (failStoryGet != null) throw failStoryGet!;
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

  bool failPhotos = false;

  @override
  Future<List<AiNotePhoto>> photoNodes() async {
    calls.add('photos');
    if (failPhotos) throw StateError('photos unavailable');
    return photos;
  }

  @override
  Future<void> deletePhotoNode(String nodeId) async {
    calls.add('photo_delete:$nodeId');
  }

  @override
  Future<void> setPhotoNodeVisibility(String nodeId, String visibility) async {
    calls.add('photo_visibility:$nodeId:$visibility');
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
    bool noRetry = false,
    Duration? timeout,
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
          isSelf: true, otherUid: '', subjectImage: '',
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
    String graphNodeId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    String matchReportId = '',
    String sharedKind = '',
    String sharedRefId = '',
    String sharedSubjectUid = '',
    String sharedSubjectName = '',
    String sharedRefVersion = '',
    String replyImagePath = '',
    String sharedCardKind = '',
    String sharedCardUid = '',
    String sharedCardName = '',
    String sharedCardPhoto = '',
    String sharedCardRefId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String screenRoute = '',
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
    CallStateSnapshot callState = const CallStateSnapshot.none(),
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
    String graphNodeId = '',
    String storyPassage = '',
    String storyTimelineEntryId = '',
    String deepDiveReportId = '',
    String deepDiveTarget = '',
    String appearanceFindingId = '',
    String matchReportId = '',
    String sharedKind = '',
    String sharedRefId = '',
    String sharedSubjectUid = '',
    String sharedSubjectName = '',
    String sharedRefVersion = '',
    String replyImagePath = '',
    String sharedCardKind = '',
    String sharedCardUid = '',
    String sharedCardName = '',
    String sharedCardPhoto = '',
    String sharedCardRefId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String screenRoute = '',
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String screenDetail = '',
    String screenVisible = '',
    String clientMsgId = '',
    bool tourContinuation = false,
    CallStateSnapshot callState = const CallStateSnapshot.none(),
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

/// The standalone, dev-only Ayma's Notes page (same fakes as the Story pump).
Future<void> _pumpNotes(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/notes',
    routes: [
      GoRoute(
        path: '/notes',
        builder: (_, __) => AymaNotesScreen(api: api, myUid: 'u1'),
      ),
      GoRoute(
        path: '/appearance/:id',
        builder: (_, state) => Scaffold(body: Text('APPEARANCE ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/deep-dive/:id',
        builder: (_, state) => Scaffold(body: Text('DEEP DIVE ${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // The sheet is the main chat now (§ D13) — reset its shared store and
    // open-state between tests so exchanges never leak across them.
    AymaSession.instance.store.seed(const []);
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
  });
  testWidgets(
      'the Story screen has neither the Public view nor the Ayma\'s notes tab',
      (tester) async {
    final api = _FakeApi();
    await _pumpWithRouter(tester, api);

    expect(find.text('Public view'), findsNothing);
    expect(find.text("Ayma's notes"), findsNothing);
    expect(find.text("Ayma's Notes"), findsNothing);
    // The private Story content is shown directly, with no tab bar above it.
    expect(find.textContaining('Your Story'), findsOneWidget);
  });

  testWidgets(
      'the Story cover reads the SHARED main photo (public profile primary), '
      'not a separately-picked first photo', (tester) async {
    final api = _FakeApi()
      ..mainPhotos = const [
        'https://cdn/main-starred.jpg',
        'https://cdn/other.jpg',
      ];
    await _pumpWithRouter(tester, api);

    // It reads the ONE source of truth — the public profile's primary photo.
    expect(api.calls, contains('public_profile'));
    // The cover hero renders that exact (starred) photo.
    expect(
      find.byWidgetPredicate(
          (w) => w is AymaPhoto && w.url == 'https://cdn/main-starred.jpg'),
      findsOneWidget,
    );
  });


  List<StorySection> appearance({String visibility = 'private', String? reportId = 'current',
      bool edited = false, String? body}) => [
    for (final id in ['face-analysis', 'body-analysis', 'physical-profile'])
      StorySection(pageId: id, pageType: 'misc', title: id,
          body: body ?? 'Summary for $id.\nSecond paragraph kept in full.',
          visibility: visibility, isSkill: true, reportId: reportId, userEdited: edited),
  ];

  testWidgets('Story: Appearance groups three pages behind one report link', (tester) async {
    final rows = appearance(edited: true);
    final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
    await _pumpWithRouter(tester, api);
    for (final label in ['FACE', 'PHYSIQUE', 'PROFILE']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('Second paragraph kept in full.'), findsNWidgets(3));
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
    await tester.tap(find.text('VIEW FULL REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE current'), findsOneWidget);
  });

  testWidgets("Ayma's Notes: Appearance groups three pages behind one report link",
      (tester) async {
    final rows = appearance(edited: true);
    final api = _FakeApi()..aiSections = rows;
    await _pumpNotes(tester, api);
    for (final label in ['FACE', 'PHYSIQUE', 'PROFILE']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
    await tester.tap(find.text('VIEW FULL REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE current'), findsOneWidget);
  });

  for (final visibility in ['private', 'ai', 'ai_only', 'unknown']) {
    testWidgets('Story shows only the private Appearance ($visibility)', (tester) async {
      final rows = appearance(visibility: visibility);
      final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
      await _pumpWithRouter(tester, api);
      if (visibility == 'private') {
        // Private is the only visibility that surfaces on the Story.
        expect(find.text('FACE'), findsOneWidget);
        expect(find.text('VIEW FULL REPORT'), findsOneWidget);
      } else {
        // AI-only appearance never surfaces on the Story — it lives only in
        // the dev-only Ayma's Notes.
        expect(find.text('FACE'), findsNothing);
        expect(find.text('VIEW FULL REPORT'), findsNothing);
      }
    });
  }

  testWidgets("Ayma's Notes shows the Appearance card regardless of visibility",
      (tester) async {
    final rows = appearance(visibility: 'ai');
    final api = _FakeApi()..aiSections = rows;
    await _pumpNotes(tester, api);
    expect(find.text('FACE'), findsOneWidget);
    // In Ayma's Notes the card carries its visibility tag.
    expect(find.text('AI ONLY'), findsOneWidget);
  });

  testWidgets('Story: mixed-visibility Appearance stays private and finds a later report id',
      (tester) async {
    final rows = [
      appearance(visibility: 'public', reportId: ' ').first,
      appearance()[1],
      appearance(visibility: 'public')[2],
    ];
    final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
    await _pumpWithRouter(tester, api);
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
  });

  testWidgets("Ayma's Notes: mixed-visibility Appearance shows the PRIVATE tag",
      (tester) async {
    final rows = [
      appearance(visibility: 'public', reportId: ' ').first,
      appearance()[1],
      appearance(visibility: 'public')[2],
    ];
    final api = _FakeApi()..aiSections = rows;
    await _pumpNotes(tester, api);
    expect(find.text('PRIVATE'), findsOneWidget);
    await tester.tap(find.text('VIEW FULL REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE current'), findsOneWidget);
  });

  testWidgets('Story: Run it refreshes the Appearance card in place', (tester) async {
    final rows = appearance(reportId: null);
    final pending = Completer<AppearanceReportResult>();
    final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows
      ..runAppearance = () => pending.future;
    await _pumpWithRouter(tester, api);
    await tester.tap(find.text('Run it'));
    await tester.pump();
    expect(find.text('Run it'), findsNothing);
    expect(api.calls.where((c) => c == 'run_appearance'), hasLength(1));
    api.data = StoryData(sections: appearance());
    pending.complete(const AppearanceReportResult(usageCapped: false, reportId: 'current', report: null));
    await tester.pumpAndSettle();
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
  });

  testWidgets("Ayma's Notes: Run it refreshes the Appearance card in place",
      (tester) async {
    final rows = appearance(reportId: null);
    final pending = Completer<AppearanceReportResult>();
    final api = _FakeApi()..aiSections = rows
      ..runAppearance = () => pending.future;
    await _pumpNotes(tester, api);
    await tester.tap(find.text('Run it'));
    await tester.pump();
    expect(find.text('Run it'), findsNothing);
    expect(api.calls.where((c) => c == 'run_appearance'), hasLength(1));
    api.aiSections = appearance();
    pending.complete(const AppearanceReportResult(usageCapped: false, reportId: 'current', report: null));
    await tester.pumpAndSettle();
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
  });

  for (final failure in ['run', 'credits']) {
    testWidgets('Story: Appearance handles $failure and restores Run it', (tester) async {
      final rows = appearance(reportId: null, body: '');
      final api = _FakeApi()..data = StoryData(sections: rows)..aiSections = rows;
      api.runAppearance = () async {
        if (failure == 'run') throw StateError('failed');
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

  testWidgets("Ayma's Notes: a failed refresh after Run it restores Run it",
      (tester) async {
    final rows = appearance(reportId: null, body: '');
    final api = _FakeApi()..aiSections = rows;
    api.runAppearance = () async {
      // The post-run notes refresh throws — the card must recover, not crash.
      api.failNotes = true;
      return const AppearanceReportResult(usageCapped: false, reportId: '', report: null);
    };
    await _pumpNotes(tester, api);
    await tester.tap(find.text('Run it'));
    await tester.pumpAndSettle();
    expect(find.text('Run it'), findsOneWidget);
    expect(find.text("Couldn't run that — try again."), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Story: the narrative renders through the Node-Visualiser — section '
      'title + its public node bullet, ai_only filtered, no legacy career block',
      (tester) async {
    final api = _FakeApi()
      // The story tree the backend serves for this surface: the public career
      // bullet only (ai_only is filtered server-side, so it never arrives).
      ..storyTree = GraphTree.fromMap(const {
        'surface': 'story',
        'sections': [
          {
            'page_type': 'career',
            'title': 'Career',
            'order': 1,
            'nodes': [
              {
                'id': 'career_0',
                'section': 'career',
                'label': 'Career',
                'text': 'I lead the analytics team in Lisbon.',
                'answer_type': 'text',
                'level': 1,
                'visibility': 'public',
                'subtree_visibility': 'public',
              }
            ],
          }
        ],
      });
    await _pumpWithRouter(tester, api);

    expect(api.calls, contains('graph_tree:story'));
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('I lead the analytics team in Lisbon.'), findsOneWidget);
    // Each node is a single tappable row (tap → node chat window, where the
    // visibility / delete / chat-to-edit actions now live).
    expect(find.byKey(const Key('node_row_career_0')), findsOneWidget);
    // Regression (founder-found Nov 16 2026): Career is the graph section ONLY.
    // The legacy career-timeline subsystem rendered a SECOND, duplicate numbered
    // "CAREER & EDUCATION" block (+ an "Add your LinkedIn" nudge) below it — both
    // are deleted and must never render again.
    expect(find.textContaining('CAREER & EDUCATION'), findsNothing);
    expect(find.text('Add your LinkedIn profile'), findsNothing);
    expect(find.byKey(const ValueKey('add_linkedin')), findsNothing);
    // Ayma-only is never shown in Your Story (founder order, Nov 15 2026): the
    // filtered tree carries no ai_only node, so its text never appears.
    expect(find.text('Wants to move into product.'), findsNothing);
  });

  testWidgets(
      "Ayma's Notes: narrative wiki pages render via the story_ai_notes "
      'Node-Visualiser, with no invented per-passage confidence figure',
      (tester) async {
    final api = _FakeApi()
      ..aiSections = const [
        StorySection(
          pageId: 'values', pageType: 'values', title: 'Values',
          body: 'Family matters most to me.', visibility: 'private',
        ),
      ];
    await _pumpNotes(tester, api);

    // The body now fetches the story_ai_notes report tree (2o P6), not the old
    // block report.
    expect(api.calls, contains('report_tree:story_ai_notes:u1'));
    expect(find.text('Values'), findsOneWidget);
    expect(find.byKey(const Key('node_row_values_0')), findsOneWidget);
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
        // A deleted-but-retained image: moved to Ayma-only, so it must never
        // appear on the Story surface (founder retention rule Nov 18).
        AiNotePhoto(
            url: 'https://example.com/retained.jpg',
            source: 'chat',
            visibility: 'ayma_only'),
      ];

  testWidgets('the Photos section renders inline, grouped, with no "view all" link',
      (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    expect(find.text('A few glimpses into my world.'), findsOneWidget);
    expect(find.textContaining('3 photos'), findsOneWidget); // Ayma-only excluded
    expect(find.text('PROFILE PHOTOS (1)'), findsOneWidget);
    expect(find.text('FROM CHAT & SKILLS (1)'), findsOneWidget);
    expect(find.text('FOUND ON THE INTERNET (1)'), findsOneWidget);
    expect(find.textContaining('AYMA-ONLY'), findsNothing); // never on the Story
    expect(find.textContaining('VIEW ALL PHOTOS'), findsNothing);
  });

  testWidgets('Story Photos view surfaces the retained Ayma-only group when the '
      'Developer panel is unlocked (owner-visibility, Scout NOTE 256)',
      (tester) async {
    // Owner-visibility facet: a deleted-but-retained image (ayma_only) must be
    // findable by the owner in his Photos view when dev mode is on — not vanish
    // everywhere — while still never touching the story body or public surface.
    DevPanelSession.instance.unlocked.value = true;
    addTearDown(() => DevPanelSession.instance.unlocked.value = false);
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    expect(find.text('PROFILE PHOTOS (1)'), findsOneWidget);
    // The retained Ayma-only image now shows under its labelled, dev-gated group.
    expect(find.text('AYMA-ONLY — KEPT, NOT ON YOUR PROFILE (1)'), findsOneWidget);
  });

  // NOTE 248: the strip is node-driven now. A previously-described photo must
  // show Ayma's read (from the node), never "Ayma hasn't described this photo
  // yet" (the URL-hash read-orphaning bug).
  testWidgets('a described photo shows its read from the node, not the '
      '"hasn\'t described" fallback', (tester) async {
    final api = _FakeApi()
      ..photos = const [
        AiNotePhoto(
          id: 'emergent.image.leaf',
          url: 'https://example.com/leaf.jpg',
          source: 'chat',
          context: 'A close-up of a green leaf.',
          isUser: 'no',
        ),
      ];
    silenceImageLoadErrors();
    await _pumpWithRouter(tester, api);

    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('A close-up of a green leaf.'), findsOneWidget);
    expect(find.textContaining("hasn't described this photo yet"), findsNothing);
  });

  // NOTE 248 (the 408 that silently rendered 0 PHOTOS): the node-driven strip
  // has a real empty state and a real error+retry state — never a silent 0.
  testWidgets('the Photos strip shows a real EMPTY state when there are no '
      'photos', (tester) async {
    final api = _FakeApi()..photos = const []; // loads, resolves empty
    await _pumpWithRouter(tester, api);

    expect(find.textContaining('No photos yet'), findsOneWidget);
  });

  testWidgets('the Photos strip shows an ERROR + retry state when the load '
      'fails (never a silent 0)', (tester) async {
    final api = _FakeApi()..failPhotos = true;
    await _pumpWithRouter(tester, api);

    expect(find.textContaining("Couldn't load your photos"), findsOneWidget);
    expect(find.byKey(const ValueKey('photos_retry')), findsOneWidget);

    // Retry recovers once the load succeeds.
    api.failPhotos = false;
    api.photos = mixedSourcePhotos();
    silenceImageLoadErrors();
    await tester.tap(find.byKey(const ValueKey('photos_retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining("Couldn't load your photos"), findsNothing);
    expect(find.text('A few glimpses into my world.'), findsOneWidget);
  });

  testWidgets('the Photos section renders before narrative sections', (tester) async {
    final api = _FakeApi()
      ..photos = mixedSourcePhotos()
      // A narrative section in the Node-Visualiser tree to sit below Photos.
      ..storyTree = GraphTree.fromMap(const {
        'surface': 'story',
        'sections': [
          {
            'page_type': 'career',
            'title': 'Career',
            'order': 1,
            'nodes': [
              {
                'id': 'career_0',
                'section': 'career',
                'label': 'Career',
                'text': 'I lead the analytics team in Lisbon.',
                'answer_type': 'text',
                'level': 1,
                'visibility': 'public',
                'subtree_visibility': 'public',
              }
            ],
          }
        ],
      });
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    final photosTop = tester.getTopLeft(find.text('01  PHOTOS')).dy;
    final careerTop = tester.getTopLeft(find.text('Career')).dy;
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

  testWidgets(
      'the photo detail sheet\'s "Chat about it" opens the unified node partial '
      'window with the photo attached as a graph-node context', (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpWithRouter(tester, api);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    // Styled through the shared widget now, not a one-off FilledButton.icon.
    final chatAction = find.widgetWithText(AskAymaAction, 'Chat about it');
    expect(chatAction, findsOneWidget);

    await tester.tap(chatAction);
    await tester.pumpAndSettle();

    // Unified onto the node partial window: the overlay hosts the shared
    // ChatScreen with a graphNode context carrying the photo as an image node
    // (not the old photoUrl/photoSource path).
    expect(find.byType(ChatScreen), findsOneWidget);
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    final ctx = chat.askAymaContext;
    expect(ctx, isNotNull);
    expect(ctx!.origin, AskAymaOrigin.graphNode);
    expect(ctx.nodeImageUrl, 'https://example.com/profile.jpg');
    // The photo is pinned as the persistent image context card.
    expect(find.byType(AymaPhoto), findsWidgets);
  });

  testWidgets("Ayma's Notes shows every group, including the retained Ayma-only "
      'images', (tester) async {
    final api = _FakeApi()..photos = mixedSourcePhotos();
    silenceImageLoadErrors();

    await _pumpNotes(tester, api);

    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('PROFILE PHOTOS (1)'), findsOneWidget);
    expect(find.text('FROM CHAT & SKILLS (1)'), findsOneWidget);
    expect(find.text('FOUND ON THE INTERNET (1)'), findsOneWidget);
    // The owner's Ayma-only Photos view surfaces the retained (deleted) image.
    expect(find.text('AYMA-ONLY — KEPT, NOT ON YOUR PROFILE (1)'), findsOneWidget);
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
        isSelf: true, otherUid: '', subjectImage: '',
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


  // --- privacy: the cover stats header never shows another account's data ---
  //
  // R2-C6/C7 regression. The "N TOPICS / N PHOTOS / N WEB FINDS" cover
  // (`_StoryCover`) is derived from the story screen's own in-memory
  // `_sections`/`_photos`, loaded once in `initState` for whoever was signed
  // in then. If the signed-in user changes while this screen stays mounted
  // (e.g. a route left over from an account switch), it must NEVER paint the
  // previous account's cover — a ghost of another user's stats. See the
  // `_userChanged` guard in `story_editor_screen.dart`.

  /// Pumps the Story screen whose injected `myUid` is driven by [uid], so a
  /// test can flip the signed-in user WITHOUT recreating the screen's State
  /// (the exact "same screen, different account" condition the ghost needs).
  Future<void> pumpSwappable(
      WidgetTester tester, _FakeApi api, ValueNotifier<String> uid) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/story',
      routes: [
        GoRoute(
          path: '/story',
          builder: (_, __) => ValueListenableBuilder<String>(
            valueListenable: uid,
            builder: (_, u, __) => StoryEditorScreen(api: api, myUid: u),
          ),
        ),
        GoRoute(
            path: '/deep-dive/:id',
            builder: (_, state) => Scaffold(
                body: Text('DEEP DIVE ${state.pathParameters['id']}'))),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'the cover never shows a previous account\'s stats after the signed-in '
      'user changes under the mounted screen', (tester) async {
    // Account A has a story, so its cover renders.
    final api = _FakeApi();
    final uid = ValueNotifier<String>('userA');
    addTearDown(uid.dispose);
    await pumpSwappable(tester, api, uid);

    // A's cover is on screen.
    expect(find.text('Your Story'), findsOneWidget);
    expect(find.textContaining('your story takes'), findsNothing);

    // A DIFFERENT account signs in under the still-mounted screen, with its
    // own (here: empty) story. The backend now answers for account B.
    api.data = const StoryData(sections: []);
    api.photos = const [];
    uid.value = 'userB';
    await tester.pumpAndSettle();

    // The previous account's cover must be GONE — only B's own clean empty
    // state, never A's "N topics / N photos" ghost stacked on top.
    expect(find.text('Your Story'), findsNothing);
    expect(
        find.text(
            'Share something in a chat with Ayma and your story fills in here.'),
        findsOneWidget);
  });

  testWidgets(
      'a fresh/empty-story account renders a clean empty state with no cover '
      'stats at all', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [])
      ..photos = const [];
    await _pumpWithRouter(tester, api);

    // No cover block (no "Your Story" / topics / photos), just the empty state.
    expect(find.text('Your Story'), findsNothing);
    expect(
        find.text(
            'Share something in a chat with Ayma and your story fills in here.'),
        findsOneWidget);
  });

  testWidgets(
      'Story: a tree with duplicated pageTypes (demo-test1 shape) renders '
      'through the Node-Visualiser with no duplicate-key crash or error card',
      (tester) async {
    Map<String, dynamic> sec(String pt, String title, int order, String nid,
            String text) =>
        {
          'page_type': pt,
          'title': title,
          'order': order,
          'nodes': [
            {
              'id': nid,
              'section': pt,
              'label': title,
              'text': text,
              'answer_type': 'text',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
            }
          ],
        };
    final api = _FakeApi()
      ..storyTree = GraphTree.fromMap({
        'surface': 'story',
        'sections': [
          sec('dealbreakers', 'Core Non-Negotiables', 3, 'b1',
              'Must want children.'),
          sec('dealbreakers', 'Non-Negotiables', 3, 'b2', 'Never smoke.'),
          sec('family', 'Family', 7, 'b3', 'Close to parents.'),
          sec('family', 'Family 2', 7, 'b4', 'Brother in Chicago.'),
        ],
      });
    await _pumpWithRouter(tester, api);

    expect(tester.takeException(), isNull);
    expect(find.text('Something didn\'t load'), findsNothing);
    expect(find.text('Could not load your story'), findsNothing);
    expect(find.text('Core Non-Negotiables'), findsOneWidget);
    expect(find.text('Non-Negotiables'), findsOneWidget);
    expect(find.text('Must want children.'), findsOneWidget);
    expect(find.text('Never smoke.'), findsOneWidget);
    expect(find.text('Close to parents.'), findsOneWidget);
    expect(find.text('Brother in Chicago.'), findsOneWidget);
  });

  testWidgets(
      'Story load 408 does not trigger infinite reload loop and displays Retry',
      (tester) async {
    final api = _FakeApi()
      ..failStoryGet = ApiException('Request timed out — please try again.', statusCode: 408);

    await _pumpWithRouter(tester, api);
    // Advance past retry budget (45s)
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 16));
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();

    // Verify error is shown and not an infinite loop
    expect(find.textContaining('Could not load your story'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

    // Initial load attempted
    expect(api.calls.where((c) => c == 'get').isNotEmpty, isTrue);

    // Verify tapping Retry clears error and can succeed
    api.failStoryGet = null;
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load your story'), findsNothing);
  });
}
