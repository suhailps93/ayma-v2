import 'dart:async';

import 'package:ayma_flutter/services/voice_transport.dart';

/// In-memory [VoiceTransport] for tests — records calls, never touches WebRTC.
class FakeVoiceTransport implements VoiceTransport {
  final agentSpeakingController = StreamController<bool>.broadcast();
  final transcriptsController = StreamController<TranscriptSegment>.broadcast();
  final closedController = StreamController<Object>.broadcast();

  String? connectedUrl;
  String? connectedToken;
  final List<bool> micCalls = [];
  int disconnectCalls = 0;
  int disposeCalls = 0;
  bool failConnect = false;
  bool failMic = false;

  @override
  Stream<bool> get agentSpeaking => agentSpeakingController.stream;

  @override
  Stream<TranscriptSegment> get transcripts => transcriptsController.stream;

  @override
  Stream<Object> get closed => closedController.stream;

  @override
  Future<void> connect({required String url, required String token}) async {
    if (failConnect) throw StateError('connect failed');
    connectedUrl = url;
    connectedToken = token;
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
    if (!agentSpeakingController.isClosed) await agentSpeakingController.close();
    if (!transcriptsController.isClosed) await transcriptsController.close();
    if (!closedController.isClosed) await closedController.close();
  }
}
