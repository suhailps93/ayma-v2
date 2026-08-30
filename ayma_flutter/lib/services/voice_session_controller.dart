import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'voice_transport.dart';

/// Where a voice session is in its lifecycle (a pragmatic reduction of the
/// state machine in ARCHITECTURE.md §1.3 — the `listening`/`thinking`/`speaking`
/// sub-states are surfaced through [agentSpeaking] rather than as phases).
enum VoiceSessionPhase { idle, connecting, live, error }

/// Owns the LiveKit voice-session lifecycle for the chat screen: mic permission,
/// `POST /bootstrap`, room connect, mic publish, teardown (§1.7 step 5).
///
/// Step 14 scope: a working voice round-trip. Feeding turns into the unified
/// [TranscriptStore] is Step 16; sending the recent-turns window to `/bootstrap`
/// is Step 17.
class VoiceSessionController extends ChangeNotifier {
  VoiceSessionController({
    ApiClient? apiClient,
    VoiceTransport Function()? transportFactory,
  })  : _apiClient = apiClient,
        _transportFactory =
            transportFactory ?? (() => LiveKitVoiceTransport());

  final ApiClient? _apiClient;

  /// Lazy so merely constructing the controller (e.g. in a widget build) never
  /// touches `FirebaseAuth.instance` — same pattern as `ChatScreen._api`.
  late final ApiClient _api = _apiClient ?? ApiClient();
  final VoiceTransport Function() _transportFactory;

  VoiceTransport? _transport;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<Object>? _closedSub;

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  VoiceSessionPhase get phase => _phase;

  bool _agentSpeaking = false;
  bool get agentSpeaking => _agentSpeaking;

  bool _muted = false;
  bool get muted => _muted;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool get isActive =>
      _phase == VoiceSessionPhase.connecting || _phase == VoiceSessionPhase.live;

  /// Begin a voice session. Safe to call when already active (no-op).
  ///
  /// The OS microphone prompt is raised by the WebRTC layer the first time
  /// [VoiceTransport.setMicrophoneEnabled] is called; a denied permission
  /// surfaces there as a thrown error and lands the session in
  /// [VoiceSessionPhase.error].
  Future<void> start() async {
    if (isActive) return;
    _errorMessage = null;
    _agentSpeaking = false;
    _muted = false;
    _setPhase(VoiceSessionPhase.connecting);

    try {
      final session = await _api.bootstrap();
      if (session.livekitToken.isEmpty || session.livekitUrl.isEmpty) {
        _fail('The server did not return voice credentials.');
        return;
      }

      final transport = _transportFactory();
      _transport = transport;
      _speakingSub = transport.agentSpeaking.listen((speaking) {
        _agentSpeaking = speaking;
        notifyListeners();
      });
      _closedSub = transport.closed.listen((_) {
        unawaited(_teardown());
        _fail('The voice connection dropped.');
      });

      await transport.connect(
        url: session.livekitUrl,
        token: session.livekitToken,
      );

      try {
        await transport.setMicrophoneEnabled(true);
      } catch (e) {
        await _teardown();
        _fail('Ayma needs microphone access for voice.');
        return;
      }

      _setPhase(VoiceSessionPhase.live);
    } on ApiException catch (e) {
      await _teardown();
      _fail(e.message);
    } catch (e) {
      await _teardown();
      _fail('Could not start voice ($e).');
    }
  }

  /// End the current voice session and return to [VoiceSessionPhase.idle].
  Future<void> stop() async {
    await _teardown();
    _agentSpeaking = false;
    _muted = false;
    if (_phase != VoiceSessionPhase.error) {
      _setPhase(VoiceSessionPhase.idle);
    } else {
      notifyListeners();
    }
  }

  Future<void> toggleMute() async {
    if (_phase != VoiceSessionPhase.live || _transport == null) return;
    _muted = !_muted;
    notifyListeners();
    try {
      await _transport!.setMicrophoneEnabled(!_muted);
    } catch (_) {
      _muted = !_muted; // revert on failure
      notifyListeners();
    }
  }

  void _setPhase(VoiceSessionPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    _setPhase(VoiceSessionPhase.error);
  }

  Future<void> _teardown() async {
    await _speakingSub?.cancel();
    await _closedSub?.cancel();
    _speakingSub = null;
    _closedSub = null;
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.disconnect();
      } finally {
        await transport.dispose();
      }
    }
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
