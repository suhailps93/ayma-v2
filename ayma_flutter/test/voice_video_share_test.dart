import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/screen_share_platform.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/services/voice_transport.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

/// In-memory [ScreenSharePlatform]: records the consent/service flow and
/// lets each test decide the consent outcome — no platform channel, no
/// MediaProjection dialog.
class _FakeScreenSharePlatform implements ScreenSharePlatform {
  bool supported = true;
  bool consent = true;
  int consentCalls = 0;
  int startServiceCalls = 0;
  int stopServiceCalls = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> requestConsent() async {
    consentCalls++;
    return consent;
  }

  @override
  Future<void> startProjectionService() async {
    startServiceCalls++;
  }

  @override
  Future<void> stopProjectionService() async {
    stopServiceCalls++;
  }
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

/// A controller driven to a genuinely conversing call (live + first agent
/// response, so `isConversationReady` holds and capture may begin), with
/// the serving stack declaring whether it can perceive video.
Future<VoiceSessionController> _readyCall(
  FakeVoiceTransport transport, {
  _FakeScreenSharePlatform? platform,
  bool visionSupported = true,
}) async {
  final c = VoiceSessionController(
    transcriptStore: TranscriptStore(),
    apiClient: _api(),
    transportFactory: () => transport,
    screenSharePlatform: platform ?? _FakeScreenSharePlatform(),
  );
  await c.start();
  transport.markAgentReady();
  await Future<void>.delayed(Duration.zero);
  if (visionSupported) {
    transport.emitVoiceStatus('vision_supported');
    await Future<void>.delayed(Duration.zero);
  }
  transport.emitAgentSpeaking(true);
  await Future<void>.delayed(Duration.zero);
  expect(c.phase, VoiceSessionPhase.live);
  expect(c.isConversationReady, isTrue);
  return c;
}

/// Let unawaited sends (the vision-control data messages) land.
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
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

  test('video toggle publishes then unpublishes the camera track', () async {
    final transport = FakeVoiceTransport();
    final c = await _readyCall(transport);
    expect(c.visionSupported, isTrue);

    await c.toggleVideo();
    await _settle();
    expect(c.videoOn, isTrue);
    expect(transport.cameraCalls, [true]);
    expect(transport.visionControlCalls, [(source: 'camera', active: true)]);

    await c.toggleVideo();
    await _settle();
    expect(c.videoOn, isFalse);
    expect(transport.cameraCalls, [true, false]);
    expect(transport.visionControlCalls, [
      (source: 'camera', active: true),
      (source: 'camera', active: false),
    ]);

    await c.stop();
  });

  test('without a vision-capable stack the toggles never publish', () async {
    final transport = FakeVoiceTransport();
    final platform = _FakeScreenSharePlatform();
    final c = await _readyCall(
      transport,
      platform: platform,
      visionSupported: false,
    );
    expect(c.visionSupported, isFalse);

    await c.toggleVideo();
    await c.toggleScreenShare();
    await _settle();
    expect(c.videoOn, isFalse);
    expect(c.screenShareOn, isFalse);
    expect(transport.cameraCalls, isEmpty);
    expect(transport.screenShareCalls, isEmpty);
    // Not even a consent dialog: the control simply does not exist here.
    expect(platform.consentCalls, 0);

    await c.stop();
  });

  test(
    'an explicit vision_unsupported declaration also gates the toggles',
    () async {
      final transport = FakeVoiceTransport();
      final c = await _readyCall(transport, visionSupported: false);
      transport.emitVoiceStatus('vision_unsupported');
      await _settle();
      expect(c.visionSupported, isFalse);

      await c.toggleVideo();
      expect(transport.cameraCalls, isEmpty);

      await c.stop();
    },
  );

  test('a denied camera permission leaves the voice call untouched', () async {
    final transport = FakeVoiceTransport()..failCamera = true;
    final c = await _readyCall(transport);
    final micCallsBefore = List.of(transport.micCalls);

    await c.toggleVideo();
    await _settle();

    expect(c.videoOn, isFalse);
    expect(c.visionNotice, contains('camera access'));
    // The call itself: still live, mic state exactly as it was.
    expect(c.phase, VoiceSessionPhase.live);
    expect(c.errorMessage, isNull);
    expect(transport.micCalls, micCallsBefore);
    expect(transport.disconnectCalls, 0);

    await c.stop();
  });

