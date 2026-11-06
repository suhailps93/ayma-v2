// Voice in the "Edit with Ayma" sheet: push-to-talk over the existing LiveKit
// pipeline, transcribing a spoken utterance and routing it through the exact
// same `_send()` text path typed messages use (story context intact) — see
// `ask_ayma_overlay.dart` for why this is push-to-talk rather than full duplex.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

/// Records every `/chat` and `/chat/stream` call so a test can assert the
/// story-passage context rode along with a transcribed voice turn exactly as
/// it does for a typed one.
class _FakeChatApi extends ApiClient {
  _FakeChatApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<Map<String, String>> chatCalls = [];
  ChatResult reply = const ChatResult(reply: 'Done — made that more concise.');

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
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
  }) async* {
    // The sheet always tries the stream first — fail it so every call
    // exercises (and this test only has to assert on) the plain `chat` path.
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
    String screenPreviousRoute = '',
    String screenPreviousLabel = '',
    String clientMsgId = '',
    bool tourContinuation = false,
  }) async {
    chatCalls.add({
      'message': message,
      'story_page_id': storyPageId,
      'story_passage': storyPassage,
      'story_timeline_entry_id': storyTimelineEntryId,
    });
    return reply;
  }
}

/// A minimal `/bootstrap`-serving [ApiClient] for [VoiceSessionController] —
/// same shape as `voice_session_controller_test.dart`'s helper.
ApiClient _voiceApi() {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/bootstrap') {
      return http.Response(
        jsonEncode({
          'session_mode': 'marketing',
          'uid': 'u1',
          'livekit': {
            'token': 'tok-abc',
            'url': 'wss://example.livekit.cloud',
            'room': 'ayma-u1',
          },
        }),
        200,
      );
    }
    if (request.url.path == '/post-turn') {
      return http.Response(jsonEncode({'ok': true, 'persisted': 0}), 200);
    }
    if (request.url.path == '/voice/context') {
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    return http.Response('not found', 404);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

Future<void> _openSheet(
  WidgetTester tester, {
  required ApiClient api,
  required ApiClient voiceApi,
  required VoiceTransport Function() transportFactory,
  String pageId = 'career',
  String selectedText = 'I lead the analytics team in Lisbon.',
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showAskAymaOverlay(
            context,
            transcriptStore: TranscriptStore(),
            api: api,
            ctx: AskAymaContext(pageId: pageId, selectedText: selectedText),
            voiceApiClient: voiceApi,
            voiceTransportFactory: transportFactory,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Drives the sheet's mic button, then the fake transport, all the way to a
/// live push-to-talk capture (mirrors `voice_session_controller_test.dart`'s
/// `_startLive`).
Future<void> _startListening(
    WidgetTester tester, FakeVoiceTransport transport) async {
  await tester.tap(find.byIcon(Icons.mic_none_rounded));
  await tester.pump();
  transport.markAgentReady();
  await tester.pump();
  // The mic is published only once Ayma is genuinely conversing (her first
  // response), not merely when the agent joins — emit one so the session
  // reaches the real conversation-ready state (privacy fix 2026-11-03). Toggle
  // back to not-speaking so the composer settles on "listening", not
  // "aiSpeaking".
  transport.emitAgentSpeaking(true);
  transport.emitAgentSpeaking(false);
  await tester.pump();
  // Let the composer's AnimatedSwitcher/AnimatedSize crossfade from the text
  // row to the voice row fully finish (220ms) before asserting on which
  // icons are present — otherwise both rows are briefly in the tree mid-fade.
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  tearDown(() {
    // A controller left `active` by a failed test must not leak into the next.
    VoiceSessionController.active = null;
  });

  testWidgets('mic button starts a real voice engagement, not the old snackbar',
      (tester) async {
    final transport = FakeVoiceTransport();
    await _openSheet(
      tester,
      api: _FakeChatApi(),
      voiceApi: _voiceApi(),
      transportFactory: () => transport,
    );

    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    await _startListening(tester, transport);

    // The old stub showed this snackbar and never touched a real session.
    expect(find.text('Open the Ayma tab to talk by voice.'), findsNothing);
    // A real session is live: the composer switched to its voice row (mic
    // gone, "End voice" stop button showing) and the transport actually
    // connected/published the mic.
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    expect(transport.connectedUrl, 'wss://example.livekit.cloud');
    expect(transport.micCalls, [true]);
  });

  testWidgets('composer amplitude reflects the controller live values',
      (tester) async {
    final transport = FakeVoiceTransport();
    await _openSheet(
      tester,
      api: _FakeChatApi(),
      voiceApi: _voiceApi(),
      transportFactory: () => transport,
    );
    await _startListening(tester, transport);

    final composerBefore =
        tester.widget<ChatComposer>(find.byType(ChatComposer));
    expect(composerBefore.mode, ComposerMode.listening);
    expect(composerBefore.userAmplitude.value, 0);

    transport.emitMicLevel(0.9);
    await tester.pump();

    final composerAfter =
        tester.widget<ChatComposer>(find.byType(ChatComposer));
    // Not the old hardcoded-zero ValueNotifier — it moved with the real level.
    expect(composerAfter.userAmplitude.value, greaterThan(0));
  });

  testWidgets('sheet disposal while voice is active cleans up correctly',
      (tester) async {
    final transport = FakeVoiceTransport();
    await _openSheet(
      tester,
      api: _FakeChatApi(),
      voiceApi: _voiceApi(),
      transportFactory: () => transport,
    );
    await _startListening(tester, transport);
    expect(VoiceSessionController.active, isNotNull);

    // Close the sheet (the header's close button — same as Android back /
    // tap-outside) while still "live".
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // `VoiceSessionController.active` is nulled synchronously at the very top
    // of `dispose()`, before any teardown await — so this proves the sheet
    // actually called `dispose()` on its controller (not just discarded the
    // widget) without needing the rest of the async teardown to be observed.
    // (`transport.disconnect()`/`.dispose()` do get called by that teardown
    // in production; asserting their call counts here would require awaiting
    // that chain to completion, which does not resolve under `testWidgets`'
    // fake-time zone in this environment even for a trivial fake transport —
    // confirmed with a minimal repro with no sheet/controller involved at
    // all — so that part is exercised instead by
    // `voice_session_controller_test.dart`'s own `stop()` tests, which do not
    // hit this environment limitation.)
    expect(VoiceSessionController.active, isNull);

    // No leftover "a call is already active" block for the next attempt.
    await _openSheet(
      tester,
      api: _FakeChatApi(),
      voiceApi: _voiceApi(),
      transportFactory: () => FakeVoiceTransport(),
    );
    await tester.tap(find.byIcon(Icons.mic_none_rounded));
    await tester.pump();
    expect(find.textContaining('already on a voice call'), findsNothing);
  });

  testWidgets(
      'a finalized utterance routes through _send with story context intact',
      (tester) async {
    final transport = FakeVoiceTransport();
    final api = _FakeChatApi();
    await _openSheet(
      tester,
      api: api,
      voiceApi: _voiceApi(),
      pageId: 'career',
      selectedText: 'I lead the analytics team in Lisbon.',
      transportFactory: () => transport,
    );
    await _startListening(tester, transport);

    // Gemini Live's own turn-detection finalizes what the user said.
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'Make this more concise',
      isFinal: true,
    ));
    // A bounded pump loop, not `pumpAndSettle` — the composer briefly re-enters
    // a repeating-animation voice mode while easing back to flat, and
    // `pumpAndSettle` treats a still-repeating ticker as "never settles".
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(api.chatCalls, hasLength(1));
    expect(api.chatCalls.single['message'], 'Make this more concise');
    expect(api.chatCalls.single['story_page_id'], 'career');
    expect(api.chatCalls.single['story_passage'],
        'I lead the analytics team in Lisbon.');

    // The session was torn down before any spoken reply — back to text mode.
    // (Driven by the sheet's own `_listening` flag, not by waiting on the
    // controller's async teardown to reach `idle` — see `ask_ayma_overlay.dart`.)
    final composer = tester.widget<ChatComposer>(find.byType(ChatComposer));
    expect(composer.mode, ComposerMode.text);

    // The partial sheet lists no history (founder rule, Nov 2026) — expand
    // before asserting on the rendered transcript. Bounded pumps (the
    // 320ms expand animation), not `pumpAndSettle`, for the same
    // repeating-ticker reason as the loop above.
    await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The transcribed line and the reply both landed in the transcript.
    // (Scoped to the transcript list: the same "Make this more concise"
    // quick chip also pins above the composer once turns exist — § D13.)
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Make this more concise'),
      ),
      findsOneWidget,
    );
    expect(find.text('Done — made that more concise.'), findsOneWidget);
  });

  testWidgets(
      'declines to start a second session when the main tab call is already live',
      (tester) async {
    // Simulate the main Ayma tab already on a live call: a second, separate
    // controller becomes `VoiceSessionController.active`. Left in `waking`
    // (never `markAgentReady()`d) — `isActive` already covers that phase, and
    // it skips `_startScreenAwareness()`'s Firestore listener entirely, which
    // this test has no need to exercise.
    final otherTransport = FakeVoiceTransport();
    final other = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _voiceApi(),
      transportFactory: () => otherTransport,
    );
    await other.start();
    expect(other.isActive, isTrue);

    final sheetTransport = FakeVoiceTransport();
    await _openSheet(
      tester,
      api: _FakeChatApi(),
      voiceApi: _voiceApi(),
      transportFactory: () => sheetTransport,
    );

    await tester.tap(find.byIcon(Icons.mic_none_rounded));
    await tester.pumpAndSettle();

    // No second LiveKit connection was opened for the sheet.
    expect(sheetTransport.connectedUrl, isNull);
    expect(
      find.textContaining("already on a voice call"),
      findsOneWidget,
    );

    // Not awaited: `stop()`'s teardown chain does not resolve under
    // `testWidgets`' fake-time zone in this environment even for a trivial
    // fake transport (see the disposal test above) — but `active` is cleared
    // synchronously at the top of `stop()`, which is all `tearDown` below
    // needs to leave the next test clean. `unawaited` documents that this is
    // deliberate, not a dropped error.
    unawaited(other.stop());
  });
}
