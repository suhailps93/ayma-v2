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

    expect(c.phase, VoiceSessionPhase.live);
    expect(transport.connectedUrl, 'wss://example.livekit.cloud');
    expect(transport.connectedToken, 'tok-abc');
    expect(transport.micCalls, [true]);
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
    await c.start();

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
}