  test('screen share runs consent, then the service, then publishes', () async {
    final transport = FakeVoiceTransport();
    final platform = _FakeScreenSharePlatform();
    final c = await _readyCall(transport, platform: platform);

    await c.toggleScreenShare();
    await _settle();
    expect(c.screenShareOn, isTrue);
    expect(platform.consentCalls, 1);
    expect(platform.startServiceCalls, 1);
    expect(transport.screenShareCalls, [true]);
    expect(transport.visionControlCalls, [(source: 'screen', active: true)]);

    await c.toggleScreenShare();
    await _settle();
    expect(c.screenShareOn, isFalse);
    expect(transport.screenShareCalls, [true, false]);
    expect(platform.stopServiceCalls, 1);
    expect(transport.visionControlCalls, [
      (source: 'screen', active: true),
      (source: 'screen', active: false),
    ]);

    await c.stop();
  });

  test(
    'a denied MediaProjection consent leaves the voice call untouched',
    () async {
      final transport = FakeVoiceTransport();
      final platform = _FakeScreenSharePlatform()..consent = false;
      final c = await _readyCall(transport, platform: platform);

      await c.toggleScreenShare();
      await _settle();

      expect(c.screenShareOn, isFalse);
      expect(c.visionNotice, isNull);
      expect(platform.consentCalls, 1);
      expect(platform.startServiceCalls, 0);
      expect(transport.screenShareCalls, isEmpty);
      expect(c.phase, VoiceSessionPhase.live);
      expect(transport.disconnectCalls, 0);

      await c.stop();
    },
  );

  test(
    'a failed screen-share publish downgrades the service and notifies',
    () async {
      final transport = FakeVoiceTransport()..failScreenShare = true;
      final platform = _FakeScreenSharePlatform();
      final c = await _readyCall(transport, platform: platform);

      await c.toggleScreenShare();
      await _settle();

      expect(c.screenShareOn, isFalse);
      expect(platform.startServiceCalls, 1);
      expect(platform.stopServiceCalls, 1);
      expect(c.visionNotice, contains('could not start'));
      expect(c.phase, VoiceSessionPhase.live);

      await c.stop();
    },
  );

  test('screen share refuses quietly on an unsupported platform', () async {
    final transport = FakeVoiceTransport();
    final platform = _FakeScreenSharePlatform()..supported = false;
    final c = await _readyCall(transport, platform: platform);

    await c.toggleScreenShare();
    await _settle();

    expect(c.screenShareOn, isFalse);
    expect(platform.consentCalls, 0);
    expect(transport.screenShareCalls, isEmpty);
    expect(c.phase, VoiceSessionPhase.live);

    await c.stop();
  });

  test(
    'session end unpublishes both vision tracks and drops the service',
    () async {
      final transport = FakeVoiceTransport();
      final platform = _FakeScreenSharePlatform();
      final c = await _readyCall(transport, platform: platform);

      await c.toggleVideo();
      await c.toggleScreenShare();
      await _settle();
      expect(c.videoOn, isTrue);
      expect(c.screenShareOn, isTrue);

      await c.stop();
      await _settle();

      expect(c.videoOn, isFalse);
      expect(c.screenShareOn, isFalse);
      expect(c.visionSupported, isFalse);
      expect(transport.cameraCalls, [true, false]);
      expect(transport.screenShareCalls, [true, false]);
      expect(platform.stopServiceCalls, greaterThanOrEqualTo(1));
      expect(transport.disconnectCalls, 1);
    },
  );

  test('secure-content state surfaces the protected-content notice', () async {
    final transport = FakeVoiceTransport();
    final c = await _readyCall(transport);

    // Nothing shared yet: a stale signal must not invent a notice.
    transport.emitVisionState(visionStateSecureContent);
    await _settle();
    expect(c.visionNotice, isNull);

    await c.toggleScreenShare();
    await _settle();
    transport.emitVisionState(visionStateSecureContent);
    await _settle();
    expect(c.visionNotice, contains('protected content'));

    transport.emitVisionState(visionStateFramesFlowing);
    await _settle();
    expect(c.visionNotice, isNull);

    await c.stop();
  });
}
