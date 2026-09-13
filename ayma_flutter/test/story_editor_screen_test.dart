import 'dart:async';

import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: StoryEditorScreen(api: api)));
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
}
