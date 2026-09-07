import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'transcript_store.dart';
import 'voice_transport.dart';

/// Where a voice session is in its lifecycle (a pragmatic reduction of the
/// state machine in ARCHITECTURE.md §1.3 — the `listening`/`thinking`/`speaking`
/// sub-states are surfaced through [agentSpeaking] rather than as phases).
enum VoiceSessionPhase { idle, connecting, waking, live, error }

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
    this.welcome = false,
    ApiClient? apiClient,
    VoiceTransport Function()? transportFactory,
    Duration? wakingTimeout,
  })  : _store = transcriptStore,
        _apiClient = apiClient,
        _wakingTimeout = wakingTimeout ?? const Duration(seconds: 25),
        _transportFactory =
            transportFactory ?? (() => LiveKitVoiceTransport());

  /// The pre-sign-in greeting session — connects via `POST /welcome/token`
  /// (no account) instead of `POST /bootstrap`.
  final bool welcome;

  /// Shared with the chat screen so voice + text land in one `raw_turns` doc.
  final String sessionId;
  final TranscriptStore _store;
  final ApiClient? _apiClient;

  /// Lazy so merely constructing the controller (e.g. in a widget build) never
  /// touches `FirebaseAuth.instance` — same pattern as `ChatScreen._api`.
  late final ApiClient _api = _apiClient ?? ApiClient();
  final VoiceTransport Function() _transportFactory;

  /// How long to wait in [VoiceSessionPhase.waking] for the agent to join
  /// before giving up. The `ayma-agent` worker is scale-to-zero, so a cold
  /// start can take 5–20s; 25s leaves headroom without stranding the caller.
  final Duration _wakingTimeout;

  VoiceTransport? _transport;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<bool>? _readySub;
  StreamSubscription<TranscriptSegment>? _transcriptSub;
  StreamSubscription<Object>? _closedSub;
  Timer? _wakingTimer;

  /// Set the moment [VoiceTransport.agentReady] fires — even if that's before
  /// we've entered `waking` (a warm worker already in the room emits during
  /// `connect()`). Checked when `waking` is entered so the signal is never lost.
  bool _agentReadySeen = false;

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  VoiceSessionPhase get phase => _phase;

  bool _agentSpeaking = false;
  bool get agentSpeaking => _agentSpeaking;

  bool _muted = false;
  bool get muted => _muted;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool get isActive =>
      _phase == VoiceSessionPhase.connecting ||
      _phase == VoiceSessionPhase.waking ||
      _phase == VoiceSessionPhase.live;

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
    _agentReadySeen = false;
    _muted = false;
    active = this;
    _setPhase(VoiceSessionPhase.connecting);

    try {
      final String url;
      final String token;
      if (welcome) {
        debugPrint('[voice] start(): calling /welcome/token');
        final w = await _api.welcomeToken();
        url = w.url;
        token = w.token;
      } else {
        debugPrint('[voice] start(): calling /bootstrap');
        final session = await _api.bootstrap(
          sessionId: sessionId,
          recentTurns: _store.wireTurns(),
        );
        if (session.usageCapped) {
          _fail('Out of credits — reload on your profile to use voice.');
          return;
        }
        url = session.livekitUrl;
        token = session.livekitToken;
      }
      debugPrint('[voice] token ok: url=$url tokenLen=${token.length}');
      if (token.isEmpty || url.isEmpty) {
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
      _readySub = transport.agentReady.listen((_) => _onAgentReady());
      _transcriptSub = transport.transcripts.listen(_onTranscriptSegment);
      _closedSub = transport.closed.listen((_) {
        unawaited(_teardown());
        _fail('The voice connection dropped.');
      });

      await transport.connect(url: url, token: token);

      try {
        await transport.setMicrophoneEnabled(true);
      } catch (e) {
        await _teardown();
        _fail('Ayma needs microphone access for voice.');
        return;
      }

      // The room is connected and our mic is publishing, but the agent
      // (scale-to-zero worker) may still be cold-starting. Hold `waking` — NOT
      // `live` — until `agentReady` fires so the UI never claims "Listening"
      // while nothing is there to hear the caller (§1.7).
      debugPrint('[voice] phase -> waking');
      _setPhase(VoiceSessionPhase.waking);
      if (_agentReadySeen) {
        // Warm worker: `agentReady` already fired during connect().
        _onAgentReady();
      } else {
        _wakingTimer = Timer(_wakingTimeout, _onWakingTimeout);
      }
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

  /// The agent has joined the room and is audible — promote `waking` -> `live`.
  /// May be invoked before `waking` is entered (warm worker); [_agentReadySeen]
  /// carries the signal forward so `start()` can act on it.
  void _onAgentReady() {
    _agentReadySeen = true;
    _wakingTimer?.cancel();
    _wakingTimer = null;
    if (_phase != VoiceSessionPhase.waking) return;
    debugPrint('[voice] phase -> live (agent ready)');
    _setPhase(VoiceSessionPhase.live);
  }

  /// The agent never joined within [_wakingTimeout] — tear down and surface a
  /// clear error instead of a silent dead "Listening".
  void _onWakingTimeout() {
    _wakingTimer = null;
    if (_phase != VoiceSessionPhase.waking) return;
    debugPrint('[voice] waking timed out — agent never joined');
    unawaited(_teardown());
    _fail("Ayma didn't pick up — try again in a moment.");
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
    _wakingTimer?.cancel();
    _wakingTimer = null;
    await _speakingSub?.cancel();
    await _readySub?.cancel();
    await _transcriptSub?.cancel();
    await _closedSub?.cancel();
    _speakingSub = null;
    _readySub = null;
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
