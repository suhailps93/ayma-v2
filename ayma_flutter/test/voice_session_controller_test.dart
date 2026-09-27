import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' show MediaConnectException;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

final postTurnCalls = <Map<String, dynamic>>[];
final voiceContextCalls = <Map<String, dynamic>>[];

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
    if (request.url.path == '/voice/context') {
      voiceContextCalls.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true}), 200);
    }
    return http.Response('not found', 404);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

void main() {
  setUp(() {
    voiceContextCalls.clear();
    AppContext.instance.clear();
  });
  tearDown(AppContext.instance.clear);

  test('entering `live` posts the current screen context to the backend',
      () async {
    AppContext.instance.set(screen: 'ayma');
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await _startLive(c, transport);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(c.phase, VoiceSessionPhase.live);
    expect(voiceContextCalls, isNotEmpty);
    expect(voiceContextCalls.first['screen'], 'ayma');

    await c.stop();
  });

  test('a screen-context change while live re-posts (debounced)', () async {
    AppContext.instance.set(screen: 'ayma');
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    voiceContextCalls.clear();

    AppContext.instance.set(
      screen: 'profile',
      subjectUid: 'u-jordan',
      subjectName: 'Jordan',
    );
    // Debounced by ~500ms — nothing yet, then one post with the new screen.
    expect(voiceContextCalls, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(voiceContextCalls, hasLength(1));
    expect(voiceContextCalls.single['screen'], 'profile');
    expect(voiceContextCalls.single['subject_uid'], 'u-jordan');
    expect(voiceContextCalls.single['subject_name'], 'Jordan');

    await c.stop();
  });

  test('stopping the session clears the mirror', () async {
    AppContext.instance.set(screen: 'ayma');
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);
    await c.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The clear posts an empty screen (the backend deletes on that).
    expect(voiceContextCalls.last['screen'], '');
  });

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

  // --- ice-relay-retry: one automatic TURN-relay retry on an ICE timeout ---

  test(
      'an ICE timeout on the first connect retries once with relay forced '
      'and proceeds to live', () async {
    final transports = <FakeVoiceTransport>[];
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () {
        final t = FakeVoiceTransport();
        if (transports.isEmpty) {
          // Exactly what production throws on a UDP-blocking network.
          t.connectError = MediaConnectException(
              'Timed out waiting for PeerConnection to connect, please check '
              'your network for ice connectivity');
        }
        transports.add(t);
        return t;
      },
    );

    await c.start();

    // Attempt 1: default policy, failed and was fully torn down.
    // Attempt 2: a fresh transport with relay forced, which succeeded.
    expect(transports, hasLength(2));
    expect(transports[0].connectCalls, [false]);
    expect(transports[0].disconnectCalls, 1);
    expect(transports[0].disposeCalls, 1);
    expect(transports[1].connectCalls, [true]);
    expect(c.relayRetrying, isTrue);
    expect(c.phase, VoiceSessionPhase.waking);
    expect(transports[1].micCalls, [true]); // mic published on the retry path

    transports[1].markAgentReady();
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
  });

  test('both connect attempts failing surfaces the existing error', () async {
    final transports = <FakeVoiceTransport>[];
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () {
        final t = FakeVoiceTransport()
          ..connectError = MediaConnectException(
              'Timed out waiting for PeerConnection to connect');
        transports.add(t);
        return t;
      },
    );

    await c.start();

    expect(transports, hasLength(2)); // exactly one retry, never a loop
    expect(transports[1].connectCalls, [true]);
    expect(c.phase, VoiceSessionPhase.error);
    expect(c.errorMessage, contains('Could not start voice'));
    // Both dead transports were cleaned up.
    expect(transports[0].disposeCalls, 1);
    expect(transports[1].disposeCalls, 1);
  });

  test('a non-ICE connect failure does not trigger the relay retry', () async {
    final transports = <FakeVoiceTransport>[];
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () {
        final t = FakeVoiceTransport()..failConnect = true;
        transports.add(t);
        return t;
      },
    );

    await c.start();

    expect(transports, hasLength(1));
    expect(transports.single.connectCalls, [false]);
    expect(c.relayRetrying, isFalse);
    expect(c.phase, VoiceSessionPhase.error);
  });

  test('a fresh start() clears relayRetrying from a previous session',
      () async {
    final transports = <FakeVoiceTransport>[];
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () {
        final t = FakeVoiceTransport();
        if (transports.isEmpty) {
          t.connectError = MediaConnectException();
        }
        transports.add(t);
        return t;
      },
    );

    await c.start();
    expect(c.relayRetrying, isTrue);
    await c.stop();

    await c.start(); // third transport — connects first try
    expect(c.relayRetrying, isFalse);
    expect(transports, hasLength(3));
    expect(transports.last.connectCalls, [false]);

    await c.stop();
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

  // --- §F3 mid-call credit cap: the agent's own `call_ending` signal -------

  test(
      'a call_ending(out_of_credits) signal surfaces the same reload '
      'affordance as the pre-call usageCapped check', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);
    expect(c.phase, VoiceSessionPhase.live);

    transport.emitCallEnding('out_of_credits');
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.error);
    expect(c.cappedError, isTrue);
    expect(c.errorMessage, contains('Out of credits'));
  });

  test(
      'the generic "connection dropped" close that follows a call_ending '
      'does not clobber the out-of-credits message', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    transport.emitCallEnding('out_of_credits');
    await Future<void>.delayed(Duration.zero);
    // The room actually closing shortly after, exactly like a real forced
    // disconnect from the backend.
    transport.closedController.add('room deleted');
    await Future<void>.delayed(Duration.zero);

    expect(c.cappedError, isTrue);
    expect(c.errorMessage, isNot(contains('connection dropped')));
  });

  test('an ordinary dropped connection (no call_ending) still surfaces the '
      'generic error, not the credits one', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    transport.closedController.add('network error');
    await Future<void>.delayed(Duration.zero);

    expect(c.cappedError, isFalse);
    expect(c.errorMessage, contains('connection dropped'));
  });

  test('an unrelated call_ending reason is ignored', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    transport.emitCallEnding('something_else');
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.live);
    expect(c.cappedError, isFalse);
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

  test('reportBackgroundBlocked() surfaces as an explained error, not a '
      'silent failure', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    c.reportBackgroundBlocked();

    expect(c.phase, VoiceSessionPhase.error);
    expect(c.backgroundPermissionDenied, isTrue);
    expect(c.errorMessage, isNotNull);
    expect(c.errorMessage, contains('notification'));
  });

  test('a fresh start() clears a previous backgroundPermissionDenied flag',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);
    c.reportBackgroundBlocked();
    expect(c.backgroundPermissionDenied, isTrue);

    await c.stop();
    await c.start();

    expect(c.backgroundPermissionDenied, isFalse);
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

  test('a tool_used start+end pair attaches its label to the next ayma turn',
      () async {
    final transport = FakeVoiceTransport();
    final store = TranscriptStore();
    final c = VoiceSessionController(
      transcriptStore: store,
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();

    transport.toolEventsController.add(const ToolUsedEvent(
      name: 'deep_dive',
      label: 'Researching them online…',
      phase: 'start',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(c.activeToolLabel, 'Researching them online…');

    transport.toolEventsController.add(const ToolUsedEvent(
      name: 'deep_dive',
      label: 'Researched them online',
      phase: 'end',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(c.activeToolLabel, isNull); // live indicator clears on "end"

    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'agent_transcript',
      text: "Here's what I found.",
      isFinal: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(store.turns, hasLength(1));
    expect(store.turns.single.tools, ['Researched them online']);

    await c.stop();
  });

  test('multiple tool calls in one turn all attach to the finalized reply',
      () async {
    final transport = FakeVoiceTransport();
    final store = TranscriptStore();
    final c = VoiceSessionController(
      transcriptStore: store,
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();

    for (final name in ['web_search', 'deep_dive']) {
      transport.toolEventsController
          .add(ToolUsedEvent(name: name, label: '$name-working', phase: 'start'));
      transport.toolEventsController
          .add(ToolUsedEvent(name: name, label: '$name-done', phase: 'end'));
    }
    await Future<void>.delayed(Duration.zero);

    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'agent_transcript',
      text: 'Found a few things.',
      isFinal: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(store.turns.single.tools, ['web_search-done', 'deep_dive-done']);

    await c.stop();
  });

  test('a duplicate settled label is only attached once', () async {
    final transport = FakeVoiceTransport();
    final store = TranscriptStore();
    final c = VoiceSessionController(
      transcriptStore: store,
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();

    for (var i = 0; i < 2; i++) {
      transport.toolEventsController.add(const ToolUsedEvent(
          name: 'web_search', label: 'Searching the web…', phase: 'start'));
      transport.toolEventsController.add(const ToolUsedEvent(
          name: 'web_search', label: 'Searched the web', phase: 'end'));
    }
    await Future<void>.delayed(Duration.zero);

    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'agent_transcript',
      text: 'Done.',
      isFinal: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(store.turns.single.tools, ['Searched the web']);

    await c.stop();
  });

  test(
      'a tool call with no subsequent agent_transcript does not leak into '
      'the next user turn', () async {
    final transport = FakeVoiceTransport();
    final store = TranscriptStore();
    final c = VoiceSessionController(
      transcriptStore: store,
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await c.start();

    // A tool call fires but the call drops / the agent never replies.
    transport.toolEventsController.add(const ToolUsedEvent(
        name: 'deep_dive', label: 'Researching…', phase: 'start'));
    transport.toolEventsController.add(const ToolUsedEvent(
        name: 'deep_dive', label: 'Researched them online', phase: 'end'));
    await Future<void>.delayed(Duration.zero);

    // A new user turn starts — the stale label must not resurface later.
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'user_transcript',
      text: 'actually never mind',
      isFinal: true,
    ));
    transport.transcriptsController.add(const TranscriptSegment(
      topic: 'agent_transcript',
      text: 'No worries.',
      isFinal: true,
    ));
    await Future<void>.delayed(Duration.zero);

    final aymaTurn =
        store.turns.firstWhere((t) => t.role == TurnRole.ayma);
    expect(aymaTurn.tools, isEmpty);

    await c.stop();
  });

  test('mic + ayma audio levels propagate (smoothed) from the transport',
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

    expect(c.micLevel.value, 0);
    expect(c.aymaLevel.value, 0);

    transport.emitMicLevel(1.0);
    transport.emitAgentLevel(0.8);
    await Future<void>.delayed(Duration.zero);

    // Exponential smoothing: first sample lands part-way, not at the raw value.
    expect(c.micLevel.value, greaterThan(0));
    expect(c.micLevel.value, lessThan(1.0));
    expect(c.aymaLevel.value, greaterThan(0));

    await c.stop();
    expect(c.micLevel.value, 0);
    expect(c.aymaLevel.value, 0);
  });
}
