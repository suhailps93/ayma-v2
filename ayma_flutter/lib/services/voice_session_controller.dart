import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'transcript_store.dart';
import 'voice_transport.dart';

/// Where a voice session is in its lifecycle (a pragmatic reduction of the
/// state machine in ARCHITECTURE.md §1.3 — the `listening`/`thinking`/`speaking`
/// sub-states are surfaced through [agentSpeaking] rather than as phases).
enum VoiceSessionPhase { idle, connecting, live, error }

/// Owns the LiveKit voice-session lifecycle for the chat screen: `POST
/// /bootstrap`, room connect, mic publish, transcript relay, teardown (§1.7
/// step 5). Voice transcript segments land in the shared [TranscriptStore]
/// through the same path as typed turns (§1.7 step 12).
///
/// Sending the recent-turns window to `/bootstrap` is Step 17.
class VoiceSessionController extends ChangeNotifier {
  VoiceSessionController({
    required TranscriptStore transcriptStore,
    this.sessionId = '',
    ApiClient? apiClient,
    VoiceTransport Function()? transportFactory,
  })  : _store = transcriptStore,
        _apiClient = apiClient,
        _transportFactory =
            transportFactory ?? (() => LiveKitVoiceTransport());

  /// Shared with the chat screen so voice + text land in one `raw_turns` doc.
  final String sessionId;
  final TranscriptStore _store;
  final ApiClient? _apiClient;

  /// Lazy so merely constructing the controller (e.g. in a widget build) never
  /// touches `FirebaseAuth.instance` — same pattern as `ChatScreen._api`.
  late final ApiClient _api = _apiClient ?? ApiClient();
  final VoiceTransport Function() _transportFactory;

  VoiceTransport? _transport;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<TranscriptSegment>? _transcriptSub;
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

  /// The controller with a session currently starting or live, if any. Used by
  /// screens outside the chat shell (e.g. the voice-preview picker) to stop a
  /// call before doing something that would talk over it.
  static VoiceSessionController? active;

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
    active = this;
    _setPhase(VoiceSessionPhase.connecting);

    try {
      debugPrint('[voice] start(): calling /bootstrap');
      final session = await _api.bootstrap(
        sessionId: sessionId,
        recentTurns: _store.wireTurns(),
      );
      debugPrint('[voice] bootstrap ok: url=${session.livekitUrl} '
          'tokenLen=${session.livekitToken.length}');
      if (session.usageCapped) {
        _fail('Out of credits — reload on your profile to use voice.');
        return;
      }
      if (session.livekitToken.isEmpty || session.livekitUrl.isEmpty) {
        _fail('The server did not return voice credentials.');
        return;
      }

      final transport = _transportFactory();
      _transport = transport;
      // Driven by the agent's authoritative state (§1.3). A barge-in flips this
      // false the instant Gemini Live's turn-detection interrupts a reply, so
      // the UI stops indicating playback immediately (§1.7 step 10).
      _speakingSub = transport.agentSpeaking.listen((speaking) {
        if (_agentSpeaking == speaking) return;
        _agentSpeaking = speaking;
        notifyListeners();
      });
      _transcriptSub = transport.transcripts.listen(_onTranscriptSegment);
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

      debugPrint('[voice] phase -> live');
      _setPhase(VoiceSessionPhase.live);
    } on ApiException catch (e) {
      debugPrint('[voice] ApiException: ${e.message}');
      await _teardown();
      _fail(e.message);
    } catch (e, st) {
      debugPrint('[voice] start() FAILED: $e\n$st');
      await _teardown();
      _fail('Could not start voice ($e).');
    }
  }

  void _onTranscriptSegment(TranscriptSegment seg) {
    final role = seg.topic == 'agent_transcript' ? TurnRole.ayma : TurnRole.user;
    _store.applyVoiceSegment(role, seg.text, isFinal: seg.isFinal);
  }

  /// Best-effort raw_turns persistence on session end (§1.7 step 8). The agent
  /// worker also persists on room disconnect; both upsert the same doc.
  void _persistSession() {
    if (sessionId.isEmpty) return;
    _api.postTurn(sessionId, _store.wireTurns()).catchError((_) {});
  }

  /// End the current voice session and return to [VoiceSessionPhase.idle].
  Future<void> stop() async {
    if (active == this) active = null;
    await _teardown();
    _persistSession();
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
    await _transcriptSub?.cancel();
    await _closedSub?.cancel();
    _speakingSub = null;
    _transcriptSub = null;
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
    if (active == this) active = null;
    unawaited(_teardown());
    super.dispose();
  }
}
