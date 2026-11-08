import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// A voice controller the test can park in `live` without a real
/// /bootstrap or LiveKit room (mirrors chat_voice_out_of_credits_test's
/// _FakeVoice). [stop] is the real teardown entry point the chat screen
/// calls for a typed disconnect — here it just counts and goes idle.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  int stopCalls = 0;

  @override
  VoiceSessionPhase get phase => _phase;

  @override
  bool get isActive =>
      _phase == VoiceSessionPhase.connecting ||
      _phase == VoiceSessionPhase.waking ||
      _phase == VoiceSessionPhase.live;

  @override
  bool get isListening => _phase == VoiceSessionPhase.live;

  void goLive() {
    _phase = VoiceSessionPhase.live;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _phase = VoiceSessionPhase.idle;
    notifyListeners();
  }
}

/// An ApiClient whose /chat/stream (and /chat fallback) record their
/// request bodies and answer with a fixed reply.
class _Capture {
  final bodies = <Map<String, dynamic>>[];

  ApiClient api() {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({'messages': <dynamic>[], 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      if (request.url.path == '/chat/stream') {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        final body = [
          'data: ${jsonEncode({
                'type': 'reply',
                'text': 'Done.',
                'tools_used': <String>[],
              })}',
          '',
          '',
        ].join('\n');
        return http.Response(body, 200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'});
      }
      if (request.url.path == '/chat') {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'reply': 'Done.',
            'tools_used': <String>[],
            'capped': false,
            'fallback_form': false,
            'usage_capped': false,
          }),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    return ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
  }
}

/// Bounded pumps instead of pumpAndSettle: with a call live, the chat
/// screen's voice UI animates perpetually and never "settles".
Future<void> _pumpFrames(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpChat(
    WidgetTester tester, _Capture capture, _FakeVoice voice) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(apiClient: capture.api(), voiceController: voice),
  ));
  await _pumpFrames(tester);
}


Future<void> _pumpScopedChat(WidgetTester tester, _Capture capture) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      apiClient: capture.api(),
      askAymaContext: const AskAymaContext(
        pageId: 'career',
        selectedText: 'some passage',
      ),
    ),
  ));
  await _pumpFrames(tester);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
  await _pumpFrames(tester, frames: 30);
}

void main() {
  setUp(() {
    VoiceSessionController.debugClearLastCallEnd();
    VoiceSessionController.active = null;
  });
  tearDown(() {
    ChatInbox.instance.take();
    VoiceSessionController.debugClearLastCallEnd();
    VoiceSessionController.active = null;
  });

  testWidgets(
      'a typed "disconnect please" during a live call ends the call and '
      'the turn is stamped just-ended (text_disconnect)', (tester) async {
    final capture = _Capture();
    // The live call is a different controller than this screen's own —
    // exactly the production shape: the call lives on the process-wide
    // active session while the user types in a scoped sheet.
    final voice = _FakeVoice()..goLive();
    VoiceSessionController.active = voice;
    await _pumpScopedChat(tester, capture);

    await _send(tester, 'disconnect please');

    expect(voice.stopCalls, 1);
    expect(capture.bodies, isNotEmpty);
    final callState = capture.bodies.last['call_state'] as Map;
    expect(callState['in_call'], isFalse);
    expect(callState['end_reason'], 'text_disconnect');
    expect(callState['ended_seconds_ago'], 0);
  });

  testWidgets(
      'a disconnect typed after an idle-ended call is stamped with the '
      'ended call, so Ayma acknowledges it instead of denying it',
      (tester) async {
    VoiceSessionController.debugSetLastCallEnd(
      DateTime.now().subtract(const Duration(seconds: 60)),
      'client_idle_timeout',
    );
    final capture = _Capture();
    final voice = _FakeVoice(); // idle — the call already ended
    await _pumpChat(tester, capture, voice);

    await _send(tester, 'disconnect please');

    // Nothing live to end — and the payload still names the call that
    // DID happen, with how it ended.
    expect(voice.stopCalls, 0);
    expect(capture.bodies, isNotEmpty);
    final callState = capture.bodies.last['call_state'] as Map;
    expect(callState['in_call'], isFalse);
    expect(callState['end_reason'], 'client_idle_timeout');
    expect(callState['ended_seconds_ago'], closeTo(60, 10));
  });

  testWidgets(
      'an ordinary message during a live call does not end it and the '
      'turn is stamped in_call', (tester) async {
    final capture = _Capture();
    final voice = _FakeVoice()..goLive();
    VoiceSessionController.active = voice;
    await _pumpScopedChat(tester, capture);

    await _send(tester, 'hello, how are you?');

    expect(voice.stopCalls, 0);
    final callState = capture.bodies.last['call_state'] as Map;
    expect(callState['in_call'], isTrue);
  });

  testWidgets(
      '"I feel disconnected" during a live call does not end it',
      (tester) async {
    final capture = _Capture();
    final voice = _FakeVoice()..goLive();
    VoiceSessionController.active = voice;
    await _pumpScopedChat(tester, capture);

    await _send(tester, 'I feel disconnected');

    expect(voice.stopCalls, 0);
    final callState = capture.bodies.last['call_state'] as Map;
    expect(callState['in_call'], isTrue);
  });
}
