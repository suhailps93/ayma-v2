import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

/// Regression tests for the 30 s user-idle disconnect rule (founder directive,
/// 2026-11-05: if Ayma voice session is on and it hasn't got a proper input in
/// thirty seconds it should disconnect on its own).
/// Proper input = finalized intelligible user speech. Silence, background noise,
/// and Ayma's own speech do not count.
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
    if (request.url.path == '/practice/voice/start') {
      return http.Response(
        jsonEncode({
          'session_id': 'practice_v1',
          'simulation': true,
          'persona': {'name': 'Dana', 'age': 30, 'location': 'Berlin'},
          'livekit': {
            'token': 'tok-practice',
            'url': 'wss://example.livekit.cloud',
            'room': 'ayma-her',
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

Future<void> _startLive(
    VoiceSessionController c, FakeVoiceTransport transport) async {
  await c.start();
  transport.markAgentReady();
  await Future<void>.delayed(const Duration(milliseconds: 20));
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

  test('1. silent live session ends after user idle timeout', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      userIdleTimeout: const Duration(milliseconds: 150),
    );
    await _startLive(c, transport);
    expect(c.phase, VoiceSessionPhase.live);

    // No user input occurs: after timeout expires, session ends on its own.
    await Future<void>.delayed(const Duration(milliseconds: 220));

    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.endNotice, contains('30 seconds'));
    expect(c.disconnectReason, 'client_idle_timeout');
  });

  test('2. a finalized user segment resets the timeout deadline', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      userIdleTimeout: const Duration(milliseconds: 200),
    );
    await _startLive(c, transport);
    expect(c.phase, VoiceSessionPhase.live);

    // Finalized user segment arrives at 60ms.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'hello Ayma',
      isFinal: true,
    ));

    // At 180ms total (120ms after user segment), call is still live.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.phase, VoiceSessionPhase.live);

    // After 200ms from the user segment (~300ms total), the timer fires and ends.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.disconnectReason, 'client_idle_timeout');
  });

  test('3. interim user segments across the timeout boundary prevent firing while user speaks', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      userIdleTimeout: const Duration(milliseconds: 200),
    );
    await _startLive(c, transport);

    // User starts speaking before deadline: interim segment at 100ms.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'I was thinking',
      isFinal: false,
    ));

    // Beyond initial 200ms boundary (at 220ms total), session is still live.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(c.phase, VoiceSessionPhase.live);

    // Further interim segment at 260ms total.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'I was thinking about going to dinner',
      isFinal: false,
    ));

    // At 360ms total (100ms after last interim), still live.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.phase, VoiceSessionPhase.live);

    // Now silence: after 200ms from the last interim segment (~500ms total), it ends.
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.disconnectReason, 'client_idle_timeout');
  });

  test('4. Ayma-only activity never resets the user-idle clock', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      userIdleTimeout: const Duration(milliseconds: 200),
    );
    await _startLive(c, transport);

    // Ayma produces transcript segments and tool events at 30ms and 60ms.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'agent_transcript',
      text: 'Hello, how can I help?',
      isFinal: true,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    transport.toolEventsController.add(const ToolUsedEvent(
      name: 'search',
      label: 'Searching…',
      phase: 'start',
    ));
    transport.emitAgentMute(true);

    // Ayma finishes tool at 80ms.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    transport.toolEventsController.add(const ToolUsedEvent(
      name: 'search',
      label: 'Searched',
      phase: 'end',
    ));

    // Still live before 200ms.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(c.phase, VoiceSessionPhase.live);

    // Clock was NOT reset by Ayma: ends at 200ms from session start (~260ms with margin).
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.disconnectReason, 'client_idle_timeout');
  });

  test('5. a flag-off (practice-shaped or unconfigured) controller never fires', () async {
    // 5a. Flag-off: userIdleTimeout is null (default).
    final t1 = FakeVoiceTransport();
    final cNull = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => t1,
    );
    expect(cNull.userIdleTimeoutForTest, isNull);
    await _startLive(cNull, t1);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(cNull.phase, VoiceSessionPhase.live);
    await cNull.stop();

    // 5b. Flag-off: userIdleTimeout is Duration.zero.
    final t2 = FakeVoiceTransport();
    final cZero = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => t2,
      userIdleTimeout: Duration.zero,
    );
    expect(cZero.userIdleTimeoutForTest, isNull);
    await _startLive(cZero, t2);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(cZero.phase, VoiceSessionPhase.live);
    await cZero.stop();

    // 5c. Practice-shaped: practiceOtherUid is provided (practice calls never idle-end).
    final t3 = FakeVoiceTransport();
    final cPractice = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      practiceOtherUid: 'sim-user-123',
      transportFactory: () => t3,
      userIdleTimeout: const Duration(milliseconds: 40),
    );
    expect(cPractice.userIdleTimeoutForTest, isNull);
    await _startLive(cPractice, t3);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(cPractice.phase, VoiceSessionPhase.live);
    await cPractice.stop();
  });

  test('6. mid-utterance fire defers until Ayma utterance completes, then ends if still no user input', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      userIdleTimeout: const Duration(milliseconds: 150),
    );
    await _startLive(c, transport);

    // Ayma begins speaking at 40ms (well before 150ms).
    await Future<void>.delayed(const Duration(milliseconds: 40));
    transport.emitAgentSpeaking(true);

    // Beyond the 150ms timeout deadline (at 190ms total), Ayma is still speaking,
    // so disconnection is deferred and session remains live.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.phase, VoiceSessionPhase.live);

    // Ayma completes her utterance at 220ms total. Still no user input.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    transport.emitAgentSpeaking(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Session ends immediately after utterance completes.
    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.endNotice, contains('30 seconds'));
    expect(c.disconnectReason, 'client_idle_timeout');
  });

  test('6b. mid-utterance fire with user barge-in clears deferred end and resets timer', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      userIdleTimeout: const Duration(milliseconds: 150),
    );
    await _startLive(c, transport);

    // Ayma speaks at 40ms.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    transport.emitAgentSpeaking(true);

    // Timeout fires at 150ms while speaking -> deferred.
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(c.phase, VoiceSessionPhase.live);

    // User speaks / barges in at 200ms before Ayma finishes.
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'wait Ayma',
      isFinal: true,
    ));

    // Ayma stops speaking at 230ms total.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    transport.emitAgentSpeaking(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Call stays live because user input cleared the deferred end!
    expect(c.phase, VoiceSessionPhase.live);

    // And now after another 150ms from the user input (~380ms total), it ends.
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.disconnectReason, 'client_idle_timeout');
  });
}
