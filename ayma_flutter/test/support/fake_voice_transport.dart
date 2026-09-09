import 'dart:async';

import 'package:ayma_flutter/services/voice_transport.dart';

/// In-memory [VoiceTransport] for tests — records calls, never touches WebRTC.
class FakeVoiceTransport implements VoiceTransport {
  final agentReadyController = StreamController<bool>.broadcast();
  final agentSpeakingController = StreamController<bool>.broadcast();
  final transcriptsController = StreamController<TranscriptSegment>.broadcast();
  final closedController = StreamController<Object>.broadcast();
  final localLevelController = StreamController<double>.broadcast();
  final agentLevelController = StreamController<double>.broadcast();

  /// Push a mic / agent audio level (0..1) for tests.
  void emitMicLevel(double v) {
    if (!localLevelController.isClosed) localLevelController.add(v);
  }

  void emitAgentLevel(double v) {
    if (!agentLevelController.isClosed) agentLevelController.add(v);
  }

  /// When true, [connect] latches [agentReady] immediately (warm-worker path).
  bool agentReadyOnConnect = false;

  String? connectedUrl;
  String? connectedToken;
  final List<bool> micCalls = [];
  int disconnectCalls = 0;
  int disposeCalls = 0;
  bool failConnect = false;
  bool failMic = false;

  @override
  Stream<bool> get agentReady => agentReadyController.stream;

  /// Emit the one-shot readiness signal (test helper).
  void markAgentReady() {
    if (!agentReadyController.isClosed) agentReadyController.add(true);
  }

  @override
  Stream<bool> get agentSpeaking => agentSpeakingController.stream;

  @override
  Stream<double> get localAudioLevel => localLevelController.stream;

  @override
  Stream<double> get agentAudioLevel => agentLevelController.stream;

  @override
  Stream<TranscriptSegment> get transcripts => transcriptsController.stream;

  @override
  Stream<Object> get closed => closedController.stream;

  @override
  Future<void> connect({required String url, required String token}) async {
    if (failConnect) throw StateError('connect failed');
    connectedUrl = url;
    connectedToken = token;
    if (agentReadyOnConnect) markAgentReady();
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    if (failMic && enabled) throw StateError('mic permission denied');
    micCalls.add(enabled);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!agentReadyController.isClosed) await agentReadyController.close();
    if (!agentSpeakingController.isClosed) await agentSpeakingController.close();
    if (!transcriptsController.isClosed) await transcriptsController.close();
    if (!closedController.isClosed) await closedController.close();
    if (!localLevelController.isClosed) await localLevelController.close();
    if (!agentLevelController.isClosed) await agentLevelController.close();
  }
}
