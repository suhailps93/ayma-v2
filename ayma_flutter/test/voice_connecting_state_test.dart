// Both voice entry points — the chat composer's mic button and the Ayma orb's
// "Ask Ayma" push-to-talk sheet — must show a distinct "Connecting…" /
// "Waking Ayma…" state while the session is still being established, and only
// flip to "Listening…" once the agent has genuinely joined (controller phase
// `live`). These tests drive the REAL [VoiceSessionController] phase machine
// through a [FakeVoiceTransport], so both paths are proven to share the same
// phase -> label/mode mapping rather than each asserting a hand-set state.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/ayma_logo_loader.dart';
import 'package:ayma_flutter/widgets/chat_composer.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

ApiClient _api() {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((request) async {
    switch (request.url.path) {
      case '/bootstrap':
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
      case '/chat/history':
        return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      case '/post-turn':
      case '/voice/context':
        return http.Response(jsonEncode({'ok': true}), 200);
      default:
        return http.Response('{}', 200,
            headers: const {'content-type': 'application/json; charset=utf-8'});
    }
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

/// The composer currently in the tree (both entry points render exactly one).
ComposerMode _composerMode(WidgetTester tester) =>
    tester.widget<ChatComposer>(find.byType(ChatComposer)).mode;

void main() {
  tearDown(() => VoiceSessionController.active = null);

  testWidgets(
    'chat composer mic: connecting shows "Connecting/Waking" + animated logo '
    'loader, not "Listening"; agent join flips to "Listening"',
    (tester) async {
      final transport = FakeVoiceTransport();
      final voice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
      );

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(apiClient: _api(), voiceController: voice),
      ));
      await tester.pumpAndSettle();

      // Entry point 1: tap the composer's mic. Do NOT mark the agent ready,
      // so the controller settles in `waking` (connect + mic published, agent
      // still cold-starting).
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(voice.phase, VoiceSessionPhase.waking);
      expect(_composerMode(tester), ComposerMode.connecting);
      expect(find.text('Waking Ayma…'), findsOneWidget);
      expect(find.text('Listening…'), findsNothing);
      expect(find.byType(AymaLogoLoader), findsOneWidget);
      // The lit capturing mic (listening) must be absent while connecting.
      expect(find.byIcon(Icons.mic_rounded), findsNothing);

      // The agent joins — now, and only now, we are genuinely listening.
      transport.markAgentReady();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(voice.phase, VoiceSessionPhase.live);
      expect(_composerMode(tester), ComposerMode.listening);
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byType(AymaLogoLoader), findsNothing);

      // Tear down the live session cleanly: `stop()` is fire-and-forget (its
      // awaited teardown only advances under `pump`, never a bare `await`, so
      // awaiting it here would hang), the pumps flush the cancellation of the
      // live session's real timers (screen-capture, ctx heartbeat, idle
      // guard), and unmounting disposes the composer's waveform ticker — all
      // of which `pumpAndSettle()` cannot do without hanging on the ticker.
      unawaited(voice.stop());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      voice.dispose();
    },
  );

  testWidgets(
    'Ask-Ayma orb sheet uses the identical connecting -> listening states',
    (tester) async {
      final transport = FakeVoiceTransport();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showAskAymaOverlay(
                context,
                api: _api(),
                ctx: const AskAymaContext(
                  pageId: 'career',
                  selectedText: 'I lead the analytics team in Lisbon.',
                ),
                voiceApiClient: _api(),
                voiceTransportFactory: () => transport,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Entry point 2: the sheet's mic button, same as the orb hold reaches.
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_composerMode(tester), ComposerMode.connecting);
      expect(find.text('Waking Ayma…'), findsOneWidget);
      expect(find.text('Listening…'), findsNothing);
      expect(find.byType(AymaLogoLoader), findsOneWidget);

      transport.markAgentReady();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(_composerMode(tester), ComposerMode.listening);
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byType(AymaLogoLoader), findsNothing);
    },
  );
}
