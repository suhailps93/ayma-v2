// Scout NOTE 219 leg b: in the per-bullet Ask-Ayma chat (a docked PARTIAL
// sheet scoped to one story bullet), tapping the "Make private" quick chip was
// a silent no-op — no user turn, no `/chat` call — while the SAME phrase typed
// in the expanded view worked. These tests drive the exact chip-tap send path
// and assert the scoped turn actually reaches `chatStream` with the bullet
// context the typed path carries.
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<Map<String, String>> streamCalls = [];

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
    streamCalls.add({
      'message': message,
      'storyPageId': storyPageId,
      'storyPassage': storyPassage,
    });
    yield ChatReplyEvent(const ChatResult(reply: 'Done — that bullet is private now.'));
  }
}

const _ctx = AskAymaContext(
  origin: AskAymaOrigin.story,
  pageId: 'page_about_me',
  selectedText: 'I grew up in Lisbon.',
  sectionTitle: 'About Me',
  quoteTitle: 'About Me',
  quoteText: 'I grew up in Lisbon.',
);

void main() {
  setUp(() {
    AymaSession.instance.store.seed(const []);
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
  });

  Future<_RecordingApi> pumpScopedBulletChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412 * 3, 1500 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _RecordingApi();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAskAymaOverlay(context, api: api, ctx: _ctx),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets(
      'tapping "Make private" in the docked per-bullet sheet sends the scoped '
      'turn with the bullet context (NOTE 219 leg b)', (tester) async {
    // Match the device: the shared conversation already has real history, so
    // the quick chips render ONLY via the partial-sheet path (not the
    // empty-conversation path), and the sheet is docked, not expanded.
    AymaSession.instance.store.seed([
      TranscriptTurn(role: TurnRole.ayma, text: 'Earlier hello', source: TurnSource.text),
    ]);
    final api = await pumpScopedBulletChat(tester);
    expect(aymaSheet.isExpanded, isFalse, reason: 'sheet must be docked/partial');

    // Docked partial sheet: the quick chip is present…
    expect(find.text('Make private'), findsOneWidget);

    // …and it renders in the composer section, NOT in the body Expanded
    // under the context card — that body region does not reliably receive
    // taps on-device (Scout NOTE 219 leg b). Guard the placement structurally.
    expect(find.byKey(const ValueKey('askAymaComposerChips')), findsOneWidget,
        reason: 'docked chips must live with the (tappable) composer');
    expect(find.byKey(const ValueKey('askAymaBodyChips')), findsNothing,
        reason: 'docked chips must NOT sit in the un-tappable body Expanded');

    await tester.tap(find.text('Make private'));
    await tester.pumpAndSettle();

    expect(api.streamCalls, hasLength(1),
        reason: 'the chip tap must reach chatStream, not be swallowed');
    expect(api.streamCalls.single['message'], 'Make private');
    // The bullet context the typed path carries must ride along.
    expect(api.streamCalls.single['storyPageId'], 'page_about_me');
    expect(api.streamCalls.single['storyPassage'], 'I grew up in Lisbon.');

    // The user turn landed in the shared conversation.
    final texts = [for (final t in AymaSession.instance.store.turns) t.text];
    expect(texts, contains('Make private'));
  });
}
