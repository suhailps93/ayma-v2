import 'dart:async';

import 'package:ayma_flutter/services/voice_transport.dart';

/// In-memory [VoiceTransport] for tests — records calls, never touches WebRTC.
class FakeVoiceTransport implements VoiceTransport {
  final agentReadyController = StreamController<bool>.broadcast();
  final agentSpeakingController = StreamController<bool>.broadcast();
  final transcriptsController = StreamController<TranscriptSegment>.broadcast();
  final toolEventsController = StreamController<ToolUsedEvent>.broadcast();
  final callEndingController = StreamController<String>.broadcast();
  final agentMuteController = StreamController<bool>.broadcast();
  final practiceCoachController = StreamController<String>.broadcast();
  final voiceStatusController = StreamController<String>.broadcast();
  final reconnectingController = StreamController<bool>.broadcast();
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

  /// The `forceRelay` flag of each [connect] call, in order — lets tests
  /// assert the ice-relay-retry's second attempt actually forced relay.
  final List<bool> connectCalls = [];
  int disconnectCalls = 0;
  int disposeCalls = 0;
  bool failConnect = false;

  /// Thrown from [connect] while set (takes precedence over nothing, after
  /// [failConnect]) — set to a real `MediaConnectException` to exercise the
  /// controller's ice-relay-retry.
  Object? connectError;
  bool failMic = false;

  @override
  Stream<bool> get agentReady => agentReadyController.stream;

  /// Emit the one-shot readiness signal (test helper).
  void markAgentReady() {
    if (!agentReadyController.isClosed) agentReadyController.add(true);
  }

  /// Emit an agent-speaking change (test helper). A `true` is also the
  /// simplest way to simulate Ayma's first genuine response, which is what
  /// flips a live call to conversation-ready (mic published, OS call surface).
  void emitAgentSpeaking(bool speaking) {
    if (!agentSpeakingController.isClosed) {
      agentSpeakingController.add(speaking);
    }
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
  Stream<ToolUsedEvent> get toolEvents => toolEventsController.stream;

  @override
  Stream<String> get callEnding => callEndingController.stream;

  /// Emit the agent's own "I'm ending this call" reason (test helper, §F3).
  void emitCallEnding(String reason) {
    if (!callEndingController.isClosed) callEndingController.add(reason);
  }

  @override
  Stream<bool> get agentMute => agentMuteController.stream;

  @override
  Stream<String> get practiceCoach => practiceCoachController.stream;

  /// Emit a practice live-coach hint to the user (test helper, hackathon B).
  void emitPracticeCoach(String hint) {
    if (!practiceCoachController.isClosed) practiceCoachController.add(hint);
  }

  @override
  Stream<String> get voiceStatus => voiceStatusController.stream;

  /// Emit an honest voice-stack status (test helper, §13.9) — e.g.
  /// `open_weights_warming` for the Modal cold start.
  void emitVoiceStatus(String state) {
    if (!voiceStatusController.isClosed) voiceStatusController.add(state);
  }

  /// Emit the agent's "I've gone quiet" / "I'm back" signal (test helper).
  void emitAgentMute(bool muted) {
    if (!agentMuteController.isClosed) agentMuteController.add(muted);
  }

  /// Every [sendAgentMuteControl] request, in order.
  final List<bool> muteControlCalls = [];
  bool failMuteControl = false;

  @override
  Future<void> sendAgentMuteControl({required bool muted}) async {
    if (failMuteControl) throw StateError('data channel closed');
    muteControlCalls.add(muted);
  }

  /// Every [sendVoiceAccentControl] request, in order (accent, language).
  final List<({String accent, String language})> accentControlCalls = [];
  bool failAccentControl = false;

  @override
  Future<void> sendVoiceAccentControl({
    required String accent,
    required String language,
  }) async {
    if (failAccentControl) throw StateError('data channel closed');
    accentControlCalls.add((accent: accent, language: language));
  }

  /// Every [sendTourTapped] request, in order (the step index).
  final List<int> tourTappedCalls = [];
  bool failTourTapped = false;

  @override
  Future<void> sendTourTapped({required int index}) async {
    if (failTourTapped) throw StateError('data channel closed');
    tourTappedCalls.add(index);
  }

  @override
  Stream<bool> get reconnecting => reconnectingController.stream;

  /// Emit a mid-call transport reconnect state change (test helper) — the
  /// SDK re-establishing a dropped connection (`true`), then resuming the
  /// same session (`false`).
  void emitReconnecting(bool reconnecting) {
    if (!reconnectingController.isClosed) {
      reconnectingController.add(reconnecting);
    }
  }

  @override
  Stream<Object> get closed => closedController.stream;

  @override
  Future<void> connect({
    required String url,
    required String token,
    bool forceRelay = false,
  }) async {
    connectCalls.add(forceRelay);
    if (failConnect) throw StateError('connect failed');
    final error = connectError;
    if (error != null) throw error;
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
    if (!agentSpeakingController.isClosed)
      await agentSpeakingController.close();
    if (!transcriptsController.isClosed) await transcriptsController.close();
    if (!toolEventsController.isClosed) await toolEventsController.close();
    if (!callEndingController.isClosed) await callEndingController.close();
    if (!agentMuteController.isClosed) await agentMuteController.close();
    if (!practiceCoachController.isClosed) {
      await practiceCoachController.close();
    }
    if (!voiceStatusController.isClosed) await voiceStatusController.close();
    if (!reconnectingController.isClosed) {
      await reconnectingController.close();
    }
    if (!closedController.isClosed) await closedController.close();
    if (!localLevelController.isClosed) await localLevelController.close();
    if (!agentLevelController.isClosed) await agentLevelController.close();
  }
}
