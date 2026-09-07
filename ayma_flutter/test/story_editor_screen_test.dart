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
  Future<StoryChatReply> storyEdit({
    required String pageId,
    required String selection,
    required List<Map<String, String>> messages,
  }) async {
    calls.add('edit:$pageId:${messages.last['text']}');
    return const StoryChatReply(
      reply: 'How about: I run the whole analytics org.',
      revisedBody: 'I run the whole analytics org in Lisbon.',
    );
  }

  @override
  Future<List<StoryVersion>> storySectionVersions(String pageId) async {
    calls.add('versions:$pageId');
    return const [];
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: StoryEditorScreen(api: api)));
  await tester.pumpAndSettle();
}

/// Long-press the first section's selectable text — Flutter selects the word
/// under the press and fires onSelectionChanged, which is what the editor
/// listens for.
Future<void> _selectWord(WidgetTester tester) async {
  await tester.longPress(find.byType(SelectableText).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders sections as one document', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    expect(find.text('Your Story'), findsOneWidget);
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(api.calls, ['get']);
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

  testWidgets('selecting a passage shows the toolbar and Make private wraps '
      'that word', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    await _selectWord(tester);
    expect(find.text('Make private'), findsOneWidget);

    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();

    final save = api.calls.firstWhere((c) => c.startsWith('save:career:'));
    expect(save.contains('{{private}}'), isTrue);
    expect(save.contains('{{/private}}'), isTrue);
  });

  testWidgets('Ask Ayma opens a thread and Apply shows a diff', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    await _selectWord(tester);
    await tester.tap(find.text('Ask Ayma'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Tell Ayma what to change…'),
        'make it bigger');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(api.calls, contains('edit:career:make it bigger'));
    expect(find.textContaining('I run the whole analytics org'), findsWidgets);
    expect(find.text('Apply this change'), findsOneWidget);

    await tester.tap(find.text('Apply this change'));
    await tester.pumpAndSettle();
    expect(find.text('Accept'), findsOneWidget); // the diff sheet
  });
}
