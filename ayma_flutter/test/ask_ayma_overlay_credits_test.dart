// A capped Ayma reply inside the "Edit with Ayma" sheet must render a
// persistent, always-visible Upgrade affordance — not rely solely on a
// toast, which is easy to miss or may have already auto-dismissed by the
// time the user looks (see `ask_ayma_overlay.dart`'s `_send`). Same treatment
// `chat_screen.dart`'s `_TranscriptLine` gives `turn.capped`. The partial
// sheet lists no history (founder rule, Nov 2026), so each test below
// expands to full screen before asserting on the rendered reply.
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
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
    String screenRoute = '',
    String screenDetail = '',
    String screenVisible = '',
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
    String screenRoute = '',
    String screenDetail = '',
    String screenVisible = '',
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
                transcriptStore: TranscriptStore(),
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
        path: '/profile/plan',
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
      'Upgrade pill', (tester) async {
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

    // The upgrade sheet opens automatically on the capped reply; dismiss it,
    // then expand — the reply renders in the full transcript, not the
    // partial sheet.
    await tester.tap(find.text('Keep exploring'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
    await tester.pumpAndSettle();

    // The message itself still renders…
    expect(find.textContaining("I've used up the shared assistant budget"),
        findsOneWidget);
    // …alongside a persistent, always-visible Upgrade affordance, not just a
    // toast that could already be gone.
    expect(find.text('Upgrade'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
  });

  testWidgets('tapping Upgrade in the sheet opens the plans screen',
      (tester) async {
    final api = _FakeApi()
      ..reply = const ChatResult(reply: 'capped', usageCapped: true);
    await _pumpSheet(tester, api);

    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep exploring'));
    await tester.pumpAndSettle();
    // The transcript pill only renders once expanded (partial lists no
    // history) — expand before tapping through it.
    await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upgrade'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade').last);
    await tester.pumpAndSettle();

    expect(find.text('USAGE PAGE'), findsOneWidget);
  });

  testWidgets('a normal (non-capped) reply shows no Upgrade pill',
      (tester) async {
    final api = _FakeApi()..reply = const ChatResult(reply: 'all good');
    await _pumpSheet(tester, api);

    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('all good'), findsOneWidget);
    expect(find.text('Upgrade'), findsNothing);
  });
}
