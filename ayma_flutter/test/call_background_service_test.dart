import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/call_background_service.dart';
import 'package:ayma_flutter/services/call_permissions.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

class _FakeGateway implements PermissionGateway {
  _FakeGateway({this.granted = true});
  bool granted;

  @override
  Future<bool> isNotificationGranted() async => granted;

  @override
  Future<bool> requestNotification() async => granted;

  @override
  Future<bool> openAppSettings() async => true;
}

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

Future<VoiceSessionController> _liveController(
  FakeVoiceTransport transport, {
  CallPermissions? callPermissions,
}) async {
  final c = VoiceSessionController(
    transcriptStore: TranscriptStore(),
    apiClient: _api(),
    transportFactory: () => transport,
    callPermissions: callPermissions,
  );
  await c.start();
  transport.markAgentReady();
  await Future<void>.delayed(Duration.zero);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ayma/call_ui');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('native -> Dart actions route into VoiceSessionController', () {
    test('hangUp stops the live call', () async {
      final transport = FakeVoiceTransport();
      final voice = await _liveController(transport);
      final service = CallBackgroundService(voice, debugSupportedOverride: true);

      expect(voice.phase, VoiceSessionPhase.live);
      await service.debugHandleNativeCall(const MethodCall('hangUp'));

      expect(voice.phase, VoiceSessionPhase.idle);
      expect(transport.disconnectCalls, 1);
    });

    test('toggleMute flips the mic (mirrors the notification Mute button)',
        () async {
      final transport = FakeVoiceTransport();
      final voice = await _liveController(transport);
      final service = CallBackgroundService(voice, debugSupportedOverride: true);

      await service.debugHandleNativeCall(const MethodCall('toggleMute'));

      expect(voice.muted, isTrue);
      expect(transport.micCalls, [true, false]);
    });

    test('setMuted mirrors CallKit\'s own mute button only on an actual '
        'change', () async {
      final transport = FakeVoiceTransport();
      final voice = await _liveController(transport);
      final service = CallBackgroundService(voice, debugSupportedOverride: true);

      // Same state as now (false) — a no-op, not a spurious toggle.
      await service.debugHandleNativeCall(
        const MethodCall('setMuted', {'muted': false}),
      );
      expect(voice.muted, isFalse);
      expect(transport.micCalls, [true]);

      // A real change — mirrors into the one state machine.
      await service.debugHandleNativeCall(
        const MethodCall('setMuted', {'muted': true}),
      );
      expect(voice.muted, isTrue);
      expect(transport.micCalls, [true, false]);
    });
  });

  group('backgrounding', () {
    test('missing the notification permission stops the call with an '
        'explanation instead of silently killing it', () async {
      final transport = FakeVoiceTransport();
      final gateway = _FakeGateway(granted: false);
      final voice = await _liveController(
        transport,
        callPermissions: CallPermissions(gateway: gateway),
      );
      final service = CallBackgroundService(
        voice,
        permissions: CallPermissions(gateway: gateway),
        debugSupportedOverride: true,
      );

      // Started the moment the call is live — never on backgrounding (that
      // reactive trigger is exactly what crashed the app on-device: Android
      // rejects starting a microphone-typed foreground service after the app
      // has already left the foreground). `start()` attaches to an
      // already-live call eagerly, covering both a fresh call and one this
      // service attaches to mid-flight.
      service.start();
      await Future<void>.delayed(Duration.zero);

      expect(voice.phase, VoiceSessionPhase.error);
      expect(voice.backgroundPermissionDenied, isTrue);
      expect(voice.errorMessage, contains('notification'));
      expect(service.debugUiActive, isFalse);
    });

    test('a granted permission starts the native call UI the moment the '
        'call goes live', () async {
      final transport = FakeVoiceTransport();
      final gateway = _FakeGateway(granted: true);
      final voice = await _liveController(
        transport,
        callPermissions: CallPermissions(gateway: gateway),
      );
      final service = CallBackgroundService(
        voice,
        permissions: CallPermissions(gateway: gateway),
        debugSupportedOverride: true,
      );

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      service.start();
      await Future<void>.delayed(Duration.zero);

      expect(service.debugUiActive, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'start');
      expect(voice.phase, VoiceSessionPhase.live); // never touched the call

      // Backgrounding/foregrounding no longer starts or stops the OS
      // surface — it stays up for the whole call, exactly like a real phone
      // call notification does, foreground or not.
      await Future<void>.delayed(Duration.zero);
      expect(service.debugUiActive, isTrue);
      expect(calls, hasLength(1));

      await voice.stop();
      await Future<void>.delayed(Duration.zero);

      expect(service.debugUiActive, isFalse);
      expect(calls.last.method, 'stop');
    });
  });
}
