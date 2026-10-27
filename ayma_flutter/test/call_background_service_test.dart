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

    test('unmuteAyma asks the agent to talk again (notification '
        '"Unmute Ayma")', () async {
      final transport = FakeVoiceTransport();
      final voice = await _liveController(transport);
      final service = CallBackgroundService(voice, debugSupportedOverride: true);

      transport.emitAgentMute(true);
      await Future<void>.delayed(Duration.zero);
      await service.debugHandleNativeCall(const MethodCall('unmuteAyma'));

      expect(transport.muteControlCalls, [false]);
      // The user's own mic is untouched.
      expect(voice.muted, isFalse);
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

  group('the call notification is gated on the listening state', () {
    test('no call notification while connecting/waking; it appears only once '
        'Ayma is genuinely listening', () async {
      final transport = FakeVoiceTransport();
      final gateway = _FakeGateway(granted: true);
      final voice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _api(),
        transportFactory: () => transport,
        callPermissions: CallPermissions(gateway: gateway),
      );
      // Start the call but DO NOT mark the agent ready — the controller
      // settles in `waking` (room connected, mic published, agent still
      // cold-starting), exactly the window the founder saw the call
      // notification appear in.
      await voice.start();
      expect(voice.phase, VoiceSessionPhase.waking);

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      final service = CallBackgroundService(
        voice,
        permissions: CallPermissions(gateway: gateway),
        debugSupportedOverride: true,
      )..start();
      await Future<void>.delayed(Duration.zero);

      // Connecting/waking: the mic foreground service and its notification
      // must NOT be up yet — nothing was posted to the OS.
      expect(service.debugUiActive, isFalse);
      expect(calls, isEmpty);

      // The agent joins — now, and only now, the call surface appears.
      transport.markAgentReady();
      await Future<void>.delayed(Duration.zero);

      expect(voice.phase, VoiceSessionPhase.live);
      expect(service.debugUiActive, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'start');

      service.dispose();
      await voice.stop();
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

  group('notification reflects Ayma\'s quiet state', () {
    test('agent_mute updates the notification text and Unmute Ayma flag, '
        'with or without the app in the foreground', () async {
      final transport = FakeVoiceTransport();
      final gateway = _FakeGateway(granted: true);
      final voice = await _liveController(
        transport,
        callPermissions: CallPermissions(gateway: gateway),
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final service = CallBackgroundService(
        voice,
        permissions: CallPermissions(gateway: gateway),
        debugSupportedOverride: true,
      )..start();
      await Future<void>.delayed(Duration.zero);
      Map args() => calls.last.arguments as Map;
      expect(args()['status'], 'Voice call');
      expect(args()['aymaQuiet'], isFalse);

      // Backgrounding changes nothing: the service is driven by the
      // controller, not by lifecycle, so a locked screen still updates.
      transport.emitAgentMute(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.method, 'update');
      expect(args()['aymaQuiet'], isTrue);
      expect(args()['status'], CallBackgroundService.quietStatus);

      // The user's mic state never hides that Ayma is quiet.
      await service.debugHandleNativeCall(const MethodCall('toggleMute'));
      await Future<void>.delayed(Duration.zero);
      expect(args()['muted'], isTrue);
      expect(args()['status'], CallBackgroundService.quietStatus);

      transport.emitAgentMute(false);
      await Future<void>.delayed(Duration.zero);
      expect(args()['aymaQuiet'], isFalse);
      expect(args()['status'], 'Mic muted');

      service.dispose();
      await voice.stop();
    });
  });

  group('shared across shells (notification Hang Up / Mute stay wired)', () {
    Future<void> tapFromNotification(String method) async {
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method)),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
    }

    test('a second shell disposing keeps the first one\'s handler, so the '
        'notification still mutes and hangs up the call', () async {
      final transport = FakeVoiceTransport();
      final gateway = _FakeGateway(granted: true);
      final voice = await _liveController(
        transport,
        callPermissions: CallPermissions(gateway: gateway),
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      // Shell A is up during the call; shell B is pushed / built as its
      // replacement, then shell A (or B) is disposed.
      final a = CallBackgroundService.acquire(
        voice,
        permissions: CallPermissions(gateway: gateway),
        debugSupportedOverride: true,
      );
      final b = CallBackgroundService.acquire(voice);
      expect(identical(a, b), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c.method == 'start'), hasLength(1));

      a.release();
      expect(a.debugUiActive, isTrue);

      await tapFromNotification('toggleMute');
      expect(voice.muted, isTrue);
      expect(calls.last.method, 'update');
      expect((calls.last.arguments as Map)['muted'], isTrue);

      await tapFromNotification('toggleMute');
      expect(voice.muted, isFalse);

      await tapFromNotification('hangUp');
      expect(voice.phase, VoiceSessionPhase.idle);
      expect(transport.disconnectCalls, 1);
      expect(calls.last.method, 'stop');
      expect(b.debugUiActive, isFalse);

      b.release();
    });

    test('the last release unhooks the handler and a later acquire starts '
        'a fresh service', () async {
      final transport = FakeVoiceTransport();
      final voice = await _liveController(transport);
      final first =
          CallBackgroundService.acquire(voice, debugSupportedOverride: true);
      first.release();

      await tapFromNotification('hangUp');
      expect(voice.phase, VoiceSessionPhase.live);

      final second =
          CallBackgroundService.acquire(voice, debugSupportedOverride: true);
      expect(identical(first, second), isFalse);
      await tapFromNotification('hangUp');
      expect(voice.phase, VoiceSessionPhase.idle);
      second.release();
    });

    test('disposing an older instance never clears a newer one\'s handler',
        () async {
      final transport = FakeVoiceTransport();
      final voice = await _liveController(transport);
      final older =
          CallBackgroundService(voice, debugSupportedOverride: true)..start();
      final newer =
          CallBackgroundService(voice, debugSupportedOverride: true)..start();
      older.dispose();

      await tapFromNotification('hangUp');
      expect(voice.phase, VoiceSessionPhase.idle);
      newer.dispose();
    });
  });
}
