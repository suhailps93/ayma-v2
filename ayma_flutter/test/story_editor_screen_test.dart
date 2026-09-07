import 'package:ayma_flutter/screens/story_editor_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<String> calls = [];

  Map<String, StoryData> data = {
    'private': const StoryData(
      headVersionId: 'v1',
      sections: [
        StorySection(
          pageId: 'career',
          pageType: 'career',
          title: 'Career',
          body: 'Private career text.',
          visibility: 'private',
        ),
        StorySection(
          pageId: 'family',
          pageType: 'family',
          title: 'Family',
          body: 'Private family text.',
          visibility: 'private',
        ),
      ],
    ),
    'public': const StoryData(
      headVersionId: 'p1',
      sections: [
        StorySection(
          pageId: 'career',
          pageType: 'career',
          title: 'Career',
          body: 'Public career blurb.',
          visibility: 'public',
        ),
      ],
    ),
  };

  StoryEditResult editResult = const StoryEditResult(
    action: 'rewrite',
    revisedBody: 'Rewritten career line.',
  );

  @override
  Future<StoryData> storyGet(String side) async {
    calls.add('get:$side');
    return data[side]!;
  }

  @override
  Future<String> storySaveSection({
    required String pageId,
    required String side,
    required String body,
    String? visibility,
  }) async {
    calls.add('save:$side:$pageId:$body');
    return 'v2';
  }

  @override
  Future<StoryEditResult> storyEdit({
    required String pageId,
    required String side,
    required String selection,
    required String instruction,
  }) async {
    calls.add('edit:$pageId:$instruction');
    return editResult;
  }

  @override
  Future<String> storySeedPublic(String pageId) async {
    calls.add('seed:$pageId');
    return 'Seeded public draft.';
  }

  @override
  Future<List<StoryVersion>> storyVersions(String side) async => const [];
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: StoryEditorScreen(api: api)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the section tree and opens the first section',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    expect(find.text('Your Story'), findsOneWidget);
    expect(find.text('Career'), findsWidgets); // tree + editor header
    expect(find.text('Family'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Private career text.'),
      findsOneWidget,
    );
    expect(api.calls, ['get:private']);
  });

  testWidgets('the side toggle reloads the other side', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    await tester.tap(find.text('Public'));
    await tester.pumpAndSettle();

    expect(api.calls, ['get:private', 'get:public']);
    expect(
      find.widgetWithText(TextField, 'Public career blurb.'),
      findsOneWidget,
    );
  });

  testWidgets('editing a section and saving cuts a new version', (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    await tester.enterText(
        find.byType(TextField), 'I now lead the analytics team.');
    await tester.pumpAndSettle();

    expect(find.text('Save'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      api.calls,
      contains('save:private:career:I now lead the analytics team.'),
    );
  });

  testWidgets('highlight-to-chat rewrite shows a diff and Accept saves it',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api);

    // open the edit chat panel
    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();

    // the instruction field is the last TextField on screen
    await tester.enterText(find.byType(TextField).last, 'make it punchier');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(api.calls, contains('edit:career:make it punchier'));
    // the diff sheet is up
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(
      api.calls,
      contains('save:private:career:Rewritten career line.'),
    );
  });

  testWidgets('a move classification asks to confirm the move', (tester) async {
    final api = _FakeApi()
      ..editResult = const StoryEditResult(
        action: 'move',
        targetSide: 'public',
      );
    await _pump(tester, api);

    await tester.tap(find.byIcon(Icons.forum_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'make this public');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(find.textContaining('Move Career to your Public profile?'),
        findsOneWidget);
  });
}
