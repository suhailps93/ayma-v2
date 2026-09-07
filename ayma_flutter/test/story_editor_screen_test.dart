import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];

  StoryData data = const StoryData(
    headVersionId: 'v1',
    sections: [
      StorySection(
        pageId: 'career',
        pageType: 'career',
        title: 'Career',
        body: 'I lead the analytics team.',
        visibility: 'public',
      ),
      StorySection(
        pageId: 'family',
        pageType: 'family',
        title: 'Family',
        body: 'Close with my sister.',
        visibility: 'private',
      ),
      StorySection(
        pageId: 'face-analysis',
        pageType: 'face_analysis',
        title: 'Facial analysis',
        body: '**6.9 / 10** — Above average',
        visibility: 'private',
        isSkill: true,
      ),
    ],
  );

  StoryEditResult editResult = const StoryEditResult(
    action: 'rewrite',
    revisedBody: 'I now lead the whole analytics org.',
  );

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
  Future<({String body, String headVersionId})> storySpanAction({
    required String pageId,
    required String selection,
    required String action,
  }) async {
    calls.add('span:$pageId:$action:$selection');
    return (body: 'updated body', headVersionId: 'v2');
  }

  @override
  Future<StoryEditResult> storyEdit({
    required String pageId,
    required String selection,
    required String instruction,
  }) async {
    calls.add('edit:$pageId:$instruction');
    return editResult;
  }

  @override
  Future<List<StoryVersion>> storyVersions() async => const [];
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: StoryEditorScreen(api: api)));
  await tester.pumpAndSettle();
}

/// Enter edit mode on a section via its ⋯ menu.
Future<void> _editSection(WidgetTester tester, String title) async {
  final card = find.ancestor(
    of: find.text(title),
    matching: find.byType(Column),
  );
  await tester.tap(find.descendant(
      of: card.first, matching: find.byIcon(Icons.more_horiz)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit text').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders sections as one document, skills last', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    expect(find.text('Your Story'), findsOneWidget);
    expect(find.text('Career'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text("FROM AYMA'S SKILLS"), findsOneWidget);
    expect(find.text('Facial analysis'), findsOneWidget);
    expect(api.calls, ['get']);
  });

  testWidgets("the 'What's public' toggle filters to public sections",
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    await tester.tap(find.text("What's public"));
    await tester.pumpAndSettle();

    expect(find.text('Career'), findsOneWidget); // public
    expect(find.text('Family'), findsNothing); // private, filtered out
  });

  testWidgets('editing a section and saving cuts a version', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    await _editSection(tester, 'Career');
    await tester.enterText(
        find.byType(TextField).first, 'I lead the analytics org now.');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('save:career:I lead the analytics org now.'));
  });

  testWidgets('the ⋯ menu can flip a section to private', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    final card = find.ancestor(
        of: find.text('Career'), matching: find.byType(Column));
    await tester.tap(find.descendant(
        of: card.first, matching: find.byIcon(Icons.more_horiz)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make private').last);
    await tester.pumpAndSettle();

    expect(api.calls, contains('vis:career:private'));
  });

  testWidgets('selecting text opens the passage chat with a Make-private chip',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    await _editSection(tester, 'Career');

    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    editable.controller.selection =
        const TextSelection(baseOffset: 0, extentOffset: 6); // "I lead"
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask Ayma about this'));
    await tester.pumpAndSettle();

    expect(find.text('Make private'), findsOneWidget);
    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('span:career:private:I lead'));
  });

  testWidgets('a free-text edit returns a diff and Accept saves it',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);
    await _editSection(tester, 'Career');

    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    editable.controller.selection =
        const TextSelection(baseOffset: 0, extentOffset: 6);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask Ayma about this'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'make it bigger');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(api.calls, contains('edit:career:make it bigger'));
    expect(find.text('Accept'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(api.calls,
        contains('save:career:I now lead the whole analytics org.'));
  });
}
