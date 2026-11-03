// App-lifecycle teardown for a voice session (founder privacy bug 2026-11-03):
// the microphone and the OS call surface must be GUARANTEED released whenever
// the app is closed/detached — never left held behind a backgrounded or killed
// app. These drive the controller's lifecycle hook directly
// ([debugDispatchLifecycle], the exact entry the installed
// WidgetsBindingObserver forwards to) so the detach/pause behaviour is proven
// deterministically, independent of the test binding's lifecycle dispatch.
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/call_background_service.dart';
import 'package:ayma_flutter/services/call_permissions.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mockHttp, auth: auth);
}

class _FakeGateway implements PermissionGateway {
  @override
  Future<bool> isNotificationGranted() async => true;
  @override
  Future<bool> requestNotification() async => true;
  @override
  Future<bool> openAppSettings() async => true;
}

VoiceSessionController _controller(FakeVoiceTransport transport) =>
    VoiceSessionController(
      transcriptStore: TranscriptStore(),
      apiClient: _api(),
      transportFactory: () => transport,
      callPermissions: CallPermissions(gateway: _FakeGateway()),
    );

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Drives the controller to a genuinely conversing call: connect, agent joins,
/// Ayma's first response lands (mic published, OS surface eligible).
Future<void> _driveToConversing(
    VoiceSessionController c, FakeVoiceTransport t) async {
  await c.start();
  t.markAgentReady();
  await Future<void>.delayed(Duration.zero);
  t.emitAgentSpeaking(true);
  t.emitAgentSpeaking(false);
  await _settle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ayma/call_ui');

  tearDown(() {
    VoiceSessionController.active = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('app detached during a live call releases the mic and dismisses the '
      'call notification', () async {
    final transport = FakeVoiceTransport();
    final voice = _controller(transport);

    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final service = CallBackgroundService(
      voice,
      permissions: CallPermissions(gateway: _FakeGateway()),
      debugSupportedOverride: true,
    )..start();

    await _driveToConversing(voice, transport);
    expect(voice.isConversationReady, isTrue);
    expect(transport.micCalls, [true]); // mic captured
    expect(service.debugUiActive, isTrue); // notification up
    calls.clear();

    // The app (engine) is being destroyed.
    voice.debugDispatchLifecycle(AppLifecycleState.detached);
    await _settle();

    expect(voice.phase, VoiceSessionPhase.idle); // call ended
    expect(transport.disconnectCalls, 1); // mic/room released
    expect(service.debugUiActive, isFalse); // notification torn down
    expect(calls.map((c) => c.method), contains('stop'));

    service.dispose();
  });

  test('app backgrounded while still connecting/warming (not yet '
      'conversation-ready) tears the session down — nothing held in the '
      'background', () async {
    final transport = FakeVoiceTransport();
    final voice = _controller(transport);

    await voice.start();
    transport.markAgentReady();
    await _settle();
    // Live but awaiting the first response (e.g. open-weights still warming):
    // no mic captured, no OS surface — and no mic FGS can legally start once
    // backgrounded, so this session must not linger holding a room.
    expect(voice.phase, VoiceSessionPhase.live);
    expect(voice.isConversationReady, isFalse);
    expect(transport.micCalls, isEmpty);

    voice.debugDispatchLifecycle(AppLifecycleState.paused);
    await _settle();

    expect(voice.phase, VoiceSessionPhase.idle);
    expect(transport.disconnectCalls, 1);
  });

  test('app backgrounded DURING a live, conversing call keeps it alive (the '
      'intended background call) — not torn down', () async {
    final transport = FakeVoiceTransport();
    final voice = _controller(transport);

    await _driveToConversing(voice, transport);
    expect(voice.isConversationReady, isTrue);

    voice.debugDispatchLifecycle(AppLifecycleState.paused);
    await _settle();

    // A genuinely live call rides on the foreground-service / CallKit surface
    // while backgrounded — exactly like a real phone call — so it stays up.
    expect(voice.phase, VoiceSessionPhase.live);
    expect(voice.isConversationReady, isTrue);
    expect(transport.disconnectCalls, 0);

    await voice.stop();
  });
}
