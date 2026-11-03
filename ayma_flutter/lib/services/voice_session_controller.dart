import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../features/practice_date/practice_models.dart';
import 'api_client.dart';
import 'app_command_service.dart';
import 'app_context.dart';
import 'screen_capture.dart';
import 'call_permissions.dart';
import 'error_reporting.dart';
import 'transcript_store.dart';
import 'voice_transport.dart';

/// Where a voice session is in its lifecycle (a pragmatic reduction of the
/// state machine in ARCHITECTURE.md §1.3 — the `listening`/`thinking`/`speaking`
/// sub-states are surfaced through [agentSpeaking] rather than as phases).
enum VoiceSessionPhase { idle, connecting, waking, live, error }

/// A voice start that failed without an exception of its own (the agent never
/// joined, the server returned no credentials) — what gets reported.
class VoiceStartError implements Exception {
  const VoiceStartError(this.message);

  final String message;

  @override
  String toString() => 'VoiceStartError: $message';
}

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
    this.practiceOtherUid,
    this._apiClient,
    VoiceTransport Function()? transportFactory,
    Duration? wakingTimeout,
    AppCommandService? appCommandService,
    CallPermissions? callPermissions,
    Duration? idleGuardTimeout,
    Duration? responseGuardTimeout,
    Duration? openWeightsResponseGuardTimeout,
    ErrorReporter? errorReporter,
  })  : _store = transcriptStore,
        _reporter = errorReporter ?? ErrorReporter.instance,
        _idleGuardTimeout = idleGuardTimeout ?? const Duration(minutes: 4),
        _responseGuardTimeout =
            responseGuardTimeout ?? const Duration(seconds: 20),
        _openWeightsResponseBudget =
            openWeightsResponseGuardTimeout ?? const Duration(seconds: 150),
        _wakingTimeout = wakingTimeout ?? const Duration(seconds: 45),
        _transportFactory =
            transportFactory ?? (() => LiveKitVoiceTransport()),
        _commands = appCommandService ?? AppCommandService.shared,
        _permissions = callPermissions ?? CallPermissions();

  /// The pre-sign-in greeting session — connects via `POST /welcome/token`
  /// (no account) instead of `POST /bootstrap`.
  final bool welcome;

  /// Practice Date voice (hackathon B): when non-null, this is a simulated-match
  /// practice call against that user's viewer-visible profile — [start] connects
  /// via `POST /practice/voice/start` (which seeds the persona prompt) instead
  /// of `/bootstrap`, and the persona's immersion is kept by routing coach
  /// nudges to [coachHint] rather than the persona's own voice. Ayma's normal
  /// screen-awareness / navigation and the `raw_turns` post-turn persistence are
  /// both OFF for practice — a simulation never touches the user's real memory
  /// (the agent persists the practice transcript server-side for the debrief).
  final String? practiceOtherUid;

  bool get isPractice => practiceOtherUid != null;

  /// Shared with the chat screen so voice + text land in one `raw_turns` doc.
  final String sessionId;
  final TranscriptStore _store;
  final ApiClient? _apiClient;

  /// The live transcript this session writes its voice segments to (§1.7 step
  /// 12). Exposed so a surface that only has the controller — e.g. the
  /// sign-in page's pre-sign-in greeting, where there is no uid and so no
  /// backend [AppCommandService] navigation path — can observe the user's own
  /// finalized voice turns and act on them locally.
  TranscriptStore get transcript => _store;

  /// Lazy so merely constructing the controller (e.g. in a widget build) never
  /// touches `FirebaseAuth.instance` — same pattern as `ChatScreen._api`.
  late final ApiClient _api = _apiClient ?? ApiClient();
  final VoiceTransport Function() _transportFactory;

  /// Requests whatever a call needs up front (Android's POST_NOTIFICATIONS,
  /// for the background call notification — F4/item 3), rather than
  /// discovering a missing permission only once the app is backgrounded.
  final CallPermissions _permissions;

  /// Where failed starts / dropped calls are reported (Sentry + Crashlytics).
  final ErrorReporter _reporter;

  /// The voice backend `/bootstrap` reported for this call, for report tags.
  String _provider = '';

  /// Set once the current [start] has used its one automatic retry after the
  /// agent failed to join (see [_onWakingTimeout]).
  bool _noJoinRetried = false;

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

  /// Client-side backstop for the agent's own 3-minute idle stop (the agent
  /// reports it via `call_ending`/`idle_timeout`): if a live call sees no
  /// agent/transcript/tool events for this long — 1 minute longer than the
  /// agent's window — the agent evidently isn't going to end it (crashed or
  /// unreachable), so end it here and stop paying for an empty room.
  final Duration _idleGuardTimeout;
  Timer? _idleGuard;

  /// How long to wait, once the session reaches [VoiceSessionPhase.live] (the
  /// agent has joined the room and published its track, so the UI would say
  /// "Listening…"), for the agent to produce its FIRST genuine response —
  /// audible speech, a transcript segment, or a tool call. A healthy call
  /// always produces an opener within seconds, even if the caller stays silent
  /// (the agent's `maybe_open_conversation`). When Ayma's inference runs but
  /// the LiveKit gateway is 429/drained/unreachable (AGENTS.md "all inference
  /// goes through LiveKit": when LiveKit is not working the app SHOWS AN HONEST
  /// ERROR, never a silent "Listening…"), the worker still joins the room and
  /// publishes a silent track — so `agentReady` fires and the UI reaches
  /// "Listening…" — but no response ever lands. Without this guard the call
  /// hangs on "Listening…" until the 4-minute idle guard ends it with a benign
  /// "silence" notice; this instead surfaces an honest error within a bounded
  /// window. Armed on entering `live`, cancelled for good on the first agent
  /// response ([_noteAgentResponse]).
  final Duration _responseGuardTimeout;
  Timer? _responseGuard;

  /// A longer first-response budget for the open-weights (self-hosted Modal)
  /// brain: its LLM endpoint is scale-to-zero and its first reply can take
  /// ~100s on a cold start (the agent fires a warm-up at session start and
  /// signals `open_weights_warming`). The generic 20s budget would trip during
  /// that legitimate warm-up and show the wrong error, so when the agent tells
  /// us open-weights is warming we re-arm the guard to this instead (§13.9,
  /// founder bug 2026-11-02). Matched to the backend cold-start LLM timeout;
  /// injectable for tests.
  final Duration _openWeightsResponseBudget;

  /// The `voice_status` state the agent sends while the open-weights Modal LLM
  /// is cold-starting (mirrors `VOICE_STATUS_OPEN_WEIGHTS_WARMING` in agent.py).
  static const _kOpenWeightsWarming = 'open_weights_warming';

  /// Set when the agent signals the open-weights brain is warming from a cold
  /// start (data topic `voice_status`, state `open_weights_warming`). Drives
  /// the honest, open-weights-specific status line and failure copy, instead of
  /// a silent "Listening…" / the generic "Couldn't reach the voice service".
  bool _openWeightsWarming = false;

  /// Set once the agent has produced any genuine response this session (speech,
  /// transcript, or a tool call). Latches the brain as "alive" so the
  /// no-first-response guard can never fire after a real reply — later mid-call
  /// silence is the (benign) idle guard's job, not this one's.
  bool _agentRespondedOnce = false;

  /// Non-error note shown after a call ended on its own (idle timeout).
  String? _endNotice;
  String? get endNotice => _endNotice;

  /// Practice voice (hackathon B): the practice session id returned by
  /// `/practice/voice/start` — the client fetches the debrief with it once the
  /// call ends. Empty until a practice call has started.
  String _practiceSessionId = '';
  String get practiceSessionId => _practiceSessionId;

  /// The simulated persona for this practice call (its viewer-visible identity),
  /// for the simulator header. Null outside a practice call.
  PracticePersona? _practicePersona;
  PracticePersona? get practicePersona => _practicePersona;

  /// The latest out-of-character live coach nudge to show the user during a
  /// practice voice call (from the agent's `practice_coach` data channel).
  String _coachHint = '';
  String get coachHint => _coachHint;

  VoiceTransport? _transport;
  StreamSubscription<bool>? _speakingSub;
  StreamSubscription<bool>? _readySub;
  StreamSubscription<TranscriptSegment>? _transcriptSub;
  StreamSubscription<ToolUsedEvent>? _toolEventsSub;
  StreamSubscription<String>? _callEndingSub;
  StreamSubscription<bool>? _agentMuteSub;
  StreamSubscription<String>? _coachSub;
  StreamSubscription<String>? _voiceStatusSub;
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

  /// Synchronous single-flight latch for [start]: set the instant a start is
  /// admitted and cleared only when that start fully settles. [isActive] alone
  /// can't guard re-entrancy because it doesn't become true until
  /// [VoiceSessionPhase.connecting] is set — and there's an `await
  /// existing.stop()` *before* that (tearing down another surface's session).
  /// A second near-simultaneous [start] (the founder's rapid orb taps,
  /// 2026-11-02) would slip through the `isActive` check during that await and
  /// open a SECOND LiveKit room — two agents talking over each other. This flag
  /// is written before any await, so only the first caller in a burst proceeds.
  bool _starting = false;

  bool _agentSpeaking = false;
  bool get agentSpeaking => _agentSpeaking;

  bool _muted = false;
  bool get muted => _muted;

  /// True while the agent has been told to "shut up" and is deliberately
  /// silent (server-side `MuteState`, authoritative: the agent re-publishes
  /// it on every change and whenever the app (re)joins the room); cleared
  /// when she is called back by name or unmuted ([unmuteAyma]), and on
  /// session end. Distinct from [muted], the user's own mic.
  bool _aymaQuiet = false;
  bool get aymaQuiet => _aymaQuiet;

  /// True from the moment a one-shot retry kicks in for the current
  /// `start()`: either the first connect attempt died with an
  /// ICE-connectivity timeout ([isIceConnectivityFailure]) and we're retrying
  /// once with the ICE transport policy forced to TURN relay, or the agent
  /// never joined and we're starting over in a fresh room
  /// ([_onWakingTimeout]). The existing connecting status line reads
  /// "Reconnecting…" instead of "Connecting…" while this is set; no other UI.
  bool _relayRetrying = false;
  bool get relayRetrying => _relayRetrying;

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

  /// The single source of truth for "Ayma is genuinely listening": the agent
  /// has joined the room and reached the live state (the one-shot `agentReady`
  /// latch promoted `waking` -> `live` in [_onAgentReady]), NOT merely that a
  /// call is being set up. Both the OS call surface ([CallBackgroundService] —
  /// the Android ongoing-call notification / iOS CallKit call) and the central
  /// voice orb's live/"connected" treatment ([AymaOrb.voiceLive]) gate on this
  /// one getter so they can never disagree or light up during
  /// connecting/waking, matching the composer's own `connecting` vs
  /// `listening` distinction.
  bool get isListening => _phase == VoiceSessionPhase.live;

  /// The honest status line to show in place of "Listening…" while the
  /// open-weights (self-hosted Modal) brain is warming from a cold start — the
  /// agent signalled `open_weights_warming` and no first reply has landed yet
  /// (§13.9). Null on every other path / once a reply arrives, so the UI falls
  /// back to its normal "Listening…".
  String? get warmingNotice =>
      (_openWeightsWarming && !_agentRespondedOnce && isListening)
          ? 'Warming up the open-weights model — first reply can take a minute '
              'or two'
          : null;

  /// The controller with a session currently starting or live, if any — the
  /// process-wide registry that enforces the single-active-voice-session
  /// invariant. [start] reads it to tear down any other live session before
  /// connecting (see there); screens outside the chat shell (e.g. the
  /// voice-preview picker) also read it to stop a call before doing something
  /// that would talk over it. Set in [start], cleared in [stop], [_endForIdle]
  /// and [dispose] (never on the error path, so a banner can explain a failed
  /// start until the next start clears it).
  static VoiceSessionController? active;

  /// Begin a voice session. Safe to call when already active (no-op).
  ///
  /// The OS microphone prompt is raised by the WebRTC layer the first time
  /// [VoiceTransport.setMicrophoneEnabled] is called; a denied permission
  /// surfaces there as a thrown error and lands the session in
  /// [VoiceSessionPhase.error].
  Future<void> start() async {
    // Single-flight: reject a re-entrant start the moment one is already
    // active OR in flight. `_starting` is set SYNCHRONOUSLY (before the first
    // await below), which closes the gap `isActive` leaves open — `isActive`
    // only turns true once `connecting` is set, and that comes *after* the
    // `await existing.stop()` below, so without `_starting` a burst of rapid
    // orb taps each slips past the `isActive` check during that await and opens
    // its own room (two agents talking over each other — founder report
    // 2026-11-02). One tap/one start in a burst is admitted; the rest no-op.
    if (isActive || _starting) return;
    _starting = true;
    try {
      // Single-active-voice-session invariant (ARCHITECTURE.md §1.3): only ONE
      // voice session may ever be live at a time, across every surface — the
      // main Ayma call, a Practice Date call, the Ask-Ayma push-to-talk
      // capture. Each is a separate controller with its OWN LiveKit room, so
      // without this they can talk over each other (founder report 2026-10-26:
      // a live main Ayma call + a Practice Date voice call both running, two
      // personas speaking at once). This is the one mutual-exclusion point:
      // before connecting, fully tear down whatever OTHER session is active —
      // its own `stop()` disconnects its room, releases its mic, and flips it
      // to idle, which clears its orb and (for the main call) its foreground
      // call notification through the listeners already watching it. Awaited,
      // so the old room is gone before this one publishes audio — never a
      // window where both are live. `active` is the shared registry every
      // voice surface writes on start.
      final existing = active;
      if (existing != null && !identical(existing, this) && existing.isActive) {
        await existing.stop();
      }
      _errorMessage = null;
      _endNotice = null;
      _cappedError = false;
      _backgroundPermissionDenied = false;
      _relayRetrying = false;
      _agentSpeaking = false;
      _agentReadySeen = false;
      _agentRespondedOnce = false;
      _openWeightsWarming = false;
      _muted = false;
      _pendingToolLabels.clear();
      _activeToolLabel = null;
      _noJoinRetried = false;
      _provider = '';
      _coachHint = '';
      active = this;
      _setPhase(VoiceSessionPhase.connecting);
      // Best-effort and fire-before-connect: ask for whatever the call will
      // need in the background while the user still has full context for the
      // OS prompt, so it's (hopefully) already settled by the time
      // backgrounding actually needs it. Never blocks or fails the call — a
      // foreground call never needed this permission in the first place.
      unawaited(_permissions.ensureCallStartPermissions());
      await _attempt();
    } finally {
      // Held for the whole connect (where `isActive` is already true, so the
      // guard still holds via that), and cleared once this start has fully
      // settled — reached `live`, ended in `error`, or returned early. A later
      // start (e.g. a retry after an error) is then free to proceed.
      _starting = false;
    }
  }

  /// One full connect attempt: credentials, room connect, mic publish, then
  /// `waking` until the agent joins. Every failure tears down, is reported
  /// (with tags) and lands in [VoiceSessionPhase.error] with a clear message.
  Future<void> _attempt() async {
    try {
      final String url;
      final String token;
      if (welcome) {
        debugPrint('[voice] start(): calling /welcome/token');
        final w = await _api.welcomeToken();
        url = w.url;
        token = w.token;
      } else if (isPractice) {
        debugPrint('[voice] start(): calling /practice/voice/start');
        final sess = await _api.practiceVoiceStart(practiceOtherUid!);
        if (sess == null) {
          _fail('There is no profile to practice with.');
          return;
        }
        if (sess.usageCapped) {
          _cappedError = true;
          _fail('Out of credits — tap Upgrade to use voice.');
          return;
        }
        _practiceSessionId = sess.sessionId;
        _practicePersona = sess.persona;
        url = sess.livekitUrl;
        token = sess.livekitToken;
      } else {
        debugPrint('[voice] start(): calling /bootstrap');
        final session = await _api.bootstrap(
          sessionId: sessionId,
          recentTurns: _store.wireTurns(),
        );
        if (session.usageCapped) {
          _cappedError = true;
          _fail('Out of credits — tap Upgrade to use voice.');
          return;
        }
        url = session.livekitUrl;
        token = session.livekitToken;
        _provider = session.voiceProvider;
      }
      debugPrint('[voice] token ok: url=$url tokenLen=${token.length}');
      if (token.isEmpty || url.isEmpty) {
        _report(const VoiceStartError('no voice credentials in response'),
            null, 'no_credentials');
        _fail('The server did not return voice credentials.');
        return;
      }

      VoiceTransport transport;
      try {
        transport =
            await _connectTransport(url: url, token: token, forceRelay: false);
      } catch (e) {
        if (!isIceConnectivityFailure(e)) rethrow;
        // The PeerConnection never reached connected — ICE connectivity
        // between this client and LiveKit Cloud, typically a UDP-blocking
        // network. Retry ONCE with the ICE transport policy forced to TURN
        // relay (LiveKit Cloud serves TURN over TLS/443). A second failure
        // propagates to the generic catch below — the existing error surface.
        debugPrint('[voice] connect attempt 1 failed with ICE timeout: $e');
        debugPrint(
            '[voice] ice-relay-retry: retrying once with TURN relay forced');
        await _teardown();
        _relayRetrying = true;
        notifyListeners(); // status line: "Connecting…" -> "Reconnecting…"
        transport =
            await _connectTransport(url: url, token: token, forceRelay: true);
        debugPrint('[voice] ice-relay-retry: relay connect succeeded');
      }

      try {
        await transport.setMicrophoneEnabled(true);
      } catch (e, st) {
        _report(e, st, 'mic_permission');
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
    } on ApiException catch (e, st) {
      debugPrint('[voice] ApiException: ${e.message}');
      _report(e, st, 'token_fetch',
          extra: {'http_status': '${e.statusCode ?? 'none'}'});
      await _teardown();
      _fail(e.message);
    } catch (e, st) {
      debugPrint('[voice] start() FAILED: $e\n$st');
      _report(e, st, 'connect');
      await _teardown();
      _fail('Could not start voice ($e).');
    }
  }

  /// Reports a voice failure as a handled event, never blocking the caller.
  /// Tags are ids/categories only (no user text, no uid, no room name — the
  /// room name embeds the uid).
  void _report(
    Object error,
    StackTrace? stack,
    String stage, {
    Map<String, String> extra = const {},
  }) {
    final screen = AppContext.instance.current.value.screen;
    unawaited(_reporter.report(error, stack, reason: 'voice_$stage', tags: {
      'feature': 'voice',
      'voice_stage': stage,
      'voice_phase': _phase.name,
      'session_id': sessionId.isEmpty ? 'none' : sessionId,
      'provider': _provider.isEmpty ? 'unknown' : _provider,
      'route': screen.isEmpty ? 'unknown' : screen,
      'welcome': '$welcome',
      'attempt': _noJoinRetried ? '2' : '1',
      'relay': '$_relayRetrying',
      ...extra,
    }));
  }

  /// Build a fresh transport, wire every stream listener, and connect —
  /// one attempt of `start()`'s connect step (attempt 2 is the one-shot
  /// ice-relay-retry with [forceRelay] set). On a thrown connect the caller
  /// owns cleanup via [_teardown]; the field assignments here all happen
  /// synchronously before the single `await`, so `_teardown()`'s
  /// snapshot-and-null discipline holds.
  Future<VoiceTransport> _connectTransport({
    required String url,
    required String token,
    required bool forceRelay,
  }) async {
    final transport = _transportFactory();
    _transport = transport;
    // Driven by the agent's authoritative state (§1.3). A barge-in flips this
    // false the instant Gemini Live's turn-detection interrupts a reply, so
    // the UI stops indicating playback immediately (§1.7 step 10).
    _speakingSub = transport.agentSpeaking.listen((speaking) {
      _noteActivity();
      if (speaking) _noteAgentResponse();
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
    _agentMuteSub = transport.agentMute.listen((quiet) {
      _noteActivity();
      if (!identical(_transport, transport) || _aymaQuiet == quiet) return;
      _aymaQuiet = quiet;
      notifyListeners();
    });
    // Practice Date voice (hackathon B): a live coach nudge to the user, shown
    // as a side hint — distinct from the persona's own transcript, so immersion
    // in the simulation is never broken.
    _coachSub = transport.practiceCoach.listen((hint) {
      _noteActivity();
      if (!identical(_transport, transport) || hint.isEmpty) return;
      _coachHint = hint;
      notifyListeners();
    });
    _voiceStatusSub = transport.voiceStatus.listen((state) {
      if (!identical(_transport, transport)) return;
      _onVoiceStatus(state);
    });
    _closedSub = transport.closed.listen((_) {
      // A close event queued by a transport this controller has already torn
      // down (e.g. ice-relay-retry attempt 1's Room emitting RoomDisconnected
      // just as attempt 2 is being built) must not fail the newer session —
      // `_teardown()` nulls `_transport` synchronously, so a stale event
      // never passes this identity check.
      if (!identical(_transport, transport)) return;
      unawaited(_teardown());
      if (_cappedError) return;
      _report(const VoiceStartError('voice connection dropped'), null,
          'dropped');
      _fail('The voice connection dropped.');
    });

    await transport.connect(url: url, token: token, forceRelay: forceRelay);
    return transport;
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
    _noteActivity();
    // The agent is in the room, but "joined" is not "can respond": if the
    // LiveKit inference gateway is down/429, the worker joins and the UI shows
    // "Listening…" yet no reply ever comes. Arm the bounded no-first-response
    // guard so that silent-brain case fails loudly instead of hanging.
    if (!_agentRespondedOnce) {
      _responseGuard?.cancel();
      _responseGuard = Timer(_firstResponseBudget, _onResponseGuardFired);
    }
  }

  /// The no-first-response budget for the running brain: the longer cold-start
  /// budget once the open-weights brain has signalled it is warming, else the
  /// generic 20s. Keeps a legitimate Modal warm-up from tripping the guard.
  Duration get _firstResponseBudget =>
      _openWeightsWarming ? _openWeightsResponseBudget : _responseGuardTimeout;

  /// The agent's honest voice-stack status (data topic `voice_status`). So far
  /// only the open-weights cold start: `open_weights_warming` means the Modal
  /// LLM is spinning up and the first reply can take ~100s. Latch it so the
  /// status line says so (not a silent "Listening…") and extend the
  /// no-first-response guard past the cold start so it doesn't fire early.
  void _onVoiceStatus(String state) {
    if (state != _kOpenWeightsWarming || _openWeightsWarming) return;
    _openWeightsWarming = true;
    // Re-arm an already-armed first-response guard with the longer budget
    // (warming can arrive after `live`, when the generic 20s guard is running).
    if (!_agentRespondedOnce && _responseGuard != null) {
      _responseGuard!.cancel();
      _responseGuard = Timer(_firstResponseBudget, _onResponseGuardFired);
    }
    notifyListeners();
  }

  /// The agent produced a genuine response (speech / transcript / tool call) —
  /// the brain is alive, so cancel the no-first-response guard for good.
  void _noteAgentResponse() {
    if (_agentRespondedOnce) return;
    _agentRespondedOnce = true;
    _responseGuard?.cancel();
    _responseGuard = null;
  }

  /// Live, but the agent never produced a first response within
  /// [_responseGuardTimeout] — the LiveKit gateway/brain is unreachable even
  /// though the worker joined the room. Surface an honest error rather than
  /// leaving the UI stuck on "Listening…" (AGENTS.md).
  void _onResponseGuardFired() {
    _responseGuard = null;
    if (_phase != VoiceSessionPhase.live || _agentRespondedOnce) return;
    // Capture BEFORE `_teardown()` — it runs synchronously up to its first
    // await and clears `_openWeightsWarming`, so reading the field after it
    // would always see `false` and show the generic copy.
    final warming = _openWeightsWarming;
    final budget = _firstResponseBudget;
    debugPrint('[voice] no first response — brain unreachable');
    _report(
      VoiceStartError('no agent response within ${budget.inSeconds}s of live'
          '${warming ? ' (open-weights)' : ''}'),
      null,
      warming ? 'open_weights_no_response' : 'no_response',
    );
    unawaited(_teardown());
    // Honest, brain-specific copy: the open-weights (Modal) model never came up
    // in time, so say exactly that and offer the real options — instead of the
    // generic "Couldn't reach the voice service" (founder ask, 2026-11-02).
    _fail(warming
        ? 'The open-weights model is unavailable right now — try again or '
            'switch models.'
        : "Couldn't reach the voice service — tap the mic to try again.");
  }

  /// Restarts the client idle guard (see [_idleGuardTimeout]) — only while
  /// live. Called on every agent-originated event.
  void _noteActivity() {
    if (_phase != VoiceSessionPhase.live) return;
    _idleGuard?.cancel();
    _idleGuard = Timer(_idleGuardTimeout, _onIdleGuardFired);
  }

  void _onIdleGuardFired() {
    _idleGuard = null;
    if (_phase != VoiceSessionPhase.live) return;
    // Ayma mid-reply or running a skill is never "idle", however long it takes.
    if (_agentSpeaking || _activeToolLabel != null) {
      _noteActivity();
      return;
    }
    debugPrint('[voice] client idle guard fired — ending call');
    unawaited(_endForIdle());
  }

  /// Ends the call because of silence (agent-reported or client guard): back to
  /// idle with a non-error [endNotice], never the error phase.
  Future<void> _endForIdle() async {
    if (active == this) active = null;
    await _teardown();
    _agentSpeaking = false;
    _muted = false;
    _endNotice = 'Call ended after 3 minutes of silence';
    _setPhase(VoiceSessionPhase.idle);
  }

  /// The agent never joined within [_wakingTimeout]. Reported, then retried
  /// once automatically: a fresh `/bootstrap` gets a brand-new room (so a new
  /// agent dispatch) and re-sends the wake ping, and by now a cold worker has
  /// usually finished starting. A second miss tears down and surfaces a clear
  /// error instead of a silent dead "Listening".
  void _onWakingTimeout() {
    _wakingTimer = null;
    if (_phase != VoiceSessionPhase.waking) return;
    debugPrint('[voice] waking timed out — agent never joined');
    _report(
      VoiceStartError('agent did not join within ${_wakingTimeout.inSeconds}s'),
      null,
      'agent_no_join',
    );
    if (!_noJoinRetried) {
      _noJoinRetried = true;
      unawaited(_retryAfterNoJoin());
      return;
    }
    unawaited(_teardown());
    _fail("Ayma didn't pick up — try again in a moment.");
  }

  Future<void> _retryAfterNoJoin() async {
    debugPrint('[voice] no-join retry: starting over in a fresh room');
    await _teardown();
    // A stop() while the old room was being left ends the call for good.
    if (_phase != VoiceSessionPhase.waking || active != this) return;
    _agentReadySeen = false;
    _relayRetrying = true;
    _setPhase(VoiceSessionPhase.connecting);
    await _attempt();
  }

  void _onTranscriptSegment(TranscriptSegment seg) {
    _noteActivity();
    final role = seg.topic == 'agent_transcript' ? TurnRole.ayma : TurnRole.user;
    if (role == TurnRole.ayma) _noteAgentResponse();
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
    _noteActivity();
    _noteAgentResponse();
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
  /// [showOutOfCreditsSheet] affordance the pre-call `usageCapped` check
  /// above already uses, rather than a new one-off path.
  void _onCallEnding(String reason) {
    if (reason == 'idle_timeout') {
      unawaited(_endForIdle());
      return;
    }
    if (reason != 'out_of_credits') return;
    _cappedError = true;
    _fail('Out of credits — Ayma had to end the call. Upgrade to '
        'keep going.');
  }

  /// Best-effort raw_turns persistence on session end (§1.7 step 8). The agent
  /// worker also persists on room disconnect; both upsert the same doc.
  void _persistSession() {
    // A practice simulation must never fold into the user's real `raw_turns`
    // memory — the agent persists the practice transcript server-side (to the
    // practice session) for the debrief instead.
    if (isPractice || sessionId.isEmpty) return;
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
  /// credit top-up (see `DeveloperScreen._reload`) so the banner actually goes
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

  /// The user tapped Unmute (the quiet chip, the nav-bar orb, or the call
  /// notification's "Unmute Ayma" action): ask the agent to talk again.
  /// [aymaQuiet] is not flipped here — it follows the agent's own
  /// `agent_mute` echo, so the app can never claim she is back while the
  /// agent still has her muted. A failed send leaves her quiet (the control
  /// stays up to retry, and saying "Ayma" still works).
  Future<void> unmuteAyma() async {
    final transport = _transport;
    if (!_aymaQuiet || _phase != VoiceSessionPhase.live || transport == null) {
      return;
    }
    try {
      await transport.sendAgentMuteControl(muted: false);
    } catch (e) {
      debugPrint('[voice] unmute request failed: $e');
    }
  }

  /// The voice settings were saved mid-call (§13.9): tell the live agent the
  /// saved accent/language so it hot-swaps this call instead of waiting for
  /// the next one. Returns whether the message was delivered — `false` when
  /// no call is live (the save still applies from the next call) or the send
  /// failed (best effort; the save itself already succeeded).
  Future<bool> notifyVoiceAccentChanged({
    required String accent,
    required String language,
  }) async {
    final transport = _transport;
    if (_phase != VoiceSessionPhase.live || transport == null) {
      return false;
    }
    try {
      await transport.sendVoiceAccentControl(
        accent: accent,
        language: language,
      );
      return true;
    } catch (e) {
      debugPrint('[voice] accent-control send failed: $e');
      return false;
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
    // The practice persona is not Ayma — it has no app tools and no business
    // seeing what the user is looking at, so a practice call never mirrors the
    // screen or watches for navigation commands.
    if (isPractice) return;
    if (_mirroring) return;
    _mirroring = true;
    _commands.start();
    ScreenCapture.instance.setLive(true);
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
    ScreenCapture.instance.setLive(false);
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
    _idleGuard?.cancel();
    _idleGuard = null;
    _responseGuard?.cancel();
    _responseGuard = null;

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
    final agentMuteSub = _agentMuteSub;
    final coachSub = _coachSub;
    final voiceStatusSub = _voiceStatusSub;
    final closedSub = _closedSub;
    final micLevelSub = _micLevelSub;
    final aymaLevelSub = _aymaLevelSub;
    final transport = _transport;
    _speakingSub = null;
    _readySub = null;
    _transcriptSub = null;
    _toolEventsSub = null;
    _callEndingSub = null;
    _agentMuteSub = null;
    _coachSub = null;
    _voiceStatusSub = null;
    _openWeightsWarming = false;
    _aymaQuiet = false;
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
    await agentMuteSub?.cancel();
    await coachSub?.cancel();
    await voiceStatusSub?.cancel();
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
    _coachSub?.cancel();
    _closedSub?.cancel();
    _micLevelSub?.cancel();
    _aymaLevelSub?.cancel();
    unawaited(_teardown());
    super.dispose();
  }
}
