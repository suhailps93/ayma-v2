import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

final postTurnCalls = <Map<String, dynamic>>[];

/// Drive a controller from `idle` all the way to `live`: `start()` lands in
/// `waking`, then the fake transport's one-shot `agentReady` promotes it.
Future<void> _startLive(
    VoiceSessionController c, FakeVoiceTransport transport) async {
  await c.start();
  transport.markAgentReady();
  await Future<void>.delayed(Duration.zero);
}

ApiClient _api({
  Map<String, dynamic>? bootstrapBody,
  int status = 200,
}) {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/bootstrap') {
      return http.Response(
        jsonEncode(
          bootstrapBody ??
              {
                'session_mode': 'marketing',
                'uid': 'u1',
                'livekit': {
                  'token': 'tok-abc',
                  'url': 'wss://example.livekit.cloud',
                  'room': 'ayma-u1',
                },
              },
        ),
        status,
      );
    }
    if (request.url.path == '/post-turn') {
      postTurnCalls.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true, 'persisted': 0}), 200);
    }
    return http.Response('not found', 404);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

void main() {
  test('start() bootstraps, connects the transport, and publishes the mic',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();

    // Room + mic are up, but the agent hasn't joined yet.
    expect(c.phase, VoiceSessionPhase.waking);
    expect(c.isActive, isTrue);
    expect(transport.connectedUrl, 'wss://example.livekit.cloud');
    expect(transport.connectedToken, 'tok-abc');
    expect(transport.micCalls, [true]);
  });

  test('waking -> live when the agent signals ready', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();
    expect(c.phase, VoiceSessionPhase.waking);

    transport.markAgentReady();
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.live);
  });

  test('a warm worker (ready on connect) goes straight to live', () async {
    final transport = FakeVoiceTransport()..agentReadyOnConnect = true;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.live);
  });

  test('waking times out into an error when the agent never joins', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      wakingTimeout: const Duration(milliseconds: 20),
    );

    await c.start();
    expect(c.phase, VoiceSessionPhase.waking);

    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(c.phase, VoiceSessionPhase.error);
    expect(c.errorMessage, contains("didn't pick up"));
    expect(transport.disconnectCalls, 1);
    expect(transport.disposeCalls, 1);
  });

  test('agentReady after the timeout does not resurrect the session', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      wakingTimeout: const Duration(milliseconds: 20),
    );

    await c.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.phase, VoiceSessionPhase.error);

    transport.markAgentReady();
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.error);
  });

  test('stop() from waking returns to idle cleanly', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();
    expect(c.phase, VoiceSessionPhase.waking);

    await c.stop();

    expect(c.phase, VoiceSessionPhase.idle);
    expect(transport.disconnectCalls, 1);
    expect(transport.disposeCalls, 1);
  });

  test('start() fails cleanly when the mic cannot be enabled', () async {
    final transport = FakeVoiceTransport()..failMic = true;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();

    expect(c.phase, VoiceSessionPhase.error);
    expect(c.errorMessage, contains('microphone'));
    expect(transport.disconnectCalls, 1);
  });

  test('start() surfaces a bootstrap failure as an error phase', () async {
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(status: 503),
      transportFactory: FakeVoiceTransport.new,
    );

    await c.start();

    expect(c.phase, VoiceSessionPhase.error);
  });

  test('agentSpeaking reflects transport events while live', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    transport.agentSpeakingController.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.agentSpeaking, isTrue);

    transport.agentSpeakingController.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(c.agentSpeaking, isFalse);
  });

  test('toggleMute flips mic state only when live', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.toggleMute();
    expect(c.muted, isFalse); // no-op before a session

    await c.start();
    await c.toggleMute();
    expect(c.muted, isFalse); // still a no-op while waking

    transport.markAgentReady();
    await Future<void>.delayed(Duration.zero);
    await c.toggleMute();
    expect(c.muted, isTrue);
    expect(transport.micCalls, [true, false]);
  });

  test('stop() disconnects and returns to idle', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();

    await c.stop();

    expect(c.phase, VoiceSessionPhase.idle);
    expect(transport.disconnectCalls, 1);
    expect(transport.disposeCalls, 1);
  });

  test('relayed transcript segments land in the shared store', () async {
    final transport = FakeVoiceTransport();
    final store = TranscriptStore();
    final c = VoiceSessionController(
      transcriptStore: store,
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();

    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'hey ayma',
      isFinal: true,
    ));
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'agent_transcript',
      text: 'hey you',
      isFinal: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(store.turns.map((t) => (t.role, t.text, t.source)), [
      (TurnRole.user, 'hey ayma', TurnSource.voice),
      (TurnRole.ayma, 'hey you', TurnSource.voice),
    ]);
  });

  test('stop() persists the session window when a sessionId is set', () async {
    postTurnCalls.clear();
    final transport = FakeVoiceTransport();
    final store = TranscriptStore()
      ..addTurn(TurnRole.user, 'said aloud', TurnSource.voice);
    final c = VoiceSessionController(
      transcriptStore: store,
      sessionId: 's-voice-000001',
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();
    await c.stop();
    await Future<void>.delayed(Duration.zero);

    expect(postTurnCalls, hasLength(1));
    expect(postTurnCalls.single['session_id'], 's-voice-000001');
    expect(postTurnCalls.single['recent_turns'], [
      {'role': 'user', 'text': 'said aloud'},
    ]);
  });
}
