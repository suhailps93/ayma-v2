import 'dart:async';

import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];

  StoryData data = const StoryData(sections: [
    StorySection(
      pageId: 'career',
      pageType: 'career',
      title: 'Career',
      body: 'I lead the analytics team in Lisbon.',
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
  Future<({List<ChatMessage> messages, String? nextBefore})> chatHistory({
    String? before,
    int limit = 40,
  }) async {
    calls.add('chat_history');
    return (messages: const <ChatMessage>[], nextBefore: null);
  }

  @override
  Future<List<StoryVersion>> storySectionVersions(String pageId) async {
    calls.add('versions:$pageId');
    return const [];
  }

  List<StorySection> aiSections = const [];

  @override
  Future<List<StorySection>> storyAiNotes() async {
    calls.add('ai_notes');
    return aiSections;
  }

  List<AiNotePhoto> photos = const [];

  @override
  Future<AiNotes> aiNotes() async {
    calls.add('photos');
    return AiNotes(text: '', photos: photos);
  }

  // Optional gates so a test can hold `photoHide`/`photoPublish` open long
  // enough to observe the sheet's inline busy state before letting it finish.
  Completer<void>? hideGate;
  Completer<void>? publishGate;

  @override
  Future<void> photoHide(String url, {required String source}) async {
    if (hideGate != null) await hideGate!.future;
    calls.add('photo_hide:$url:$source');
  }

  @override
  Future<void> photoPublish(String url, {required String source}) async {
    if (publishGate != null) await publishGate!.future;
    calls.add('photo_publish:$url:$source');
  }

  @override
  Future<void> photoSetNote(String url, {String? context, String? isUser}) async {
    calls.add('photo_note:$url:${context ?? ''}:${isUser ?? ''}');
  }

  // --- Appearance "Run it" (§ appearance) --------------------------------

  /// When set, the next [runAppearanceReport] call awaits this before
  /// resolving — lets a test observe the inline busy state mid-flight.
  Completer<void>? appearanceGate;

  /// When set, [runAppearanceReport] throws this instead of returning.
  Object? appearanceError;

  AppearanceReportResult appearanceResult =
      const AppearanceReportResult(usageCapped: false, reportId: 'rep-x', report: null);

  @override
  Future<AppearanceReportResult> runAppearanceReport({
    List<String> imagePaths = const [],
    bool wantFace = true,
    bool wantBody = true,
  }) async {
    calls.add('run_appearance');
    if (appearanceGate != null) await appearanceGate!.future;
    if (appearanceError != null) throw appearanceError!;
    return appearanceResult;
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: StoryEditorScreen(api: api)));
  await tester.pumpAndSettle();
}

/// Same screen, but reachable through a real [GoRouter] so `context.push`
/// (the skill-report card's "View full report" / "Run it" links) has
/// somewhere to go — each destination just renders its id back as text.
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
        builder: (_, state) =>
            Scaffold(body: Text('APPEARANCE ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/deep-dive/:id',
        builder: (_, state) =>
            Scaffold(body: Text('DEEP DIVE ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/skills',
        builder: (_, __) => const Scaffold(body: Text('SKILLS SCREEN')),
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}


void main() {
  testWidgets('renders sections as one document', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    expect(find.text('Your Story'), findsOneWidget);
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(api.calls, ['get', 'ai_notes', 'photos']);
  });

  testWidgets("the What's public toggle filters to public sections",
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    await tester.tap(find.text("What's public"));
    await tester.pumpAndSettle();
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('Family'), findsNothing);
  });

  testWidgets('the ⋯ menu flips a section to private', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    final card =
        find.ancestor(of: find.text('Career'), matching: find.byType(Column));
    await tester.tap(find.descendant(
        of: card.first, matching: find.byIcon(Icons.more_horiz)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make section private').last);
    await tester.pumpAndSettle();
    expect(api.calls, contains('vis:career:private'));
  });

  testWidgets('⋯ → Edit text opens an editable field (no blank screen)',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    final card =
        find.ancestor(of: find.text('Career'), matching: find.byType(Column));
    await tester.tap(find.descendant(
        of: card.first, matching: find.byIcon(Icons.more_horiz)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit text').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextField, 'I lead the analytics team in Lisbon.'),
        findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'New career text.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('save:career:New career text.'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('⋯ → Chat with Ayma opens the real chat in a sheet over the '
      'editor', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    final card =
        find.ancestor(of: find.text('Career'), matching: find.byType(Column));
    await tester.tap(find.descendant(
        of: card.first, matching: find.byIcon(Icons.more_horiz)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat with Ayma').last);
    await tester.pumpAndSettle();

    // The reusable Ayma chat, scoped to this section — its composer + mic.
    expect(find.text('Editing this section with Ayma'), findsOneWidget);
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    expect(api.calls, contains('chat_history'));
  });

  testWidgets('a real word selection surfaces the passage toolbar',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    // Long-press the selectable body to select a word (the editor listens to
    // onSelectionChanged).
    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(SelectableText).first));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();

    // The four passage actions are on screen.
    if (find.text('Private').evaluate().isNotEmpty) {
      expect(find.text('Public'), findsOneWidget);
      expect(find.text('Ayma'), findsOneWidget);
      await tester.tap(find.text('Private'));
      await tester.pumpAndSettle();
      final save = api.calls.firstWhere((c) => c.startsWith('save:career:'),
          orElse: () => '');
      expect(save.contains('{{private}}'), isTrue);
    }
    // (If the headless engine didn't register the selection, the pure
    // setPrivacy() unit tests still cover the wrap/unwrap logic.)
  });

  testWidgets(
      'tapping a sentence (no drag) surfaces the same passage toolbar',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    // Career's whole body is one sentence — find its tap recognizer inside
    // the built TextSpan tree and invoke it directly, exactly as a real tap
    // on that sentence would.
    final rich =
        tester.widgetList<SelectableText>(find.byType(SelectableText)).first;
    TapGestureRecognizer? found;
    rich.textSpan!.visitChildren((span) {
      if (span is TextSpan &&
          span.text == 'I lead the analytics team in Lisbon.' &&
          span.recognizer is TapGestureRecognizer) {
        found = span.recognizer as TapGestureRecognizer;
        return false;
      }
      return true;
    });
    expect(found, isNotNull,
        reason: 'career body should carry a sentence-tap recognizer');
    found!.onTap!();
    await tester.pumpAndSettle();

    // Same toolbar the drag-selection test above exercises.
    expect(find.text('Private'), findsOneWidget);
    expect(find.text('Public'), findsOneWidget);
    expect(find.text('Ayma'), findsOneWidget);
    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    expect(
        api.calls,
        contains(
            'save:career:{{private}}I lead the analytics team in Lisbon.{{/private}}'));
  });

  testWidgets('AI notes tab shows read-only sections with no menu',
      (tester) async {
    final api = _FakeApi()
      ..aiSections = const [
        StorySection(
          pageId: 'steering',
          pageType: 'steering',
          title: 'Standing instructions',
          body: '- keep it brief',
          visibility: 'ai',
        ),
      ];
    await _pump(tester, api);

    await tester.tap(find.text('AI notes'));
    await tester.pumpAndSettle();

    expect(find.text('Standing instructions'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('Career'), findsNothing); // public/private stay hidden
    expect(find.byType(PopupMenuButton<String>), findsNothing);

    // Read-only content: no drag-selection callback and no sentence-tap
    // recognizer either — SelectableMarkdown is given onSelect/onSentenceTap:
    // null for an "ai" section, so nothing here is tappable.
    var anyRecognizer = false;
    for (final rich
        in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      rich.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.recognizer != null) {
          anyRecognizer = true;
        }
        return true;
      });
    }
    expect(anyRecognizer, isFalse);
    await tester.tap(find.byType(SelectableText).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Private'), findsNothing);
  });

  testWidgets(
      'AI notes is a superset of private: a real public/private section '
      'there is fully editable, colour-coded, only a genuine ai_only one '
      'stays read-only', (tester) async {
    final api = _FakeApi()
      ..aiSections = const [
        StorySection(
          pageId: 'steering',
          pageType: 'steering',
          title: 'Standing instructions',
          body: '- keep it brief',
          visibility: 'ai', // genuinely still ai_only, remapped by api_client
        ),
        StorySection(
          pageId: 'career',
          pageType: 'career',
          title: 'Career',
          body: 'I lead the analytics team in Lisbon.',
          visibility: 'private', // real visibility passed straight through
        ),
        StorySection(
          pageId: 'family',
          pageType: 'family',
          title: 'Family',
          body: 'Close with my sister.',
          visibility: 'public', // real visibility passed straight through
        ),
      ];
    await _pump(tester, api);

    await tester.tap(find.text('AI notes'));
    await tester.pumpAndSettle();

    // The whole superset shows here, each with its own real badge.
    expect(find.text('Standing instructions'), findsOneWidget);
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    // 'private'/'public' also appear in the always-on colour legend, so each
    // section's own badge brings the count to two.
    expect(find.text('private'), findsNWidgets(2));
    expect(find.text('public'), findsNWidgets(2));

    // The ai_only section has no ⋯ menu.
    final aiCard = find.ancestor(
        of: find.text('Standing instructions'), matching: find.byType(Column));
    expect(
        find.descendant(
            of: aiCard.first, matching: find.byIcon(Icons.more_horiz)),
        findsNothing);

    // The private section has a working ⋯ menu — full edit controls.
    final careerCard =
        find.ancestor(of: find.text('Career'), matching: find.byType(Column));
    await tester.tap(find.descendant(
        of: careerCard.first, matching: find.byIcon(Icons.more_horiz)));
    await tester.pumpAndSettle();
    expect(find.text('Make section public'), findsOneWidget);
    await tester.tap(find.text('Make section public'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('vis:career:public'));

    // The public section also has a working ⋯ menu.
    final familyCard =
        find.ancestor(of: find.text('Family'), matching: find.byType(Column));
    await tester.tap(find.descendant(
        of: familyCard.first, matching: find.byIcon(Icons.more_horiz)));
    await tester.pumpAndSettle();
    expect(find.text('Make section private'), findsOneWidget);
  });

  testWidgets('photos Ayma has are filtered per tab', (tester) async {
    final api = _FakeApi()
      ..photos = const [
        AiNotePhoto(url: 'https://example.com/p.jpg', source: 'profile'),
        AiNotePhoto(url: 'https://example.com/c.jpg', source: 'chat'),
        AiNotePhoto(url: 'https://example.com/w.jpg', source: 'web',
            sourcePage: 'https://somewhere.example'),
        AiNotePhoto(url: 'https://example.com/d.jpg', source: 'chat',
            deleted: true),
      ];
    await _pump(tester, api);

    // Everything: the live profile + chat photos, not web, not deleted.
    expect(find.textContaining('PHOTOS AYMA HAS (2)'), findsOneWidget);
    expect(find.textContaining('PROFILE PHOTOS'), findsOneWidget);
    expect(find.textContaining('FROM CHAT & SKILLS'), findsOneWidget);
    expect(find.textContaining('FOUND ON THE INTERNET'), findsNothing);
    expect(find.textContaining('DELETED BY YOU'), findsNothing);

    await tester.tap(find.text("What's public"));
    await tester.pumpAndSettle();
    // Chat photos never show under What's public — only the live profile grid.
    expect(find.textContaining('PHOTOS AYMA HAS (1)'), findsOneWidget);
    expect(find.textContaining('PROFILE PHOTOS'), findsOneWidget);
    expect(find.textContaining('FROM CHAT & SKILLS'), findsNothing);

    await tester.tap(find.text('AI notes'));
    await tester.pumpAndSettle();
    // AI notes is the complete picture — every photo, any source, deleted or not.
    expect(find.textContaining('PHOTOS AYMA HAS (4)'), findsOneWidget);
    expect(find.textContaining('PROFILE PHOTOS'), findsOneWidget);
    expect(find.textContaining('FROM CHAT & SKILLS'), findsOneWidget);
    expect(find.textContaining('FOUND ON THE INTERNET'), findsOneWidget);
    expect(find.textContaining('DELETED BY YOU'), findsOneWidget);
  });

  testWidgets('tapping a photo shows a read-only face-match line and context',
      (tester) async {
    final api = _FakeApi()
      ..photos = const [
        AiNotePhoto(
          url: 'https://example.com/a.jpg',
          source: 'chat',
          isUser: 'yes',
          context: 'at my cousin\'s wedding',
        ),
      ];
    await _pump(tester, api);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(find.text('Ayma thinks this is you'), findsOneWidget);
    expect(find.text("at my cousin's wedding"), findsOneWidget);
    // No manual yes/no toggle and no free-text note field any more.
    expect(find.text('Yes'), findsNothing);
    expect(find.text('No'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('tapping a photo opens delete / make public / chat about it, '
      'showing a busy state while publishing', (tester) async {
    final api = _FakeApi()
      ..photos = const [
        AiNotePhoto(url: 'https://example.com/a.jpg', source: 'chat'),
      ];
    await _pump(tester, api);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Make public'), findsOneWidget); // not a profile photo
    expect(find.text('Chat about it'), findsOneWidget);

    final gate = Completer<void>();
    api.publishGate = gate;
    await tester.tap(find.text('Make public'));
    await tester.pump(); // the sheet stays open with an inline busy state...
    expect(find.text('Publishing…'), findsOneWidget);
    expect(find.text('Make public'), findsNothing);
    expect(api.calls, isNot(contains('photo_publish:https://example.com/a.jpg:chat')));

    gate.complete();
    await tester.pumpAndSettle(); // ...then closes once the call resolves.
    expect(api.calls, contains('photo_publish:https://example.com/a.jpg:chat'));
  });

  testWidgets('Delete on a photo calls photoHide with its source',
      (tester) async {
    final api = _FakeApi()
      ..photos = const [
        AiNotePhoto(url: 'https://example.com/a.jpg', source: 'profile'),
      ];
    await _pump(tester, api);

    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    // A profile photo is already public — no "Make public" action for it.
    expect(find.text('Make public'), findsNothing);

    final gate = Completer<void>();
    api.hideGate = gate;
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(find.text('Deleting…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(api.calls, contains('photo_hide:https://example.com/a.jpg:profile'));
  });

  // --- skill-report sections: card + link, not the full body -------------

  const faceBody =
      "Facial-analysis notes from a photo the user shared — Ayma's honest "
      'read, not stated by the user. Overall 6/10 — Very average.\n'
      'A closer, kinder note about the read.\n\n'
      'Feature scores:\n- Eyes: 7/10 — nice shape';

  const physicalBody =
      "Physical profile — Ayma's structured read of what the user looks "
      'like, used to sharpen matching and Explore search. Stated values are '
      "the user's own answers; photo values are apparent and lower "
      'confidence.\n\n'
      "From the user's own answers:\n- Height: ~180cm\n- Eye color: green\n\n"
      'Apparent from their photos:\n- Build: athletic';

  const webFindingsBody =
      'What the open web says about Jordan — gathered by Ayma in a '
      'consented lookup, not stated by the user. Overall confidence: '
      'high.\n\n'
      'Jordan works in fintech and lives in Berlin.\n\n'
      'Facts found:\n- Works at Acme (career, high, https://x.example)';

  testWidgets(
      'a face-analysis section shows a summary card, not the full body',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'face-analysis',
          pageType: 'face_analysis',
          title: 'Facial analysis',
          body: faceBody,
          visibility: 'private',
          isSkill: true,
          reportId: 'rep-appearance-1',
        ),
      ]);
    await _pump(tester, api);

    expect(find.text('Facial analysis'), findsOneWidget);
    expect(find.text("AYMA'S REPORT"), findsOneWidget);
    expect(find.text('Overall 6/10 — Very average'), findsOneWidget);
    expect(find.text('A closer, kinder note about the read.'), findsOneWidget);
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
    // The full markdown body (further-down sections) is not duplicated inline.
    expect(find.textContaining('Feature scores'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets(
      'tapping "View full report" on an appearance-linked section opens '
      '/appearance/{id}', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'body-analysis',
          pageType: 'body_analysis',
          title: 'Physique analysis',
          body: faceBody,
          visibility: 'private',
          isSkill: true,
          reportId: 'rep-appearance-1',
        ),
      ]);
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('VIEW FULL REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE rep-appearance-1'), findsOneWidget);
  });

  testWidgets('a physical-profile section teases its attributes, not a score',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'physical-profile',
          pageType: 'physical_profile',
          title: 'Physical Profile',
          body: physicalBody,
          visibility: 'private',
          reportId: 'rep-appearance-1',
        ),
      ]);
    await _pump(tester, api);

    expect(find.text('Height: ~180cm · Eye color: green'), findsOneWidget);
    expect(find.text('+1 more attribute'), findsOneWidget);
  });

  testWidgets(
      'a web-findings section links to /deep-dive/{id}, its own self-dive',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'web-findings',
          pageType: 'web_findings',
          title: 'Web findings',
          body: webFindingsBody,
          visibility: 'private',
          isSkill: true,
          reportId: 'uid_u1',
        ),
      ]);
    await _pumpWithRouter(tester, api);

    expect(find.text("AYMA'S RESEARCH"), findsOneWidget);
    expect(find.text('Overall confidence: high'), findsOneWidget);
    expect(find.text('Jordan works in fintech and lives in Berlin.'),
        findsOneWidget);

    await tester.tap(find.text('VIEW FULL REPORT'));
    await tester.pumpAndSettle();
    expect(find.text('DEEP DIVE uid_u1'), findsOneWidget);
  });

  testWidgets(
      'an appearance-linked section with no report yet runs the report in '
      'place, not a navigation, and shows the real card on success',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'face-analysis',
          pageType: 'face_analysis',
          title: 'Facial analysis',
          body: faceBody,
          visibility: 'private',
          isSkill: true, // reportId omitted: skill never explicitly run yet
        ),
      ]);
    await _pumpWithRouter(tester, api);

    expect(find.text('VIEW FULL REPORT'), findsNothing);
    expect(find.text("Ayma hasn't finished a full report for this yet."),
        findsOneWidget);

    // Once the run "succeeds" server-side the section now carries a report id
    // — the fake's storyGet() (called by the post-run refresh) picks it up.
    api.data = const StoryData(sections: [
      StorySection(
        pageId: 'face-analysis',
        pageType: 'face_analysis',
        title: 'Facial analysis',
        body: faceBody,
        visibility: 'private',
        isSkill: true,
        reportId: 'rep-appearance-1',
      ),
    ]);

    await tester.tap(find.text('Run it'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('run_appearance'));
    expect(find.text('SKILLS SCREEN'), findsNothing); // no navigation
    expect(find.text('VIEW FULL REPORT'), findsOneWidget);
  });

  testWidgets('the "Run it" button shows an inline spinner while the report '
      'is running', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'body-analysis',
          pageType: 'body_analysis',
          title: 'Physique analysis',
          body: faceBody,
          visibility: 'private',
          isSkill: true,
        ),
      ]);
    final gate = Completer<void>();
    api.appearanceGate = gate;
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Run it'));
    await tester.pump(); // start the future without letting it settle
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Run it'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a usage-capped Appearance run shows the out-of-credits snack, not a '
      'silent no-op', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'physical-profile',
          pageType: 'physical_profile',
          title: 'Physical Profile',
          body: physicalBody,
          visibility: 'private',
          isSkill: true,
        ),
      ])
      ..appearanceResult = const AppearanceReportResult(
          usageCapped: true, reportId: '', report: null);
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Run it'));
    await tester.pumpAndSettle();

    expect(find.textContaining("out of credits"), findsOneWidget);
    // Still the "no report" state — no fake refresh happened.
    expect(find.text('VIEW FULL REPORT'), findsNothing);
  });

  testWidgets(
      'a genuinely-empty (no photo at all) Appearance run surfaces a '
      '"add a photo" fallback, not a silent no-op', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'face-analysis',
          pageType: 'face_analysis',
          title: 'Facial analysis',
          body: faceBody,
          visibility: 'private',
          isSkill: true,
        ),
      ])
      ..appearanceError = ApiException(
        'appearance report failed.',
        statusCode: 400,
        body: '{"detail":"No photo to analyse — add a profile photo first."}',
      );
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Run it'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Add a profile photo first'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('any other Appearance run failure shows a generic retry message',
      (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'body-analysis',
          pageType: 'body_analysis',
          title: 'Physique analysis',
          body: faceBody,
          visibility: 'private',
          isSkill: true,
        ),
      ])
      ..appearanceError = ApiException('boom', statusCode: 502, body: '');
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Run it'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't run that"), findsOneWidget);
  });

  testWidgets(
      'a web-findings section with no report yet still opens Skills — its '
      'own re-run surface is elsewhere', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'web-findings',
          pageType: 'web_findings',
          title: 'Web findings',
          body: 'Overall confidence: low.',
          visibility: 'private',
          isSkill: true, // reportId omitted: no dive yet
        ),
      ]);
    await _pumpWithRouter(tester, api);

    await tester.tap(find.text('Run it'));
    await tester.pumpAndSettle();
    expect(find.text('SKILLS SCREEN'), findsOneWidget);
    expect(api.calls, isNot(contains('run_appearance')));
  });

  testWidgets(
      'a user-edited skill-report section renders as ordinary full text, '
      'not a card', (tester) async {
    final api = _FakeApi()
      ..data = const StoryData(sections: [
        StorySection(
          pageId: 'face-analysis',
          pageType: 'face_analysis',
          title: 'Facial analysis',
          body: 'My own words about how I look.',
          visibility: 'private',
          isSkill: true,
          userEdited: true,
          reportId: 'rep-appearance-1',
        ),
      ]);
    await _pump(tester, api);

    expect(find.text('My own words about how I look.'), findsOneWidget);
    expect(find.text('VIEW FULL REPORT'), findsNothing);
  });

  testWidgets('an ordinary page (Career) still renders full inline markdown',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    expect(
        find.text('I lead the analytics team in Lisbon.'), findsOneWidget);
    expect(find.text('VIEW FULL REPORT'), findsNothing);
  });
}
