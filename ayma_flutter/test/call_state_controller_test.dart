import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

/// The last-ended record + bootstrap carry (ledger 2cy): a call that
/// ended must stay visible to Ayma's context — the next text turn and
/// the next voice session's seed both learn that it happened and how
/// it ended. Mirrors the harness in voice_session_controller_test.dart.

final bootstrapBodies = <Map<String, dynamic>>[];

ApiClient _api({int status = 200}) {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/bootstrap') {
      bootstrapBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
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
        status,
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

/// Drive a controller from `idle` all the way to `live` (same helper
/// as voice_session_controller_test.dart).
Future<void> _startLive(
    VoiceSessionController c, FakeVoiceTransport transport) async {
  await c.start();
  transport.markAgentReady();
  await Future<void>.delayed(Duration.zero);
}

VoiceSessionController _controller(FakeVoiceTransport transport,
        {int status = 200}) =>
    VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(status: status),
      transportFactory: () => transport,
    );

void main() {
  setUp(() {
    bootstrapBodies.clear();
    AppContext.instance.clear();
    VoiceSessionController.active = null;
    VoiceSessionController.debugClearLastCallEnd();
  });
  tearDown(() {
    AppContext.instance.clear();
    VoiceSessionController.active = null;
    VoiceSessionController.debugClearLastCallEnd();
  });

  test('while live the snapshot is active; stopping records user_stop',
      () async {
    final transport = FakeVoiceTransport();
    final c = _controller(transport);
    await _startLive(c, transport);
    expect(c.phase, VoiceSessionPhase.live);
    expect(VoiceSessionController.chatCallState().status, 'active');

    await c.stop();

    final snap = VoiceSessionController.chatCallState();
    expect(snap.status, 'just_ended');
    expect(snap.reason, 'user_stop');
    expect(snap.endedSecondsAgo, isNotNull);
    expect(snap.endedSecondsAgo!, lessThan(10));
    expect(VoiceSessionController.previousCallState().status, 'just_ended');
  });

  test('an agent idle_timeout ending records agent_idle_timeout', () async {
    final transport = FakeVoiceTransport();
    final c = _controller(transport);
    await _startLive(c, transport);

    transport.emitCallEnding('idle_timeout');
    for (var i = 0; i < 50 && c.phase != VoiceSessionPhase.idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(c.phase, VoiceSessionPhase.idle);

    final snap = VoiceSessionController.chatCallState();
    expect(snap.status, 'just_ended');
    expect(snap.reason, 'agent_idle_timeout');
  });

  test('a start that fails before going live records nothing', () async {
    final transport = FakeVoiceTransport();
    final c = _controller(transport, status: 500);
    await c.start();
    expect(c.phase, VoiceSessionPhase.error);
    expect(VoiceSessionController.previousCallState().status, 'none');
    expect(VoiceSessionController.chatCallState().status, 'none');
  });

  test('the next bootstrap carries the previous call, the first does not',
      () async {
    final t1 = FakeVoiceTransport();
    final c1 = _controller(t1);
    await _startLive(c1, t1);
    await c1.stop();
    expect(bootstrapBodies, hasLength(1));
    expect(bootstrapBodies.single.containsKey('call_state'), isFalse);

    final t2 = FakeVoiceTransport();
    final c2 = _controller(t2);
    await _startLive(c2, t2);

    expect(bootstrapBodies, hasLength(2));
    final callState = bootstrapBodies.last['call_state'] as Map;
    expect(callState['in_call'], isFalse);
    expect(callState['end_reason'], 'user_stop');
    expect(callState['ended_seconds_ago'], isA<int>());

    await c2.stop();
  });
}
