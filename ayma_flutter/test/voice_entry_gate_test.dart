// Resilience chunk D (degrade glue): the heartbeat → voice-entry mapping,
// the relay-first start it drives, and the per-session drop counter behind
// the two-drops switch offer.
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/connection_heartbeat.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_entry_gate.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

ApiClient _api() {
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

void main() {
  setUp(() {
    AppContext.instance.clear();
    VoiceSessionController.active = null;
  });
  tearDown(() {
    AppContext.instance.clear();
    VoiceSessionController.active = null;
  });

  group('voiceEntryDecision', () {
    test('ok starts normally, weak starts relay-first, offline denies', () {
      expect(voiceEntryDecision(ConnectionQuality.ok),
          VoiceEntryDecision.allow);
      expect(voiceEntryDecision(ConnectionQuality.weak),
          VoiceEntryDecision.allowRelayFirst);
      expect(voiceEntryDecision(ConnectionQuality.offline),
          VoiceEntryDecision.denyOffline);
    });
  });

  test(
      'forceRelayFirst: attempt 1 forces relay, a failure retries on the '
      'direct route', () async {
    final transports = [
      FakeVoiceTransport()..connectError = Exception('relay refused'),
      FakeVoiceTransport(),
    ];
    var i = 0;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transports[i++],
    );

    await c.start(forceRelayFirst: true);

    expect(transports[0].connectCalls, [true]);
    expect(transports[1].connectCalls, [false]);
    expect(c.phase, VoiceSessionPhase.waking);
    await c.stop();
  });

  test('default start keeps the chunk B order: direct first, relay retry',
      () async {
    final transports = [
      FakeVoiceTransport()..connectError = Exception('direct refused'),
      FakeVoiceTransport(),
    ];
    var i = 0;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transports[i++],
    );

    await c.start();

    expect(transports[0].connectCalls, [false]);
    expect(transports[1].connectCalls, [true]);
    await c.stop();
  });

  test('reconnectCount counts each mid-call drop and resets on start',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();
    transport.markAgentReady();
    await Future<void>.delayed(Duration.zero);

    transport.emitReconnecting(true);
    await Future<void>.delayed(Duration.zero);
    transport.emitReconnecting(false);
    await Future<void>.delayed(Duration.zero);
    transport.emitReconnecting(true);
    await Future<void>.delayed(Duration.zero);

    expect(c.reconnectCount, 2);
    expect(c.reconnecting, isTrue);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
    await c.start();
    expect(c.reconnectCount, 0);
    await c.stop();
  });
}
