import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/error_reporting.dart';
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
int bootstrapCalls = 0;

/// Records handled-error reports instead of sending them anywhere.
class _RecordingReporter extends ErrorReporter {
  final reports = <({Object error, String reason, Map<String, String> tags})>[];

  @override
  Future<void> report(
    Object error,
    StackTrace? stack, {
    required String reason,
    Map<String, String> tags = const {},
  }) async {
    reports.add((error: error, reason: reason, tags: tags));
  }
}
final voiceContextCalls = <Map<String, dynamic>>[];

/// Drive a controller from `idle` all the way to `live`: `start()` lands in
/// `waking`, then the fake transport's one-shot `agentReady` promotes it.
/// Drives the controller to `live` (agent joined), i.e. the honest
/// "Connecting…"/awaiting-first-response window — NOT yet conversation-ready, so
/// the mic/OS call surface are intentionally still held back. Tests that need a
/// genuinely conversing call emit Ayma's first response themselves (an
/// `emitAgentSpeaking(true)` / agent transcript).
Future<void> _startLive(
    VoiceSessionController c, FakeVoiceTransport transport) async {
  await c.start();
  transport.markAgentReady();
  await Future<void>.delayed(Duration.zero);
}

/// Drives a `failMic`-configured controller to the point the mic is published
/// — Ayma's first genuine response — and pumps until the denial lands it in
/// `error` (the mic is no longer enabled at connect, so a denial surfaces here).
Future<void> _driveToDeniedMic(
    VoiceSessionController c, FakeVoiceTransport Function() transport) async {
  await c.start();
  transport().markAgentReady();
  await Future<void>.delayed(Duration.zero);
  transport().emitAgentSpeaking(true); // first response → mic publish attempt
  for (var i = 0; i < 100 && c.phase != VoiceSessionPhase.error; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ApiClient _api({
  Map<String, dynamic>? bootstrapBody,
  int status = 200,
}) {
  final auth = MockFirebaseAuth(signedIn: true);
  final mockHttp = MockClient((request) async {
    if (request.url.path == '/bootstrap') {
      bootstrapCalls++;
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
    bootstrapCalls = 0;
    voiceContextCalls.clear();
    AppContext.instance.clear();
    VoiceSessionController.active = null;
  });
  tearDown(() {
    AppContext.instance.clear();
    VoiceSessionController.active = null;
  });

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

  test('start() bootstraps and connects, but does NOT publish the mic until '
      'the call is conversation-ready (no mic during connecting/waking)',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await c.start();

    // Room is connected, but the agent hasn't joined — privacy invariant: the
    // OS mic is NOT captured yet (founder bug 2026-11-03: the mic/notification
    // used to come up the instant a call began connecting).
    expect(c.phase, VoiceSessionPhase.waking);
    expect(c.isActive, isTrue);
    expect(c.isConversationReady, isFalse);
    expect(transport.connectedUrl, 'wss://example.livekit.cloud');
    expect(transport.connectedToken, 'tok-abc');
    expect(transport.micCalls, isEmpty);

    // The agent joins — still NOT ready (its first reply hasn't landed), so
    // the mic stays released all through the "Connecting…"/warm-up window.
    transport.markAgentReady();
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, VoiceSessionPhase.live);
    expect(c.awaitingFirstResponse, isTrue);
    expect(c.isConversationReady, isFalse);
    expect(transport.micCalls, isEmpty);

    // Ayma's first genuine response — only NOW is the mic published.
    transport.emitAgentSpeaking(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.isConversationReady, isTrue);
    expect(transport.micCalls, [true]);

    await c.stop();
  });

  test('open-weights warm-up never captures the mic; the first reply does',
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
    // The agent joins, then signals the open-weights cold start — production
    // ordering: `live` precedes warming. The UI shows "Warming up…" but the
    // call is NOT conversation-ready, so the mic must stay released the whole
    // ~100s warm-up (the founder's exact privacy bug, 2026-11-03).
    transport.emitVoiceStatus('open_weights_warming');
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, VoiceSessionPhase.live);
    expect(c.warmingNotice, isNotNull); // "Warming up the open-weights model…"
    expect(c.isConversationReady, isFalse);
    expect(transport.micCalls, isEmpty);

    // The first real reply ends the warm-up — only now is the mic published.
    transport.emitAgentSpeaking(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.isConversationReady, isTrue);
    expect(transport.micCalls, [true]);

    await c.stop();
  });

  test('a crash/dropped connection releases the mic (disconnect) and leaves '
      'no conversation-ready state (so the notification is dismissed)',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);
    transport.emitAgentSpeaking(true); // reach conversation-ready, mic published
    await Future<void>.delayed(Duration.zero);
    expect(c.isConversationReady, isTrue);
    expect(transport.micCalls, [true]);

    // The transport drops unexpectedly (network / server close / a crash).
    transport.closedController.add('network error');
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.error);
    // The OS surface gates on this — false means the notification is dismissed.
    expect(c.isConversationReady, isFalse);
    // The mic/room were torn down — the privacy-critical release always runs.
    expect(transport.disconnectCalls, 1);
    expect(transport.disposeCalls, 1);
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

  test('the agent never joining retries once in a fresh room, then errors',
      () async {
    final transports = <FakeVoiceTransport>[];
    final reporter = _RecordingReporter();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      sessionId: 's-test',
      apiClient: _api(),
      transportFactory: () => transports.last,
      wakingTimeout: const Duration(milliseconds: 20),
      errorReporter: reporter,
    );
    transports.add(FakeVoiceTransport());

    await c.start();
    expect(c.phase, VoiceSessionPhase.waking);
    transports.add(FakeVoiceTransport()); // used by the automatic retry

    // The retry re-connects a fresh transport. The mic is no longer published
    // during waking (privacy fix), so key the wait on the new room connecting.
    for (var i = 0; i < 100 && transports.last.connectCalls.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    // First miss: torn down and re-bootstrapped (a new room), not failed.
    expect(bootstrapCalls, 2);
    expect(c.phase, VoiceSessionPhase.waking);
    expect(c.relayRetrying, isTrue);
    expect(transports.first.disconnectCalls, 1);

    for (var i = 0; i < 100 && c.phase != VoiceSessionPhase.error; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(c.phase, VoiceSessionPhase.error);
    expect(c.errorMessage, contains("didn't pick up"));
    expect(bootstrapCalls, 2);
    for (final t in transports) {
      expect(t.disconnectCalls, 1);
      expect(t.disposeCalls, 1);
    }
    expect(reporter.reports.map((r) => r.reason),
        ['voice_agent_no_join', 'voice_agent_no_join']);
    expect(reporter.reports.map((r) => r.tags['attempt']), ['1', '2']);
    expect(reporter.reports.first.tags['session_id'], 's-test');
  });

  test('the agent joining on the automatic retry goes live', () async {
    final transports = [FakeVoiceTransport()];
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transports.last,
      wakingTimeout: const Duration(milliseconds: 20),
      errorReporter: _RecordingReporter(),
    );

    await c.start();
    transports.add(FakeVoiceTransport()..agentReadyOnConnect = true);
    for (var i = 0; i < 100 && c.phase != VoiceSessionPhase.live; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(c.phase, VoiceSessionPhase.live);
    expect(bootstrapCalls, 2);
    await c.stop();
  });

  test('stop() while the no-join retry is waiting stays stopped', () async {
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: FakeVoiceTransport.new,
      wakingTimeout: const Duration(milliseconds: 20),
      errorReporter: _RecordingReporter(),
    );

    await c.start();
    for (var i = 0; i < 100 && bootstrapCalls < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(bootstrapCalls, 2);
    await c.stop();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.errorMessage, isNull);
    expect(bootstrapCalls, 2);
  });

  test('a failed token fetch is reported with its status and tags', () async {
    AppContext.instance.set(screen: 'ayma');
    final reporter = _RecordingReporter();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      sessionId: 's-test',
      apiClient: _api(status: 503, bootstrapBody: {'detail': 'down'}),
      transportFactory: FakeVoiceTransport.new,
      errorReporter: reporter,
    );

    await c.start();

    expect(c.phase, VoiceSessionPhase.error);
    expect(reporter.reports, hasLength(1));
    final r = reporter.reports.single;
    expect(r.reason, 'voice_token_fetch');
    expect(r.tags['http_status'], '503');
    expect(r.tags['route'], 'ayma');
    expect(r.tags['session_id'], 's-test');
    expect(r.tags['feature'], 'voice');
  });

  test('a denied mic is reported', () async {
    final reporter = _RecordingReporter();
    late FakeVoiceTransport transport;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport = FakeVoiceTransport()..failMic = true,
      errorReporter: reporter,
    );

    // The mic is published on Ayma's first response (not at connect), so the
    // denial surfaces there — drive the call to that point.
    await _driveToDeniedMic(c, () => transport);

    expect(c.errorMessage, contains('microphone'));
    expect(reporter.reports.single.reason, 'voice_mic_permission');
  });

  test('the configured voice provider tags reports', () async {
    final reporter = _RecordingReporter();
    late FakeVoiceTransport transport;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(bootstrapBody: {
        'session_mode': 'marketing',
        'uid': 'u1',
        'livekit': {
          'token': 'tok-abc',
          'url': 'wss://example.livekit.cloud',
          'room': 'ayma-u1-x',
          'voice_provider': 'inference',
        },
      }),
      transportFactory: () => transport = FakeVoiceTransport()..failMic = true,
      errorReporter: reporter,
    );

    await _driveToDeniedMic(c, () => transport);

    expect(reporter.reports.single.tags['provider'], 'inference');
  });

  test('agentReady after the timeout does not resurrect the session', () async {
    late FakeVoiceTransport transport;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport = FakeVoiceTransport(),
      wakingTimeout: const Duration(milliseconds: 20),
      errorReporter: _RecordingReporter(),
    );

    await c.start();
    for (var i = 0; i < 100 && c.phase != VoiceSessionPhase.error; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
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

  test('fails cleanly when the mic cannot be enabled (on first response)',
      () async {
    final transport = FakeVoiceTransport()..failMic = true;
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    await _driveToDeniedMic(c, () => transport);

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

  // --- relay retry: one automatic TURN-relay retry on a connect failure ---

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
    // The relay retry connected its room but has NOT published the mic — that
    // waits for the call to become conversation-ready (privacy fix).
    expect(transports[1].micCalls, isEmpty);

    transports[1].markAgentReady();
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, VoiceSessionPhase.live);
    // Ayma's first response publishes the mic on this live (retry) transport.
    transports[1].emitAgentSpeaking(true);
    await Future<void>.delayed(Duration.zero);
    expect(transports[1].micCalls, [true]);

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

  test('a non-ICE connect failure also retries once with relay forced',
      () async {
    final transports = <FakeVoiceTransport>[];
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () {
        final t = FakeVoiceTransport();
        if (transports.isEmpty) t.failConnect = true;
        transports.add(t);
        return t;
      },
    );

    await c.start();

    // Attempt 1 died with a plain (non-ICE) error — on a lossy handset
    // connection the signaling leg can fail before ICE even starts, so the
    // forgiving route still applies: one relay-forced retry, which
    // connected.
    expect(transports, hasLength(2));
    expect(transports[0].connectCalls, [false]);
    expect(transports[1].connectCalls, [true]);
    expect(c.relayRetrying, isTrue);
    expect(c.phase, VoiceSessionPhase.waking);

    await c.stop();
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

  // --- mid-call reconnect: a blip surfaces, then resumes, never ends ---

  test('a mid-call reconnect surfaces and clears without ending the call',
      () async {
    final t = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => t,
    );

    await c.start();
    t.markAgentReady();
    await Future<void>.delayed(Duration.zero);
    expect(c.phase, VoiceSessionPhase.live);
    expect(c.reconnecting, isFalse);

    // The connection drops mid-call; the SDK starts re-establishing it.
    t.emitReconnecting(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.reconnecting, isTrue);
    // The call is NOT over — no error, still live.
    expect(c.phase, VoiceSessionPhase.live);
    expect(c.errorMessage, isNull);

    // The SDK resumes the same session.
    t.emitReconnecting(false);
    await Future<void>.delayed(Duration.zero);
    expect(c.reconnecting, isFalse);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
    expect(c.reconnecting, isFalse);
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
      'a call_ending(out_of_credits) signal surfaces the same Upgrade '
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

    // The agent ending the call for out-of-credits now tears the session down
    // immediately (releasing the mic — the privacy fix no longer waits for a
    // `closed` event that may never arrive), and latches the capped error. A
    // dropped-connection `closed` arriving afterwards hits an already-torn-down
    // transport (identity check in the listener) and cannot clobber it.
    expect(c.cappedError, isTrue);
    expect(c.errorMessage, isNot(contains('connection dropped')));
    expect(c.errorMessage, contains('Out of credits'));
    expect(transport.disconnectCalls, 1);
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

  test('call_ending(idle_timeout) ends the call to idle with a non-error '
      'notice', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    transport.emitCallEnding('idle_timeout');
    await Future<void>.delayed(Duration.zero);

    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.isActive, isFalse);
    expect(c.errorMessage, isNull);
    expect(c.cappedError, isFalse);
    expect(c.endNotice, contains('3 minutes of silence'));
  });

  test('client idle guard ends a live call when the agent never reports',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      idleGuardTimeout: const Duration(milliseconds: 60),
    );
    await _startLive(c, transport);

    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(c.phase, VoiceSessionPhase.idle);
    expect(c.endNotice, isNotNull);
  });

  test('client idle guard does not fire while Ayma is speaking', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      idleGuardTimeout: const Duration(milliseconds: 60),
    );
    await _startLive(c, transport);
    transport.agentSpeakingController.add(true);

    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(c.phase, VoiceSessionPhase.live);
    await c.stop();
  });

  test('aymaQuiet follows agent_mute events and clears on session end',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);
    expect(c.aymaQuiet, isFalse);

    transport.emitAgentMute(true);
    await Future<void>.delayed(Duration.zero);
    expect(c.aymaQuiet, isTrue);

    transport.emitAgentMute(false);
    await Future<void>.delayed(Duration.zero);
    expect(c.aymaQuiet, isFalse);

    transport.emitAgentMute(true);
    await Future<void>.delayed(Duration.zero);
    await c.stop();
    expect(c.aymaQuiet, isFalse);
  });

  test('unmuteAyma asks the agent and waits for its agent_mute echo',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );
    await _startLive(c, transport);

    // Not quiet: nothing to send.
    await c.unmuteAyma();
    expect(transport.muteControlCalls, isEmpty);

    transport.emitAgentMute(true);
    await Future<void>.delayed(Duration.zero);
    await c.unmuteAyma();
    expect(transport.muteControlCalls, [false]);
    // The agent is authoritative: still quiet until it answers.
    expect(c.aymaQuiet, isTrue);

    transport.emitAgentMute(false);
    await Future<void>.delayed(Duration.zero);
    expect(c.aymaQuiet, isFalse);

    // A failed send keeps her quiet and never throws.
    transport.emitAgentMute(true);
    await Future<void>.delayed(Duration.zero);
    transport.failMuteControl = true;
    await c.unmuteAyma();
    expect(c.aymaQuiet, isTrue);
    expect(c.phase, VoiceSessionPhase.live);
    await c.stop();
  });

  test('notifyVoiceAccentChanged publishes to the live call only', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    // No live call: nothing sent (the save applies from the next call).
    expect(
      await c.notifyVoiceAccentChanged(accent: 'Irish', language: ''),
      isFalse,
    );
    expect(transport.accentControlCalls, isEmpty);

    await _startLive(c, transport);
    expect(
      await c.notifyVoiceAccentChanged(
        accent: 'an Irish accent',
        language: 'Default (English)',
      ),
      isTrue,
    );
    expect(transport.accentControlCalls, [
      (accent: 'an Irish accent', language: 'Default (English)'),
    ]);

    // A failed send is best effort: false, never throws, call stays live.
    transport.failAccentControl = true;
    expect(
      await c.notifyVoiceAccentChanged(accent: 'Irish', language: ''),
      isFalse,
    );
    expect(c.phase, VoiceSessionPhase.live);
    await c.stop();
  });

  test('notifyTourTapped publishes the tap to the live call only (§11.2b)',
      () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
    );

    // No live call: nothing sent (a text tour uses the /chat ping instead).
    expect(await c.notifyTourTapped(index: 1), isFalse);
    expect(transport.tourTappedCalls, isEmpty);

    await _startLive(c, transport);
    expect(await c.notifyTourTapped(index: 2), isTrue);
    expect(transport.tourTappedCalls, [2]);

    // A failed send is best effort: false, never throws, the call stays live.
    transport.failTourTapped = true;
    expect(await c.notifyTourTapped(index: 3), isFalse);
    expect(c.phase, VoiceSessionPhase.live);
    await c.stop();
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
    // Live but awaiting Ayma's first response — still not conversation-ready,
    // so there is no published mic to toggle yet (mute is a no-op).
    await c.toggleMute();
    expect(c.muted, isFalse);
    expect(transport.micCalls, isEmpty);

    // Ayma's first response publishes the mic; now mute actually toggles it.
    transport.emitAgentSpeaking(true);
    await Future<void>.delayed(Duration.zero);
    expect(transport.micCalls, [true]);
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

  // --- Practice Date voice (hackathon B) ----------------------------------- //
  group('practice voice', () {
    final voicePostTurns = <Map<String, dynamic>>[];
    ApiClient practiceApi() {
      voicePostTurns.clear();
      return ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((request) async {
          if (request.url.path == '/practice/voice/start') {
            return http.Response(
              jsonEncode({
                'session_id': 'practice_v1',
                'simulation': true,
                'persona': {'name': 'Dana', 'age': 30, 'location': 'Berlin'},
                'banner': 'Practice mode — simulated Dana.',
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
          if (request.url.path == '/post-turn') {
            voicePostTurns.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.url.path == '/voice/context') {
            voiceContextCalls.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('not found', 404);
        }),
      );
    }

    test('start() calls /practice/voice/start, goes live, captures the session '
        'id + persona, and surfaces coach hints', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        practiceOtherUid: 'her',
        apiClient: practiceApi(),
        transportFactory: () => transport,
      );

      await _startLive(c, transport);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(c.phase, VoiceSessionPhase.live);
      expect(c.isPractice, isTrue);
      expect(c.practiceSessionId, 'practice_v1');
      expect(c.practicePersona?.name, 'Dana');
      expect(transport.connectedToken, 'tok-practice');

      // The out-of-character live coach nudge surfaces to the user.
      transport.emitPracticeCoach('Ask an open question back.');
      await Future<void>.delayed(Duration.zero);
      expect(c.coachHint, 'Ask an open question back.');

      await c.stop();
    });

    test('a practice call never mirrors the screen nor posts raw_turns (a '
        'simulation never touches the user\'s real memory)', () async {
      AppContext.instance.set(screen: 'ayma');
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        practiceOtherUid: 'her',
        apiClient: practiceApi(),
        transportFactory: () => transport,
      );

      await _startLive(c, transport);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c.stop();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(voiceContextCalls, isEmpty); // no screen mirroring for the persona
      expect(voicePostTurns, isEmpty); // no raw_turns persistence
      AppContext.instance.clear();
    });
  });

  // --- Practice voice return (founder rule, 2026-11-06) ------------------ //
  // When voice mode is ON and a Practice Date voice call displaces Ayma's
  // session, the end of the practice call — for any reason — must bring
  // Ayma's session back up, with the bootstrap carrying the practice
  // session id so the server seeds the debrief greeting.
  group('practice voice return', () {
    final bootstrapBodies = <Map<String, dynamic>>[];

    ApiClient returnApi(
        {bool failPracticeStart = false,
        Duration practiceStartDelay = Duration.zero}) {
      bootstrapBodies.clear();
      return ApiClient(
        auth: MockFirebaseAuth(signedIn: true),
        httpClient: MockClient((request) async {
          if (request.url.path == '/bootstrap') {
            bootstrapBodies
                .add(jsonDecode(request.body) as Map<String, dynamic>);
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
            if (failPracticeStart) {
              return http.Response('boom', 500);
            }
            if (practiceStartDelay != Duration.zero) {
              await Future<void>.delayed(practiceStartDelay);
            }
            return http.Response(
              jsonEncode({
                'session_id': 'practice_v1',
                'simulation': true,
                'persona': {'name': 'Dana', 'age': 30, 'location': 'Berlin'},
                'banner': 'Practice mode — simulated Dana.',
                'livekit': {
                  'token': 'tok-practice',
                  'url': 'wss://example.livekit.cloud',
                  'room': 'ayma-her',
                },
              }),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8'
              },
            );
          }
          if (request.url.path == '/post-turn') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          if (request.url.path == '/voice/context') {
            return http.Response(jsonEncode({'ok': true}), 200);
          }
          return http.Response('not found', 404);
        }),
      );
    }

    /// Ayma controllers get a vending factory: every start creates a fresh
    /// transport (a stopped session's transport is disposed and its streams
    /// close, exactly like the real LiveKit transport), recorded in
    /// [vended] so the test can drive the current session's transport.
    VoiceSessionController aymaController(
            ApiClient api, List<FakeVoiceTransport> vended,
            {Duration? userIdleTimeout}) =>
        VoiceSessionController(
          transcriptStore: TranscriptStore(),
          apiClient: api,
          userIdleTimeout: userIdleTimeout,
          transportFactory: () {
            final t = FakeVoiceTransport();
            vended.add(t);
            return t;
          },
        );

    Future<void> startAymaLive(
        VoiceSessionController c, List<FakeVoiceTransport> vended) async {
      await c.start();
      vended.last.markAgentReady();
      await Future<void>.delayed(Duration.zero);
    }

    /// Drive Ayma's first genuine response (her opening greeting) so the
    /// user-idle clock arms (F1: the clock starts at the first response).
    Future<void> emitAymaFirstResponse(FakeVoiceTransport transport) async {
      transport.transcriptsController.add(const TranscriptSegment(
        topic: 'agent_transcript',
        text: 'Hi, how can I help?',
        isFinal: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    VoiceSessionController practiceController(
            ApiClient api, FakeVoiceTransport t) =>
        VoiceSessionController(
          transcriptStore: TranscriptStore(),
          practiceOtherUid: 'her',
          apiClient: api,
          transportFactory: () => t,
        );

    test('ending the practice call (hangup) restarts the displaced Ayma '
        'session with the practice id on its bootstrap', () async {
      final api = returnApi();
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended);
      await startAymaLive(ayma, vended);
      expect(ayma.phase, VoiceSessionPhase.live);
      expect(bootstrapBodies, hasLength(1));
      expect(bootstrapBodies.single.containsKey('practice_return_session_id'),
          isFalse);

      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await _startLive(practice, tPractice);
      // The single-active-session exclusion stopped Ayma's session.
      expect(ayma.phase, VoiceSessionPhase.idle);
      expect(practice.phase, VoiceSessionPhase.live);

      await practice.stop();
      // The return fires from a microtask; give the restart room to run.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bootstrapBodies, hasLength(2));
      expect(bootstrapBodies.last['practice_return_session_id'],
          'practice_v1');
      expect(ayma.isActive, isTrue);

      vended.last.markAgentReady();
      await Future<void>.delayed(Duration.zero);
      expect(ayma.phase, VoiceSessionPhase.live);
      await ayma.stop();
    });

    test('a practice call the agent ends on its own (idle timeout) also '
        'returns', () async {
      final api = returnApi();
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended);
      await startAymaLive(ayma, vended);

      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await _startLive(practice, tPractice);
      expect(practice.phase, VoiceSessionPhase.live);

      tPractice.emitCallEnding('idle_timeout');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bootstrapBodies, hasLength(2));
      expect(bootstrapBodies.last['practice_return_session_id'],
          'practice_v1');
      expect(ayma.isActive, isTrue);

      await ayma.stop();
    });

    test('no return when voice mode was off before the practice call',
        () async {
      final api = returnApi();
      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await _startLive(practice, tPractice);
      await practice.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bootstrapBodies, isEmpty);
    });

    test('manually restarting Ayma mid-practice cancels the pending return',
        () async {
      final api = returnApi();
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended);
      await startAymaLive(ayma, vended);

      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await _startLive(practice, tPractice);
      expect(practice.phase, VoiceSessionPhase.live);

      // The user takes voice back themselves: Ayma restarts manually,
      // displacing the practice call — no debrief return may fire after.
      await ayma.start();
      vended.last.markAgentReady();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ayma.phase, VoiceSessionPhase.live);
      expect(practice.phase, VoiceSessionPhase.idle);
      expect(bootstrapBodies, hasLength(2));
      expect(
        bootstrapBodies.any((b) => b.containsKey('practice_return_session_id')),
        isFalse,
      );

      await ayma.stop();
    });

    test('a practice call that never connects does not fire the return',
        () async {
      final api = returnApi(failPracticeStart: true);
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended);
      await startAymaLive(ayma, vended);
      expect(bootstrapBodies, hasLength(1));

      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await practice.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(practice.phase, VoiceSessionPhase.error);
      // Ayma stays down: the failed start's error surface owns the moment.
      expect(ayma.phase, VoiceSessionPhase.idle);
      expect(bootstrapBodies, hasLength(1));
    });

    test('a failed practice start disarms its return — a later, unrelated '
        'practice call ending does not resurrect the old session', () async {
      // Regression: the armed marker used to outlive a never-live practice
      // attempt and fire at the NEXT practice call's end, restarting the
      // stale Ayma controller and tearing down whatever was live then.
      final api = returnApi(failPracticeStart: true);
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended);
      await startAymaLive(ayma, vended);
      final tFailed = FakeVoiceTransport();
      final failed = practiceController(api, tFailed);
      await failed.start();
      expect(failed.phase, VoiceSessionPhase.error);
      expect(bootstrapBodies, hasLength(1));

      // A later practice call (fresh API, nothing displaced) runs and ends.
      final api2 = returnApi();
      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api2, tPractice);
      await _startLive(practice, tPractice);
      await practice.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The stale session was NOT resurrected: it is still down, and no
      // bootstrap has been recorded since (the second returnApi() cleared
      // the shared record, and both APIs append to it — a resurrection
      // restart would show up here).
      expect(ayma.phase, VoiceSessionPhase.idle);
      expect(bootstrapBodies, isEmpty);
    });

    test('cold-worker connect: a practice call initiated while Ayma is live '
        'does not let her idle window fire before it connects (note 125)',
        () async {
      // The bench case, at test scale: a 33 s cold connect vs the 30 s
      // idle window becomes a 300 ms practice start vs a 150 ms window.
      final api = returnApi(
          practiceStartDelay: const Duration(milliseconds: 300));
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended,
          userIdleTimeout: const Duration(milliseconds: 150));
      await startAymaLive(ayma, vended);
      await emitAymaFirstResponse(vended.last);
      expect(ayma.userIdleArmedAtForTest, isNotNull);

      // The tap: the practice call is initiated, but its controller has
      // not started yet — the slow connect is still ahead.
      VoiceSessionController.preparePracticeReturn();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Twice the idle window has passed with no practice start: without
      // the suspension Ayma would have idle-fired at ~150 ms.
      expect(ayma.phase, VoiceSessionPhase.live);
      expect(ayma.disconnectReason, isNull);

      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await _startLive(practice, tPractice);
      expect(ayma.phase, VoiceSessionPhase.idle);
      expect(practice.phase, VoiceSessionPhase.live);

      await practice.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bootstrapBodies, hasLength(2));
      expect(bootstrapBodies.last['practice_return_session_id'],
          'practice_v1');
      expect(ayma.isActive, isTrue);

      vended.last.markAgentReady();
      await Future<void>.delayed(Duration.zero);
      expect(ayma.phase, VoiceSessionPhase.live);
      await ayma.stop();
    });

    test('a practice call that is initiated but never starts releases the '
        'idle suspension — Ayma keeps her idle timeout (note 125)',
        () async {
      final api = returnApi();
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended,
          userIdleTimeout: const Duration(milliseconds: 150));
      await startAymaLive(ayma, vended);
      await emitAymaFirstResponse(vended.last);
      expect(ayma.userIdleArmedAtForTest, isNotNull);

      VoiceSessionController.preparePracticeReturn();

      // The practice screen goes away without ever starting its
      // controller (backed out, offline deny): its teardown must disarm
      // the return and resume Ayma's idle timer.
      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await practice.stop();
      practice.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(ayma.phase, VoiceSessionPhase.live);
      expect(ayma.userIdleArmedAtForTest, isNotNull);

      // The resumed clock is a fresh window: silence past it ends the
      // call exactly as if no practice call had ever been initiated.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(ayma.phase, VoiceSessionPhase.idle);
      expect(ayma.disconnectReason, 'client_idle_timeout');
    });

    test('Ayma responding while a practice call is pending still leaves '
        'her with an idle timeout once the practice call goes away '
        '(note 125)', () async {
      final api = returnApi();
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended,
          userIdleTimeout: const Duration(milliseconds: 150));
      await startAymaLive(ayma, vended);
      // No first response yet: the idle clock has not armed.
      expect(ayma.userIdleArmedAtForTest, isNull);

      VoiceSessionController.preparePracticeReturn();

      // Her greeting lands while the practice call is pending: the arm
      // is suppressed by the suspension, but the response is recorded.
      await emitAymaFirstResponse(vended.last);
      expect(ayma.userIdleArmedAtForTest, isNull);

      final tPractice = FakeVoiceTransport();
      final practice = practiceController(api, tPractice);
      await practice.stop();
      practice.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The resume re-arms from the recorded response — the clock must
      // not be lost just because it was suspended before it ever armed.
      expect(ayma.phase, VoiceSessionPhase.live);
      expect(ayma.userIdleArmedAtForTest, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(ayma.phase, VoiceSessionPhase.idle);
      expect(ayma.disconnectReason, 'client_idle_timeout');
    });

    test('a practice call whose first connect fails and retries still '
        'returns when it ends (note 125)', () async {
      // A cold worker is exactly when a first connect attempt fails: the
      // relay retry is part of the SAME attempt, so the armed return must
      // survive its teardown — disarming there would lose the return for
      // a practice call that then connects and runs.
      final api = returnApi();
      final vended = <FakeVoiceTransport>[];
      final ayma = aymaController(api, vended);
      await startAymaLive(ayma, vended);

      final practiceTransports = <FakeVoiceTransport>[];
      final practice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        practiceOtherUid: 'her',
        apiClient: api,
        transportFactory: () {
          final t = FakeVoiceTransport();
          if (practiceTransports.isEmpty) {
            t.connectError = MediaConnectException(
                'Timed out waiting for PeerConnection to connect');
          }
          practiceTransports.add(t);
          return t;
        },
      );
      await practice.start();
      expect(practiceTransports, hasLength(2));
      expect(practice.relayRetrying, isTrue);
      expect(practice.phase, VoiceSessionPhase.waking);
      expect(ayma.phase, VoiceSessionPhase.idle);

      practiceTransports.last.markAgentReady();
      await Future<void>.delayed(Duration.zero);
      expect(practice.phase, VoiceSessionPhase.live);

      await practice.stop();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bootstrapBodies, hasLength(2));
      expect(bootstrapBodies.last['practice_return_session_id'],
          'practice_v1');
      expect(ayma.isActive, isTrue);

      vended.last.markAgentReady();
      await Future<void>.delayed(Duration.zero);
      expect(ayma.phase, VoiceSessionPhase.live);
      await ayma.stop();
    });
  });

  // --- Single-active-voice-session invariant ------------------------------- //
  // Only ONE voice session may ever be live at a time across every surface.
  // Each surface is a separate controller with its own LiveKit room, so
  // starting one must first fully tear down any other active one — otherwise
  // two personas (e.g. main Ayma + a Practice Date persona) talk over each
  // other (founder report 2026-10-26).
  group('mutual exclusion', () {
    /// An API that answers both the main `/bootstrap` and the practice
    /// `/practice/voice/start` token endpoints with distinct LiveKit creds.
    ApiClient mutexApi() => ApiClient(
          auth: MockFirebaseAuth(signedIn: true),
          httpClient: MockClient((request) async {
            if (request.url.path == '/bootstrap') {
              return http.Response(
                jsonEncode({
                  'session_mode': 'marketing',
                  'uid': 'u1',
                  'livekit': {
                    'token': 'tok-main',
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
                headers: const {
                  'content-type': 'application/json; charset=utf-8'
                },
              );
            }
            if (request.url.path == '/post-turn' ||
                request.url.path == '/voice/context') {
              return http.Response(jsonEncode({'ok': true}), 200);
            }
            return http.Response('not found', 404);
          }),
        );

    test('starting a practice call disconnects an active main Ayma call',
        () async {
      final mainTransport = FakeVoiceTransport();
      final main = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: mutexApi(),
        transportFactory: () => mainTransport,
      );
      final practiceTransport = FakeVoiceTransport();
      final practice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        practiceOtherUid: 'her',
        apiClient: mutexApi(),
        transportFactory: () => practiceTransport,
      );

      await _startLive(main, mainTransport);
      expect(main.phase, VoiceSessionPhase.live);
      expect(VoiceSessionController.active, same(main));

      // Starting the practice call must tear the main call down first.
      await practice.start();

      expect(main.phase, VoiceSessionPhase.idle);
      expect(main.isActive, isFalse);
      expect(mainTransport.disconnectCalls, 1); // its room was closed
      expect(mainTransport.disposeCalls, 1);
      expect(practice.isActive, isTrue);
      expect(VoiceSessionController.active, same(practice));
      // Only the practice room is connected now — no overlap.
      expect(practiceTransport.connectedToken, 'tok-practice');

      await practice.stop();
      // Founder rule (2026-11-06): ending that practice call brings the
      // displaced main session back up (the debrief return). Drain the
      // return and stop it so it cannot leak into the next test.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await main.stop();
    });

    test('starting the main Ayma call disconnects an active practice call',
        () async {
      final practiceTransport = FakeVoiceTransport();
      final practice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        practiceOtherUid: 'her',
        apiClient: mutexApi(),
        transportFactory: () => practiceTransport,
      );
      final mainTransport = FakeVoiceTransport();
      final main = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: mutexApi(),
        transportFactory: () => mainTransport,
      );

      await _startLive(practice, practiceTransport);
      expect(practice.phase, VoiceSessionPhase.live);
      expect(VoiceSessionController.active, same(practice));

      await main.start();

      expect(practice.phase, VoiceSessionPhase.idle);
      expect(practice.isActive, isFalse);
      expect(practiceTransport.disconnectCalls, 1);
      expect(practiceTransport.disposeCalls, 1);
      expect(main.isActive, isTrue);
      expect(VoiceSessionController.active, same(main));
      expect(mainTransport.connectedToken, 'tok-main');

      await main.stop();
    });

    test('restarting the same controller does not tear itself down', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: mutexApi(),
        transportFactory: () => transport,
      );

      await _startLive(c, transport);
      // Already active: start() is a no-op, never a self-teardown.
      await c.start();

      expect(c.phase, VoiceSessionPhase.live);
      expect(transport.disconnectCalls, 0);
      expect(VoiceSessionController.active, same(c));

      await c.stop();
    });
  });

  // --- Honest error instead of a silent "Listening" ------------------------ //
  // AGENTS.md: when LiveKit (STT/TTS/LLM gateway) is not working, the voice UI
  // must SHOW AN HONEST ERROR, never a silent "Listening…". The gap: the agent
  // worker joins the LiveKit room and publishes a (silent) track even when the
  // inference gateway is 429/drained, so `agentReady` fires and the phase goes
  // `live` ("Listening…") — but no transcript / speech / tool event ever
  // follows. Without the no-first-response guard the call hangs on "Listening"
  // until the 4-minute idle guard ends it with a benign notice.
  group('honest error, never a silent "Listening"', () {
    test(
        'a live session that never produces a first response surfaces an '
        'honest error, not a stuck "Listening"', () async {
      final transport = FakeVoiceTransport();
      final reporter = _RecordingReporter();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        sessionId: 's-test',
        apiClient: _api(),
        transportFactory: () => transport,
        responseGuardTimeout: const Duration(milliseconds: 40),
        errorReporter: reporter,
      );

      await _startLive(c, transport);
      // The worker joined the room (agentReady), so the UI would say
      // "Listening…" — but the gateway is down, so nothing ever comes back.
      expect(c.phase, VoiceSessionPhase.live);
      expect(c.isListening, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Pre-fix this stayed `live` forever (stuck on "Listening"). Now it fails
      // loudly within the bound with an honest, retry-able message.
      expect(c.phase, VoiceSessionPhase.error);
      expect(c.isListening, isFalse);
      expect(c.errorMessage, contains('voice service'));
      expect(c.cappedError, isFalse);
      expect(transport.disconnectCalls, 1); // the dead session was torn down
      expect(
          reporter.reports.map((r) => r.reason), contains('voice_no_response'));
    });

    test(
        'open-weights warming status shows the specific warming line (not a '
        'silent "Listening") and extends the first-response budget', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
        // The generic guard would fire at 40ms — but the open-weights warming
        // signal must re-arm it to the (longer) open-weights budget so the
        // legitimate ~100s cold start is never mistaken for a dead brain.
        responseGuardTimeout: const Duration(milliseconds: 40),
        openWeightsResponseGuardTimeout: const Duration(seconds: 5),
      );

      await _startLive(c, transport);
      expect(c.warmingNotice, isNull); // generic path: no special copy yet
      transport.emitVoiceStatus('open_weights_warming');
      await Future<void>.delayed(Duration.zero);

      expect(c.warmingNotice, isNotNull);
      expect(c.warmingNotice, contains('Warming up the open-weights model'));

      // Past the generic 40ms budget: the call must still be live (the warming
      // re-arm moved the guard out to the open-weights budget), not errored.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(c.phase, VoiceSessionPhase.live);
      expect(c.errorMessage, isNull);
      await c.stop();
    });

    test(
        'open-weights that never warms in time surfaces the open-weights-'
        'specific "unavailable" copy, not the generic voice-service error',
        () async {
      final transport = FakeVoiceTransport();
      final reporter = _RecordingReporter();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
        responseGuardTimeout: const Duration(seconds: 5),
        openWeightsResponseGuardTimeout: const Duration(milliseconds: 40),
        errorReporter: reporter,
      );

      await _startLive(c, transport);
      transport.emitVoiceStatus('open_weights_warming');
      await Future<void>.delayed(Duration.zero);

      // The open-weights budget (40ms here) elapses with no reply.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(c.phase, VoiceSessionPhase.error);
      expect(c.errorMessage, contains('open-weights model is unavailable'));
      expect(c.errorMessage, contains('switch models'));
      expect(c.cappedError, isFalse);
      expect(reporter.reports.map((r) => r.reason),
          contains('voice_open_weights_no_response'));
      // A fresh start clears the warming latch so the next call isn't tainted.
      expect(c.warmingNotice, isNull);
    });

    test(
        'a cascade TTS error surfaces an honest "reconnecting" status (never a '
        'silent "Listening"), cleared when the recovered voice speaks', () async {
      // Founder bug (staging 2026-11-03): switching to the Meta cascade failed
      // SILENTLY — the TTS leg errored on an unknown voice, so no audio played
      // and the UI sat on "Listening…". The agent now signals `tts_error` and
      // the controller must surface it honestly.
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
        // Keep the no-first-response guard well clear — this tests the TTS-error
        // status, not the guard.
        responseGuardTimeout: const Duration(seconds: 30),
      );

      await _startLive(c, transport);
      expect(c.voiceTrouble, isFalse);

      transport.emitVoiceStatus('tts_error');
      await Future<void>.delayed(Duration.zero);
      expect(c.voiceTrouble, isTrue,
          reason: 'a TTS error must show honest status, never silent dead air');

      // The ERROR-close fallback recovers to Gemini Live; its audio clears the
      // "reconnecting" status.
      transport.agentSpeakingController.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.voiceTrouble, isFalse);

      await c.stop();
    });

    test(
        'a genuine first response (speech) cancels the guard — a working call '
        'stays live and never errors', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
        responseGuardTimeout: const Duration(milliseconds: 40),
      );

      await _startLive(c, transport);
      // Ayma's opener lands well inside the bound.
      transport.agentSpeakingController.add(true);
      await Future<void>.delayed(Duration.zero);

      // Longer than the guard: a healthy call must not be falsely errored.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(c.phase, VoiceSessionPhase.live);
      expect(c.errorMessage, isNull);
      await c.stop();
    });

    test(
        'an agent_transcript also counts as a first response and keeps the '
        'call live', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
        responseGuardTimeout: const Duration(milliseconds: 40),
      );

      await _startLive(c, transport);
      transport.transcriptsController.add(const TranscriptSegment(
        topic: 'agent_transcript',
        text: 'Hey — good to hear you.',
        isFinal: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(c.phase, VoiceSessionPhase.live);
      expect(c.errorMessage, isNull);
      await c.stop();
    });

    test('"Listening" (isListening) is false until the agent is ready, true '
        'only after', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
      );

      await c.start();
      // Room connected + mic publishing, but the agent has NOT joined: the UI
      // shows "Waking Ayma…", and we are explicitly not yet listening.
      expect(c.phase, VoiceSessionPhase.waking);
      expect(c.isListening, isFalse);

      transport.markAgentReady();
      await Future<void>.delayed(Duration.zero);

      expect(c.phase, VoiceSessionPhase.live);
      expect(c.isListening, isTrue);
      await c.stop();
    });
  });

  // --- First-response window + honest "Connecting…" wait state -------------- //
  // Staging voice-silence audit (2026-11-02): a healthy LiveKit Inference
  // Realtime first reply takes ~9–12s. The no-first-response guard must stay
  // clear of that (20s — never shrink back toward the generation time), and
  // while the opener is in flight the UI shows an honest "Connecting…"
  // instead of "Listening…", so a slow first reply never reads as a silently
  // dead call. If no reply lands inside the window the guard above still
  // surfaces the honest error.
  group('first-response window and honest waiting state', () {
    test('the default first-response window stays clear of a slow (~9–12s) '
        'first reply', () async {
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => FakeVoiceTransport(),
      );
      // Pinned: shrinking this toward the ~9–12s generation time re-opens
      // the audit's race (slow-but-healthy replies treated as failed calls).
      expect(
        c.firstResponseBudgetForTest,
        greaterThanOrEqualTo(const Duration(seconds: 20)),
      );
      c.dispose();
    });

    test('awaitingFirstResponse is true at live, false once the first agent '
        'transcript lands (and the flip notifies)', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
      );

      expect(c.awaitingFirstResponse, isFalse); // idle: nothing awaited

      await _startLive(c, transport);
      expect(c.phase, VoiceSessionPhase.live);
      // Live, but the opener hasn't landed: the UI reads "Connecting…".
      expect(c.awaitingFirstResponse, isTrue);

      var notified = 0;
      c.addListener(() => notified++);
      transport.transcriptsController.add(const TranscriptSegment(
        topic: 'agent_transcript',
        text: 'Hey — good to hear you.',
        isFinal: true,
      ));
      await Future<void>.delayed(Duration.zero);

      // A transcript-only first reply still flips (and rebuilds) the status.
      expect(c.awaitingFirstResponse, isFalse);
      expect(notified, greaterThan(0));
      await c.stop();
    });

    test('awaitingFirstResponse also clears on first speech', () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
      );

      await _startLive(c, transport);
      expect(c.awaitingFirstResponse, isTrue);

      transport.agentSpeakingController.add(true);
      await Future<void>.delayed(Duration.zero);

      expect(c.awaitingFirstResponse, isFalse);
      await c.stop();
    });
  });

  // Founder report 2026-11-02: tapping the orb rapidly opened MULTIPLE
  // concurrent LiveKit sessions that spoke over each other. `start()` must be
  // single-flight — at most ONE session ever starts no matter how many
  // near-simultaneous calls arrive. `bootstrapCalls` (one `/bootstrap` per
  // admitted start) and the number of transports built are the hard counters.
  group('single-flight start() (rapid orb taps -> exactly one session)', () {
    test('three near-simultaneous start() calls open exactly ONE session',
        () async {
      var transportsBuilt = 0;
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () {
          transportsBuilt++;
          return FakeVoiceTransport();
        },
      );

      // Fire three in the same synchronous burst (one frame of rapid taps) —
      // do NOT await between them, so a 2nd/3rd tap lands during the 1st's
      // async connect, exactly as the rapid taps did.
      final f1 = c.start();
      final f2 = c.start();
      final f3 = c.start();
      await Future.wait([f1, f2, f3]);

      expect(bootstrapCalls, 1, reason: 'only one /bootstrap may fire');
      expect(transportsBuilt, 1, reason: 'only one LiveKit room may connect');
      expect(c.phase, VoiceSessionPhase.waking);

      await c.stop();
    });

    test(
        'the gap case: a start() that must first tear down ANOTHER active '
        'session still admits only one of a concurrent burst', () async {
      // An existing, already-live session on a different controller forces the
      // new start() through its `await existing.stop()` — the exact async gap
      // where, before the `_starting` latch, a 2nd near-simultaneous tap slid
      // past the `isActive` check and opened a second room.
      final otherTransport = FakeVoiceTransport();
      final other = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => otherTransport,
      );
      await _startLive(other, otherTransport);
      expect(other.isListening, isTrue);
      bootstrapCalls = 0; // count only the new controller's starts

      var transportsBuilt = 0;
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () {
          transportsBuilt++;
          return FakeVoiceTransport();
        },
      );

      final f1 = c.start();
      final f2 = c.start();
      final f3 = c.start();
      await Future.wait([f1, f2, f3]);

      expect(bootstrapCalls, 1, reason: 'one /bootstrap despite the stop() gap');
      expect(transportsBuilt, 1, reason: 'exactly one room, never two');
      expect(other.phase, VoiceSessionPhase.idle,
          reason: 'the previous session was torn down');
      expect(VoiceSessionController.active, same(c));

      await c.stop();
    });

    test('a 2nd start() while already live is a no-op (no 2nd session)',
        () async {
      final transport = FakeVoiceTransport();
      final c = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
      );

      await _startLive(c, transport);
      expect(c.isListening, isTrue);
      expect(bootstrapCalls, 1);

      await c.start(); // tapping the orb again while the call is live
      expect(bootstrapCalls, 1, reason: 'no second /bootstrap while live');
      expect(c.phase, VoiceSessionPhase.live);

      await c.stop();
    });
  });
}
