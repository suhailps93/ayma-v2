import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api_client.dart';
import 'app_command_service.dart';
import 'app_context.dart';
import 'call_permissions.dart';
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
    this._apiClient,
    VoiceTransport Function()? transportFactory,
    Duration? wakingTimeout,
    AppCommandService? appCommandService,
    CallPermissions? callPermissions,
  })  : _store = transcriptStore,
        _wakingTimeout = wakingTimeout ?? const Duration(seconds: 45),
        _transportFactory =
            transportFactory ?? (() => LiveKitVoiceTransport()),
        _commands = appCommandService ?? AppCommandService(),
        _permissions = callPermissions ?? CallPermissions();

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

  /// Requests whatever a call needs up front (Android's POST_NOTIFICATIONS,
  /// for the background call notification — F4/item 3), rather than
  /// discovering a missing permission only once the app is backgrounded.
  final CallPermissions _permissions;

  /// How long to wait in [VoiceSessionPhase.waking] for the agent to join
  /// before giving up. `ayma-agent` is permanently scale-to-zero (2026-09-19
  /// founder decision — accept a cold-start wait over paying to keep it
  /// warm 24/7; `agent_wake.py` fires the actual Cloud Run start the moment
  /// a call begins). A real measured cold start: Cloud Run's own "STARTUP
  /// TCP probe succeeded" log landed ~22s after the wake ping in production
  /// — and that's before the worker has even registered with LiveKit,
  /// received the job dispatch, and joined the room on top. 45s leaves
  /// real headroom for that whole chain instead of the old, never-measured
  /// "5–20s" guess this was previously set from.
  final Duration _wakingTimeout;

  VoiceTransport? _transport;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<bool>? _readySub;
  StreamSubscription<TranscriptSegment>? _transcriptSub;
  StreamSubscription<ToolUsedEvent>? _toolEventsSub;
  StreamSubscription<String>? _callEndingSub;
  StreamSubscription<Object>? _closedSub;
  StreamSubscription<double>? _micLevelSub;
  StreamSubscription<double>? _aymaLevelSub;
  Timer? _wakingTimer;

  /// Settled ("Researched them online") labels of tool calls Ayma has made
  /// since the last finalized ayma turn — attached to the *next* finalized
  /// `agent_transcript` as [TranscriptTurn.tools] (§1.7 step 3), the voice
  /// equivalent of the text chat's status -> reply kicker. Cleared once
  /// attached, and discarded (not carried forward) on a new user turn or
  /// session teardown so a tool call that never resolves into a reply can't
  /// leak its label into a later, unrelated turn.
  final List<String> _pendingToolLabels = [];

  /// The live, present-progressive label of whichever tool is running right
  /// now ("Researching them online…"), or null when none is — a transient
  /// indicator for a slow tool call, distinct from [_pendingToolLabels]
  /// (which is what's shown once the reply lands).
  String? _activeToolLabel;
  String? get activeToolLabel => _activeToolLabel;

  /// Smoothed 0..1 audio levels for the voice-mode composer waveform:
  /// [micLevel] is the user's mic input, [aymaLevel] is Ayma's output audio.
  final ValueNotifier<double> micLevel = ValueNotifier(0);
  final ValueNotifier<double> aymaLevel = ValueNotifier(0);

  static double _smooth(double prev, double next) =>
      (prev * 0.6 + next.clamp(0.0, 1.0) * 0.4);

  /// Screen-context mirror + Ayma-driven navigation, both live only while a
  /// call is (§5.6). [_commands] watches for nav commands; [_mirrorContext]
  /// pushes what the user is looking at to the backend, debounced.
  final AppCommandService _commands;
  bool _mirroring = false;
  VoidCallback? _ctxListener;
  Timer? _ctxDebounce;
  Timer? _ctxRetry;
  Timer? _ctxHeartbeat;
  AppLifecycleListener? _lifecycle;

  /// The screen mirror is only re-pushed on change, so a long call sitting on
  /// one screen would let the backend doc age past its staleness window and
  /// `current_screen` would start coming up blank. Re-push on this cadence to
  /// keep it answerable for the whole call.
  static const _ctxHeartbeatInterval = Duration(seconds: 45);

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

  /// True when [_errorMessage] is specifically "you're out of credits", as
  /// opposed to a mic-permission denial, a dropped connection, or the agent
  /// never picking up. Lets the UI show the same actionable reload affordance
  /// chat already has instead of a plain error line for this one case (§F3).
  bool _cappedError = false;
  bool get cappedError => _cappedError;

  /// True when [_errorMessage] is specifically "the call had to end because
  /// the background call notification couldn't be shown" (Android's
  /// POST_NOTIFICATIONS was denied) — as opposed to any other error. Lets the
  /// UI offer a settings deep-link instead of a plain error line (§ ask
  /// item 3: explain + a way to grant it, not a silent failure).
  bool _backgroundPermissionDenied = false;
  bool get backgroundPermissionDenied => _backgroundPermissionDenied;

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
    _cappedError = false;
    _backgroundPermissionDenied = false;
    _agentSpeaking = false;
    _agentReadySeen = false;
    _muted = false;
    _pendingToolLabels.clear();
    _activeToolLabel = null;
    active = this;
    _setPhase(VoiceSessionPhase.connecting);
    // Best-effort and fire-before-connect: ask for whatever the call will
    // need in the background while the user still has full context for the
    // OS prompt, so it's (hopefully) already settled by the time backgrounding
    // actually needs it. Never blocks or fails the call — a foreground call
    // never needed this permission in the first place.
    unawaited(_permissions.ensureCallStartPermissions());

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
          _cappedError = true;
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
      _micLevelSub = transport.localAudioLevel.listen(
        (v) => micLevel.value = _smooth(micLevel.value, v),
      );
      _aymaLevelSub = transport.agentAudioLevel.listen(
        (v) => aymaLevel.value = _smooth(aymaLevel.value, v),
      );
      _transcriptSub = transport.transcripts.listen(_onTranscriptSegment);
      _toolEventsSub = transport.toolEvents.listen(_onToolEvent);
      // Fires (if at all) shortly before `closed` for the same disconnect —
      // §F3: the agent itself ending the call (currently only on hitting the
      // mid-call credit cap) rather than a dropped connection, so the UI can
      // show the actionable "reload credits" affordance instead of a generic
      // error. Sets `_cappedError`/`_errorMessage` first so the `closed`
      // handler below doesn't clobber it with the generic message.
      _callEndingSub = transport.callEnding.listen(_onCallEnding);
      _closedSub = transport.closed.listen((_) {
        unawaited(_teardown());
        if (_cappedError) return;
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
    if (role == TurnRole.user && seg.isFinal) {
      // A new user turn starts a new "what did Ayma do to answer it" window
      // — drop any stray labels left over from a tool call that never
      // resolved into a finalized ayma turn (e.g. the agent was interrupted)
      // rather than letting them leak into a much later reply.
      _pendingToolLabels.clear();
    }
    final tools = (role == TurnRole.ayma && seg.isFinal)
        ? _flushPendingToolLabels()
        : const <String>[];
    _store.applyVoiceSegment(role, seg.text, isFinal: seg.isFinal, tools: tools);
  }

  /// A tool call starting or finishing mid-call (§1.7 step 3) — mirrors text
  /// chat's status -> reply pattern. "start" drives the transient
  /// [activeToolLabel] indicator; "end" queues the settled label onto
  /// [_pendingToolLabels] for the next finalized ayma turn.
  void _onToolEvent(ToolUsedEvent e) {
    if (e.isStart) {
      _activeToolLabel = e.label;
      notifyListeners();
      return;
    }
    _activeToolLabel = null;
    if (e.label.isNotEmpty && !_pendingToolLabels.contains(e.label)) {
      _pendingToolLabels.add(e.label);
    }
    notifyListeners();
  }

  List<String> _flushPendingToolLabels() {
    if (_pendingToolLabels.isEmpty) return const [];
    final labels = List<String>.unmodifiable(_pendingToolLabels);
    _pendingToolLabels.clear();
    return labels;
  }

  /// The agent deliberately ended the call itself (§F3) — currently only
  /// `out_of_credits`, once mid-call usage crosses the user's balance to
  /// zero. Surfaces via the exact same `cappedError` + [OutOfCreditsBanner] /
  /// [showOutOfCreditsSnack] affordance the pre-call `usageCapped` check
  /// above already uses, rather than a new one-off path.
  void _onCallEnding(String reason) {
    if (reason != 'out_of_credits') return;
    _cappedError = true;
    _fail('Out of credits — Ayma had to end the call. Reload on your '
        'profile to keep going.');
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

  /// Clears a stale out-of-credits error left over from a previous failed
  /// [start()]. [stop()] deliberately leaves [VoiceSessionPhase.error] in
  /// place so the user sees why a call just ended, but nothing was ever
  /// clearing it afterwards — so once someone topped back up, the "Out of
  /// credits" banner kept showing at the top of chat forever, since it's
  /// only ever re-checked (and reset) inside the next [start()] call, which
  /// nothing prompts the user to retry. Call this right after a successful
  /// credit top-up (see `UsageScreen._reload`) so the banner actually goes
  /// away once the reason for it is gone, instead of only after the user
  /// happens to try voice again.
  void clearCappedError() {
    if (_phase == VoiceSessionPhase.error && _cappedError) {
      _cappedError = false;
      _errorMessage = null;
      _setPhase(VoiceSessionPhase.idle);
    }
  }

  /// Called by [CallBackgroundService] right after it has had to stop a
  /// backgrounded call because the OS call surface couldn't be shown
  /// (Android: `POST_NOTIFICATIONS` denied) — surfaces as the normal error
  /// banner plus [backgroundPermissionDenied], so the UI can add a settings
  /// deep-link instead of leaving the user with only "the call ended".
  void reportBackgroundBlocked() {
    _backgroundPermissionDenied = true;
    _fail("Ayma needs notification access to keep a call going in the "
        'background — turn it on in Settings, then try again.');
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
    if (phase == VoiceSessionPhase.live) _startScreenAwareness();
    // Voice is hands-free by design — without this the OS screen-off timeout
    // fires mid-call (no touch input) and cuts the screen while the call
    // itself is still live. Covers connecting/waking/live; _teardown() always
    // disables it again on every exit path.
    if (isActive) {
      unawaited(WakelockPlus.enable().catchError(
          (e) => debugPrint('[voice] wakelock enable failed: $e')));
    }
    notifyListeners();
  }

  /// Call is live: start watching for Ayma's navigation commands and start
  /// mirroring what the user is looking at. All best-effort — a failure here
  /// never touches the call.
  void _startScreenAwareness() {
    if (_mirroring) return;
    _mirroring = true;
    _commands.start();
    _pushContext();
    // The screen may be set a beat after the call goes live (a route still
    // settling). If we pushed nothing, try once more shortly.
    _ctxRetry = Timer(const Duration(seconds: 1), () {
      if (_mirroring && AppContext.instance.current.value.screen.isEmpty) {
        _pushContext();
      }
    });
    _ctxListener = () {
      _ctxDebounce?.cancel();
      _ctxDebounce = Timer(const Duration(milliseconds: 500), _pushContext);
    };
    AppContext.instance.current.addListener(_ctxListener!);
    _ctxHeartbeat =
        Timer.periodic(_ctxHeartbeatInterval, (_) => _pushContext());
    // Returning from the background can leave the doc stale — re-push at once.
    try {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          if (_mirroring) _pushContext();
        },
      );
    } catch (e) {
      // No widgets binding (e.g. a unit test) — the heartbeat still covers it.
      debugPrint('[voice] AppLifecycleListener unavailable: $e');
    }
  }

  void _pushContext() {
    _api.setVoiceContext(AppContext.instance.current.value.toJson()).catchError(
        (e) => debugPrint('[voice] setVoiceContext failed: $e'));
  }

  Future<void> _stopScreenAwareness() async {
    if (!_mirroring) return;
    _mirroring = false;
    _ctxDebounce?.cancel();
    _ctxDebounce = null;
    _ctxRetry?.cancel();
    _ctxRetry = null;
    _ctxHeartbeat?.cancel();
    _ctxHeartbeat = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    if (_ctxListener != null) {
      AppContext.instance.current.removeListener(_ctxListener!);
      _ctxListener = null;
    }
    await _commands.stop();
    _api.clearVoiceContext().catchError(
        (e) => debugPrint('[voice] clearVoiceContext failed: $e'));
  }

  void _fail(String message) {
    _errorMessage = message;
    _setPhase(VoiceSessionPhase.error);
  }

  Future<void> _teardown() async {
    _wakingTimer?.cancel();
    _wakingTimer = null;

    // Snapshot every session-scoped handle (subscriptions + transport) and
    // null the instance fields *synchronously*, before the first `await`
    // below — never interleaved with one. Root cause this closes ("multiple
    // voice crashes in a row" + stray transcript segments bleeding into the
    // shared `TranscriptStore`, founder report 2026-09-26): both failure
    // paths that call this — `_onWakingTimeout()` and the `transport.closed`
    // listener in `start()` — fire `unawaited(_teardown())` and then call
    // `_fail()` *synchronously right after*, which flips `_phase` out of
    // "active" and lets a fast user retry (or an auto-retry) invoke `start()`
    // again while this coroutine is still mid-flight. The old version read
    // `_speakingSub`/`_transcriptSub`/etc. — and worst of all `_transport` —
    // *after* several `await`s, by which point a concurrent `start()` had
    // already overwritten those very fields with the NEW session's handles:
    // this coroutine would then cancel the new session's subscriptions
    // instead of the dead one's (silently killing its transcript relay, so
    // voice turns it actually heard never reach `TranscriptStore` — the
    // concrete mechanism behind a later text `/chat` turn missing context
    // that was just discussed by voice moments earlier), and — the sharpest
    // symptom — call `transport.disconnect()`/`.dispose()` on the BRAND-NEW,
    // still-connecting transport, tearing down the retry out from under
    // itself and producing exactly the repeated
    // "MediaConnectException: Timed out waiting for PeerConnection" pattern.
    // Capturing everything up front (dispose()'s own pre-cancel already
    // leans on the same fix shape below it, for the same reason) means a
    // `start()` racing this sees clean null fields immediately and builds an
    // entirely independent session, while this coroutine only ever
    // cancels/disposes the handles it captured — never a newer session's.
    final speakingSub = _speakingSub;
    final readySub = _readySub;
    final transcriptSub = _transcriptSub;
    final toolEventsSub = _toolEventsSub;
    final callEndingSub = _callEndingSub;
    final closedSub = _closedSub;
    final micLevelSub = _micLevelSub;
    final aymaLevelSub = _aymaLevelSub;
    final transport = _transport;
    _speakingSub = null;
    _readySub = null;
    _transcriptSub = null;
    _toolEventsSub = null;
    _callEndingSub = null;
    _closedSub = null;
    _micLevelSub = null;
    _aymaLevelSub = null;
    _transport = null;

    unawaited(WakelockPlus.disable().catchError(
        (e) => debugPrint('[voice] wakelock disable failed: $e')));
    await _stopScreenAwareness();
    await speakingSub?.cancel();
    await readySub?.cancel();
    await transcriptSub?.cancel();
    await toolEventsSub?.cancel();
    await callEndingSub?.cancel();
    await closedSub?.cancel();
    await micLevelSub?.cancel();
    await aymaLevelSub?.cancel();
    micLevel.value = 0;
    aymaLevel.value = 0;
    // A session's tool-call bookkeeping never survives it — the next call
    // starts clean (also reset at the top of start(), belt and braces).
    _pendingToolLabels.clear();
    _activeToolLabel = null;
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
    // Cancel every listener subscription synchronously — i.e. the `.cancel()`
    // calls themselves, not their returned futures — *before* `super.dispose()`
    // marks this ChangeNotifier disposed below. `_teardown()`'s own
    // cancellation is async and unawaited here, leaving a brief gap (each
    // `await` inside it yields back to the event loop) where an
    // already-queued stream event — agentSpeaking, agentReady, a transcript
    // segment, the room closing — could still reach a listener closure that
    // calls `notifyListeners()` after disposal. That's a silent no-op in a
    // release build (the disposed-check is a stripped `assert`), but throws
    // `A ChangeNotifier was used after being disposed` in debug/profile — a
    // real, avoidable crash surface on every non-shared [VoiceSessionController]
    // instance (`showAskAymaOverlay`'s push-to-talk controller; a standalone
    // `ChatScreen`'s default one) each time its owning widget is torn down
    // mid-call. `.cancel()` stops further delivery immediately, so calling it
    // here (redundant with `_teardown()`'s own, already-null-safe cancel) is
    // enough to close the gap without restructuring `_teardown()` itself.
    _speakingSub?.cancel();
    _readySub?.cancel();
    _transcriptSub?.cancel();
    _toolEventsSub?.cancel();
    _closedSub?.cancel();
    _micLevelSub?.cancel();
    _aymaLevelSub?.cancel();
    unawaited(_teardown());
    super.dispose();
  }
}
