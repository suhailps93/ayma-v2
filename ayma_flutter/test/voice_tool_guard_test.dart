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

/// A running voice tool whose completion ("end") never arrives must not leave
/// the session frozen on a "Working…"/tool label forever (founder, 2026-11-03:
/// the voice session hung on "Working…"). The silent hang was a tool `start`
/// with no matching `end`: `activeToolLabel` stayed set, the response guard was
/// already cancelled, and the idle guard refused to fire while a label was set.
/// These cover the two recovery paths: the bounded tool guard, and a new user
/// turn clearing the stale label. Plain `test()` + real (short) delays, to
/// match the rest of voice_session_controller_test and let the real Timer fire.
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

  test('a tool start with no end recovers via the tool guard — the label '
      'clears and the call stays live (never a frozen "Working…")', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      toolGuardTimeout: const Duration(milliseconds: 200),
    );
    await _startLive(c, transport);
    expect(c.phase, VoiceSessionPhase.live);

    // A tool starts and its "end" is never delivered (orphaned turn).
    transport.toolEventsController.add(const ToolUsedEvent(
        name: 'advance_guided_tour', label: 'Working…', phase: 'start'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.activeToolLabel, 'Working…');

    // The tool guard fires: the stuck label clears, the call stays LIVE
    // (non-destructive recovery) — no perpetual "Working…".
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(c.activeToolLabel, isNull);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
  });

  test('a new user turn clears a stuck tool label immediately', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      // Long guard, so this proves the user-turn path clears it, not the timer.
      toolGuardTimeout: const Duration(minutes: 5),
    );
    await _startLive(c, transport);

    transport.toolEventsController.add(const ToolUsedEvent(
        name: 'research', label: 'Researching…', phase: 'start'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.activeToolLabel, 'Researching…');

    // The user speaks again — the stale label must not linger across the turn.
    transport.transcriptsController.add(const TranscriptSegment(
        topic: 'user_transcript', text: 'what now?', isFinal: true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.activeToolLabel, isNull);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
  });

  test('a normal tool start→end does not trip the guard', () async {
    final transport = FakeVoiceTransport();
    final c = VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      toolGuardTimeout: const Duration(milliseconds: 150),
    );
    await _startLive(c, transport);

    transport.toolEventsController.add(const ToolUsedEvent(
        name: 'open_screen', label: 'Opening…', phase: 'start'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.activeToolLabel, 'Opening…');
    // Ends promptly — the guard is cancelled, nothing fires later.
    transport.toolEventsController.add(const ToolUsedEvent(
        name: 'open_screen', label: 'Opened', phase: 'end'));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(c.activeToolLabel, isNull);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
  });
}
