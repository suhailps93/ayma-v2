// A capped Ayma reply inside the "Edit with Ayma" sheet must render a
// persistent, always-visible Get credits affordance — not rely solely on a
// SnackBar, which is easy to miss or may have already auto-dismissed by the
// time the user looks (see `ask_ayma_overlay.dart`'s `_send`). Same treatment
// `chat_screen.dart`'s `_TranscriptLine` gives `turn.capped`.
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  ChatResult reply = const ChatResult(reply: 'ok');

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
    String matchReportId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String clientMsgId = '',
  }) async* {
    // The sheet always tries the stream first — fail it so every call
    // exercises the plain `chat` path this test asserts on.
    throw ApiException('no stream in tests');
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
    String matchReportId = '',
    bool profileEdit = false,
    String photoUrl = '',
    String photoSource = '',
    String screen = '',
    String screenSubjectUid = '',
    String screenSubjectName = '',
    String screenNote = '',
    String clientMsgId = '',
  }) async =>
      reply;
}

Future<void> _pumpSheet(WidgetTester tester, ApiClient api) async {
  final router = GoRouter(
    initialLocation: '/story',
    routes: [
      GoRoute(
        path: '/story',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAskAymaOverlay(
                context,
                api: api,
                ctx: const AskAymaContext(
                  pageId: 'career',
                  selectedText: 'I lead the analytics team in Lisbon.',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/profile/usage/plans',
        builder: (_, __) => const Scaffold(body: Text('USAGE PAGE')),
      ),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'a capped reply in the Edit with Ayma sheet renders a persistent '
      'Get credits pill', (tester) async {
    final api = _FakeApi()
      ..reply = const ChatResult(
        reply: "I've used up the shared assistant budget on your account "
            'for now, so I need to pause here.',
        usageCapped: true,
      );
    await _pumpSheet(tester, api);

    await tester.enterText(find.byType(TextField).last, 'make this shorter');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // The message itself still renders…
    expect(find.textContaining("I've used up the shared assistant budget"),
        findsOneWidget);
    // …alongside a persistent, always-visible Get credits affordance, not just a
    // SnackBar that could already be gone.
    expect(find.text('Get credits'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
  });

  testWidgets('tapping Get credits in the sheet opens the plans screen',
      (tester) async {
    final api = _FakeApi()
      ..reply = const ChatResult(reply: 'capped', usageCapped: true);
    await _pumpSheet(tester, api);

    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Get credits'));
    await tester.pumpAndSettle();

    expect(find.text('USAGE PAGE'), findsOneWidget);
  });

  testWidgets('a normal (non-capped) reply shows no Get credits pill',
      (tester) async {
    final api = _FakeApi()..reply = const ChatResult(reply: 'all good');
    await _pumpSheet(tester, api);

    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('all good'), findsOneWidget);
    expect(find.text('Get credits'), findsNothing);
  });
}
