import 'dart:convert';
import 'dart:io';

import 'package:ayma_flutter/screens/voice_call_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/async_voice_controller.dart';
import 'package:ayma_flutter/services/async_voice_recorder.dart';
import 'package:ayma_flutter/services/call_permissions.dart';
import 'package:ayma_flutter/services/dm_voice_engine.dart';
import 'package:ayma_flutter/services/mic_yield_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_voice_transport.dart';

class _FakePermissionGateway implements PermissionGateway {
  @override
  Future<bool> isNotificationGranted() async => true;
  @override
  Future<bool> requestNotification() async => true;
  @override
  Future<bool> openAppSettings() async => true;
}

class _FakeRecorder implements AsyncVoiceRecorder {
  bool recording = false;
  bool cancelled = false;
  int stopCalls = 0;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> start(String path) async {
    recording = true;
    cancelled = false;
  }

  @override
  Future<RecordedClip?> stop() async {
    stopCalls++;
    recording = false;
    return const RecordedClip(path: '/tmp/test.wav', sizeBytes: 2048);
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    recording = false;
  }

  @override
  Future<void> discard(String path) async {}

  @override
  void dispose() {}
}

ApiClient _createApiClient() {
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

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _driveToConversing(
    VoiceSessionController c, FakeVoiceTransport t) async {
  await c.start();
  t.markAgentReady();
  await Future<void>.delayed(Duration.zero);
  t.emitAgentSpeaking(true);
  t.emitAgentSpeaking(false);
  await _settle();
}

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _fakePhase = VoiceSessionPhase.idle;
  final bool _fakeSpeaking = false;
  bool _fakeMuted = false;
  bool _fakeResponded = false;
  int toggleMuteCalls = 0;

  @override
  VoiceSessionPhase get phase => _fakePhase;

  @override
  bool get agentSpeaking => _fakeSpeaking;

  @override
  bool get muted => _fakeMuted;

  @override
  bool get isListening => _fakePhase == VoiceSessionPhase.live;

  @override
  bool get awaitingFirstResponse =>
      _fakePhase == VoiceSessionPhase.live && !_fakeResponded;

  @override
  bool get isConversationReady =>
      _fakePhase == VoiceSessionPhase.live && _fakeResponded;

  void setPhase(VoiceSessionPhase phase) {
    _fakePhase = phase;
    notifyListeners();
  }

  void setResponded() {
    _fakeResponded = true;
    notifyListeners();
  }

  @override
  Future<void> toggleMute() async {
    toggleMuteCalls++;
    if (micYielded) {
      await unyieldMic();
      return;
    }
    _fakeMuted = !_fakeMuted;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MicYieldService', () {
    test('dispatches native onMicYielded to registered handlers', () async {
      final channelCalls = <MethodCall>[];
      const channel = MethodChannel('test/mic_yield');
      final service = MicYieldService(
        channel: channel,
        debugSupportedOverride: true,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        channelCalls.add(call);
        return null;
      });

      String? receivedReason;
      void handler(String reason) {
        receivedReason = reason;
      }

      service.addHandler(handler);

      await service.startMonitoring();
      expect(channelCalls.length, 1);
      expect(channelCalls.first.method, 'startMonitoring');

      // Native delivers onMicYielded
      await service.debugHandleMethodCall(
        const MethodCall('onMicYielded', {'reason': 'audio_focus_loss'}),
      );

      expect(receivedReason, 'audio_focus_loss');
      expect(service.activeMonitors, 0);

      service.removeHandler(handler);
      service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('ref-counts startMonitoring and stopMonitoring', () async {
      final channelCalls = <MethodCall>[];
      const channel = MethodChannel('test/mic_yield_ref');
      final service = MicYieldService(
        channel: channel,
        debugSupportedOverride: true,
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        channelCalls.add(call);
        return null;
      });

      await service.startMonitoring();
      await service.startMonitoring();
      expect(channelCalls.length, 1);
      expect(service.activeMonitors, 2);

      await service.stopMonitoring();
      expect(channelCalls.length, 1); // Not stopped yet
      expect(service.activeMonitors, 1);

      await service.stopMonitoring();
      expect(channelCalls.length, 2);
      expect(channelCalls.last.method, 'stopMonitoring');
      expect(service.activeMonitors, 0);

      service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  group('VoiceSessionController mic yield', () {
    tearDown(() {
      VoiceSessionController.active = null;
    });

    test('yieldMic unpublishes local mic track and marks micYielded', () async {
      final transport = FakeVoiceTransport();
      final micYieldService = MicYieldService(debugSupportedOverride: false);
      final voice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _createApiClient(),
        transportFactory: () => transport,
        callPermissions: CallPermissions(gateway: _FakePermissionGateway()),
        micYieldService: micYieldService,
      );

      await _driveToConversing(voice, transport);
      expect(voice.isConversationReady, isTrue);
      expect(transport.micCalls.last, isTrue);
      expect(voice.micYielded, isFalse);

      // Yield event arrives
      await micYieldService.notifyYielded('audio_focus_loss');
      await _settle();

      expect(voice.micYielded, isTrue);
      expect(voice.micYieldReason, 'audio_focus_loss');
      expect(transport.micCalls.last, isFalse);

      // User reclaims the mic via unyieldMic
      await voice.unyieldMic();
      await _settle();

      expect(voice.micYielded, isFalse);
      expect(transport.micCalls.last, isTrue);

      await voice.stop();
      expect(voice.micYielded, isFalse);
      voice.dispose();
    });

    test('toggleMute unyields when mic is yielded', () async {
      final transport = FakeVoiceTransport();
      final micYieldService = MicYieldService(debugSupportedOverride: false);
      final voice = VoiceSessionController(
        transcriptStore: TranscriptStore(),
        apiClient: _createApiClient(),
        transportFactory: () => transport,
        callPermissions: CallPermissions(gateway: _FakePermissionGateway()),
        micYieldService: micYieldService,
      );

      await _driveToConversing(voice, transport);
      expect(transport.micCalls.last, isTrue);

      await voice.yieldMic('recording_silenced');
      expect(voice.micYielded, isTrue);
      expect(transport.micCalls.last, isFalse);

      // Tapping mute button reclaims mic
      await voice.toggleMute();
      expect(voice.micYielded, isFalse);
      expect(voice.muted, isFalse);
      expect(transport.micCalls.last, isTrue);

      await voice.stop();
      voice.dispose();
    });
  });

  group('Voice note / dictation mic yield', () {
    test('AsyncVoiceController cancels recording when mic yields', () async {
      final recorder = _FakeRecorder();
      final micYieldService = MicYieldService(debugSupportedOverride: false);
      final controller = AsyncVoiceController(
        recorder: recorder,
        micYieldService: micYieldService,
      );

      final started = await controller.startRecording();
      expect(started, isTrue);
      expect(controller.isRecording, isTrue);
      expect(recorder.recording, isTrue);

      // Yield event arrives
      await micYieldService.notifyYielded('audio_focus_loss');
      await _settle();

      expect(controller.isRecording, isFalse);
      expect(recorder.cancelled, isTrue);
      expect(controller.takeError(), 'Microphone yielded to another app.');

      controller.dispose();
    });

    test('DmVoiceNoteEngine cancels recording when mic yields', () async {
      final recorder = _FakeRecorder();
      final micYieldService = MicYieldService(debugSupportedOverride: false);
      File? sentFile;
      final engine = DmVoiceNoteEngine(
        recorder: recorder,
        onSendClip: (file) async => sentFile = file,
        micYieldService: micYieldService,
      );

      final started = await engine.startRecording();
      expect(started, isTrue);
      expect(engine.isRecording, isTrue);
      expect(recorder.recording, isTrue);

      // Yield event arrives
      await micYieldService.notifyYielded('recording_silenced');
      await _settle();

      expect(engine.isRecording, isFalse);
      expect(recorder.cancelled, isTrue);
      expect(sentFile, isNull);
      expect(engine.takeError(), 'Microphone yielded to another app.');

      engine.dispose();
    });
  });

  group('UI reflection of mic yield', () {
    testWidgets('VoiceCallScreen reflects "Mic yielded" and mute button state',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice()
        ..setPhase(VoiceSessionPhase.live)
        ..setResponded();

      await tester.pumpWidget(
        MaterialApp(
          home: VoiceCallScreen(voice: voice),
        ),
      );
      await tester.pump();

      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

      // Yield mic
      await voice.yieldMic('audio_focus_loss');
      await tester.pump();

      expect(voice.micYielded, isTrue);
      expect(find.text('Mic yielded'), findsOneWidget);
      expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);

      // Tapping mute button unyields
      await tester.tap(find.byKey(const Key('voiceCallMuteButton')));
      await tester.pump();

      expect(voice.micYielded, isFalse);
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    });
  });
}
