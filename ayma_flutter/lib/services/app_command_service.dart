import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../routing/app_router.dart';
import '../screens/explore_screen.dart';
import '../screens/sign_in_screen.dart';
import '../widgets/ask_ayma_overlay.dart';
import 'accent_color_controller.dart';
import 'api_client.dart';
import 'app_context.dart';
import 'guided_tour_controller.dart';
import 'navigation_history.dart';
import 'notification_service.dart';
import 'orb_animation_settings.dart';
import 'pair_key.dart';
import 'profile_service.dart';
import 'push_service.dart';
import 'screen_capture.dart';
import 'theme_controller.dart';
import 'tour_anchors.dart';
import 'tour_content.dart';
import 'tour_controller.dart';
import 'voice_session_controller.dart';

/// While the app is foregrounded — a live voice call or the text chat — Ayma
/// can queue one UI command at `users/{uid}/app_commands/pending` (backend
/// `skills.app_control`). This watches that doc, performs the
/// navigation/action, **acks it** at `users/{uid}/app_commands/ack`
/// (`{id, ok}` — the backend tool is waiting on that exact id to tell the
/// model whether navigation really happened), and deletes it. One shared
/// instance ([shared]) listens whenever either owner wants it: the voice
/// session ([start]/[stop]) or the app being foregrounded
/// ([setForeground], driven by `AppCommandHost`). A backgrounded app never
/// listens, so the backend's ack wait times out honestly.
///
/// Delivery hardening (founder bug, 2026-09-26 — "open my profile" during a
/// call did nothing, twice, while Ayma claimed success):
/// * the snapshot listener **resubscribes** after an error or an unexpected
///   stream close instead of dying silently for the rest of the call (the
///   old `onError: (_) {}` swallowed the error AND the subscription — every
///   later command was dropped with no trace);
/// * commands are deduped by `id`, so a cache re-delivery around a
///   resubscribe never runs the same navigation twice;
/// * a command whose server `ts` is older than [_staleAfter] is discarded
///   unexecuted — surprise-navigating minutes later (or on the *next* call,
///   off a doc a dead listener left behind) is worse than skipping. Inside
///   the window a late command still executes and acks: a command queued in
///   the last second of a voice segment used to die right there — the
///   session tore down, the listener went with it, and on the next attach
///   the orphan was already "stale", deleted unexecuted and unacked while
///   Ayma claimed the page had opened (founder bug, 2026-11-03).
///   [_staleAfter] is sized to that boundary gap (a segment reconnect, a
///   stack-switch session restart, a quick app relaunch), NOT to the
///   backend's 6s ack wait: the wait will usually have timed out by the
///   time a boundary command lands, so Ayma has already honestly said it
///   didn't go through — executing on attach still puts the user where
///   they asked to be, and the ack keeps the record truthful;
/// * the post-handle delete is transactional on the command `id`, so it can
///   never swallow a newer command that landed between our read and our
///   delete.
///
/// Three kinds of command land here, all dispatched by `action`:
/// * navigation — `navigate` (the route `path` the backend resolved from
///   `functions/bootstrap/app_registry.json`, the single source of truth for
///   destinations), `search_explore`, `open_profile`, `open_dm_thread`,
///   `open_notification` (the backend-resolved latest unread notification's
///   `deep_link`, routed exactly like a notification-centre tap);
/// * `app_action` — the registry's client-held settings (theme, accent,
///   pause matching, orb animation), each calling the exact method its
///   screen's switch/radio calls, plus the confirmed `sign_out`, which the
///   backend only sends after the user explicitly confirmed and which runs
///   after the ack is written. Deleting the account and withdrawing consent
///   are never commands: Ayma only opens those pages (founder rule);
/// * `reconnect_voice` — tear down and re-establish the live voice session so a
///   just-saved model stack (brain/voice/mode/realtime model) applies now; it
///   runs after the ack is written (like sign out) and acks `false` when no
///   call is live (`skills/set_model_stack`);
/// * `ui_action` — operate one on-screen control through [ScreenCapture]
///   (which refuses the registry's denylist), acked with the outcome and
///   what the screen shows afterwards;
/// * `go_back` — return to the previous page of the session navigation
///   history ([NavigationHistory], founder feedback item 15): one step per
///   request, a modal/sheet is dismissed first (as the user's own back
///   would), an active tour is never fought, and at the root the ack
///   carries a sayable reason instead of a silent failure. Like
///   `ui_action` it owns its ack (see [_runGoBackCommand]) because it may
///   have to await the modal dismissal first.
class AppCommandService {
  AppCommandService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    void Function(String path)? navigate,
    void Function(String path)? go,
    ThemeController? themeController,
    ProfileService? profileService,
    AccentColorController? accentController,
    OrbAnimationSettings? orbAnimationSettings,
    Future<void> Function()? clearPushToken,
    Future<UiActionResult> Function(Map<String, dynamic> cmd)? uiAction,
    bool Function()? chatPopupOpen,
    Future<void> Function()? closeChatPopup,
    String Function()? currentPath,
    bool Function()? hasActiveVoice,
    Future<void> Function()? reconnectVoice,
    NavigationHistory? navigationHistory,
    bool Function()? popupOpen,
    Future<bool> Function()? dismissPopup,
    bool Function()? tourActive,
    Future<void> Function(int index)? sendTourContinuation,
    Future<void> Function(int index)? sendTourStop,
  })  : _sendTourContinuation = sendTourContinuation ?? _postTourContinuation,
        _sendTourStop = sendTourStop ?? _postTourStop,
        _chatPopupOpen = chatPopupOpen ?? (() => isAymaSheetOpen),
        _hasActiveVoice = hasActiveVoice ??
            (() => VoiceSessionController.active?.isActive ?? false),
        _reconnectVoice = reconnectVoice ?? _reconnectActiveVoice,
        _closeChatPopup =
            closeChatPopup ?? ScreenCapture.instance.closeAymaPopup,
        _currentPath = currentPath ?? _routerPath,
        _history = navigationHistory ?? NavigationHistory.instance,
        _popupOpen = popupOpen ?? _defaultPopupOpen,
        _dismissPopup = dismissPopup ?? _defaultDismissPopup,
        _tourActive = tourActive ??
            (() =>
                TourController.instance.active ||
                GuidedTourController.instance.active ||
                GuidedTourController.instance.sessionActive),
        _accentOverride = accentController,
        _uiAction = uiAction ?? _performUiAction,
        _fsOverride = firestore,
        _authOverride = auth,
        _navigate = navigate ?? ((p) => navigateToRoute(p)),
        _go = go ?? appRouter.go,
        _theme = themeController ?? themeControllerGlobal,
        _orbAnim = orbAnimationSettings ?? orbAnimationSettingsGlobal,
        _clearPushTokenOverride = clearPushToken,
        _profilesOverride = profileService;

  final FirebaseFirestore? _fsOverride;
  final FirebaseAuth? _authOverride;
  final void Function(String path) _navigate;
  final void Function(String path) _go;

  /// Ayma's page-context chat popup: open?, and close it (waits for its
  /// dismiss transition). EVERY navigation command closes it first — as
  /// part of the navigation, not as a navigation of its own — so the
  /// destination page is actually visible, not left underneath the popup
  /// (partial or expanded).
  final bool Function() _chatPopupOpen;
  final Future<void> Function() _closeChatPopup;

  /// The concrete location on top (`/dm/<id>`), so a navigation to where the
  /// user already is does not push a second copy.
  final String Function() _currentPath;

  static String _routerPath() {
    try {
      return appRouter.state.uri.path;
    } catch (_) {
      return '';
    }
  }

  /// The session navigation history every navigation through this
  /// service is recorded into (and `go_back` unwinds). Injectable for
  /// tests; production shares [NavigationHistory.instance], which the
  /// router listener and the tab shell also feed, so user-driven and
  /// Ayma-driven navigation land in the ONE stack.
  final NavigationHistory _history;
  NavigationHistory get history => _history;

  /// Whether any modal/sheet (or Ayma's own chat popup) is on top right
  /// now, and how to dismiss the top one — a `go_back` with a modal up
  /// dismisses it first, exactly like the user's own back press.
  final bool Function() _popupOpen;
  final Future<bool> Function() _dismissPopup;

  static bool _defaultPopupOpen() =>
      screenPopupTracker.popupOpen || isAymaSheetOpen;

  static Future<bool> _defaultDismissPopup() async =>
      await screenPopupTracker.navigator?.maybePop() ?? false;

  /// Whether a tour overlay (the passive coach-mark tour or an
  /// Ayma-driven guided-tour step) is currently showing. `go_back` never
  /// fights a tour: it reports the tour instead of navigating under it.
  final bool Function() _tourActive;

  final ThemeController _theme;
  final OrbAnimationSettings _orbAnim;
  final Future<void> Function()? _clearPushTokenOverride;
  final Future<UiActionResult> Function(Map<String, dynamic> cmd) _uiAction;

  static Future<UiActionResult> _performUiAction(Map<String, dynamic> cmd) =>
      ScreenCapture.instance.perform(
        control: (cmd['control'] as String? ?? '').trim(),
        label: (cmd['label'] as String? ?? '').trim(),
        op: (cmd['op'] as String? ?? '').trim(),
        value: cmd['value'] as String? ?? '',
      );

  /// Whether a voice call is live right now (so `reconnect_voice` can ack
  /// honestly) and how to reconnect it. Injectable for tests; the defaults use
  /// the process-wide [VoiceSessionController.active].
  final bool Function() _hasActiveVoice;
  final Future<void> Function() _reconnectVoice;

  /// Fires a guided-tour continuation (§11.2b) for the TEXT surface: a minimal
  /// `/chat` ping that makes the model call `advance_guided_tour`. Injectable
  /// for tests; the default POSTs a non-persisted tour-continuation turn.
  final Future<void> Function(int index) _sendTourContinuation;

  /// Fires a guided-tour stop signal for the TEXT surface when user clicks "Skip tour" (§11.2b):
  /// a minimal `/chat` ping that makes the model consume stop and clean up tour state.
  final Future<void> Function(int index) _sendTourStop;

  /// The one-line tour-tap signal the model reads as "a real tap happened —
  /// advance." A fixed control signal, not a persona/prompt template (it is
  /// never persisted; the backend drops it via `tour_continuation`).
  static const _tourTapSignal =
      'The user just tapped the highlighted control in the guided tour. '
      'Continue the tour: call advance_guided_tour now to move to the next step.';

  static const _tourStopSignal =
      'The user clicked "Skip tour" in the guided tour. '
      'Call stop_guided_tour now to end the tour.';

  /// Default TEXT continuation: a fire-and-forget `/chat` turn flagged
  /// `tour_continuation` so neither the ping nor the narration persists. The
  /// reply is ignored — the spotlight advance arrives via the next `tour_step`
  /// command the backend queues from `advance_guided_tour`.
  static Future<void> _postTourContinuation(int index) async {
    try {
      await ApiClient().chat(_tourTapSignal, tourContinuation: true);
    } catch (e) {
      debugPrint('Ayma tour continuation ping failed: $e');
    }
  }

  static Future<void> _postTourStop(int index) async {
    try {
      await ApiClient().chat(_tourStopSignal, tourContinuation: true);
    } catch (e) {
      debugPrint('Ayma tour stop ping failed: $e');
    }
  }

  /// Bridge an async tour tap to a model-narrated advance (§11.2b): on voice,
  /// tell the live agent (data channel → `generate_reply`); otherwise fire the
  /// TEXT `/chat` continuation. Either way the model calls `advance_guided_tour`,
  /// which consumes the already-written `tour_event` and narrates/spotlights the
  /// next step — no dependence on a blocking advance being alive at tap time.
  void _kickTourAdvance(int index) {
    final voice = VoiceSessionController.active;
    if (voice != null && voice.isActive) {
      unawaited(voice.notifyTourTapped(index: index));
      return;
    }
    unawaited(_sendTourContinuation(index));
  }

  void _kickTourStop(int index) {
    final voice = VoiceSessionController.active;
    if (voice != null && voice.isActive) {
      return;
    }
    unawaited(_sendTourStop(index));
  }

  /// When the last reconnect was scheduled — a circuit breaker so a session that
  /// was just reconnected (and is re-seeded with the "reconnect" transcript)
  /// can't immediately reconnect again in a loop (founder 2026-11-03).
  DateTime? _lastReconnectAt;
  static const _reconnectCooldown = Duration(seconds: 45);

  /// Reconnect the live voice session so a just-saved model stack applies now:
  /// stop the current LiveKit room and start a fresh one, which re-runs
  /// `/bootstrap` → re-reads the saved stack (`VoiceSessionController.start` →
  /// `_attempt` → `_api.bootstrap`). A short grace delay first lets Ayma's
  /// spoken "reconnecting" confirmation play before the room drops. All voice
  /// stays on LiveKit — this only re-establishes the same room path.
  static Future<void> _reconnectActiveVoice() async {
    final session = VoiceSessionController.active;
    if (session == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await session.stop();
    await session.start();
  }

  /// A confirmed sign out — or a `reconnect_voice` — waiting to run once the ack
  /// and the pending-doc cleanup are written. Sign-out and reconnect both tear
  /// down state the ack write itself depends on (the `users/{uid}` path, or the
  /// live room), so they must run strictly after the ack is persisted.
  Future<void> Function()? _afterAck;
  final AccentColorController? _accentOverride;
  AccentColorController get _accent =>
      _accentOverride ?? accentColorControllerGlobal;
  final ProfileService? _profilesOverride;

  /// The one listener the app and the voice session share, so a command is
  /// never executed twice by two competing subscriptions.
  static final AppCommandService shared = AppCommandService();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  bool _voiceActive = false;
  bool _foreground = false;
  bool get _started => _voiceActive || _foreground;
  Timer? _resubscribe;
  String _lastHandledId = '';

  /// The `search_explore` command whose loaded results still owe the backend
  /// tool a report (its id, and the search text Explore must have run for).
  String _awaitingExploreId = '';
  String _awaitingExploreQuery = '';
  bool _reportListening = false;

  /// A command older than this on arrival is dropped unexecuted. The
  /// window is a session-boundary survival window, not an ack window: the
  /// backend's ack wait (`_ACK_TIMEOUT_SECONDS`, 6s) is far shorter, so a
  /// command that only lands on the next attach executes after Ayma has
  /// already honestly said it didn't go through — but it executes, and
  /// acks, instead of dying silently at the boundary (founder bug,
  /// 2026-11-03). Anything older than this is a leftover from a dead
  /// session, and running it would surprise-navigate long after the ask.
  static const _staleAfter = Duration(seconds: 90);

  /// Backoff before re-attaching a listener that errored/closed mid-call.
  static const _resubscribeDelay = Duration(seconds: 2);

  FirebaseFirestore get _db => _fsOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  // Lazy, like `_db`/`_auth` above: `ProfileService()`'s default constructor
  // touches `FirebaseAuth.instance` eagerly, which throws with no Firebase
  // app in a plain unit test — fine as long as nothing actually needs it
  // (most commands don't).
  ProfileService get _profiles => _profilesOverride ?? ProfileService();

  /// Begin watching. Idempotent, and a no-op if Firestore can't be reached
  /// (e.g. no Firebase in a unit test) — voice navigation just won't work.
  void start() {
    _voiceActive = true;
    _listen();
  }

  /// The voice session ended; keeps listening if the app is foregrounded.
  Future<void> stop() async {
    _voiceActive = false;
    await _detachIfUnwanted();
  }

  /// The app moved to/from the foreground (text chat can drive the app too).
  Future<void> setForeground(bool foreground) async {
    _foreground = foreground;
    if (foreground) {
      _listen();
    } else {
      await _detachIfUnwanted();
    }
  }

  /// Re-attach the listener — after a sign-in/out the watched
  /// `users/{uid}/...` path changed. No-op while nothing wants it.
  Future<void> restart() async {
    _resubscribe?.cancel();
    _resubscribe = null;
    await _sub?.cancel();
    _sub = null;
    _lastHandledId = '';
    _listen();
  }

  Future<void> _detachIfUnwanted() async {
    if (_started) return;
    _resubscribe?.cancel();
    _resubscribe = null;
    await _sub?.cancel();
    _sub = null;
  }

  void _listen() {
    if (!_started || _sub != null) return;
    try {
      final uid = _auth.currentUser?.uid;
      if (uid == null) return;
      _sub = _db
          .doc('users/$uid/app_commands/pending')
          .snapshots()
          .listen(
            _onDoc,
            // A snapshot-stream error or unexpected close is terminal for
            // the subscription — without this, one hiccup mid-call silently
            // killed Ayma-driven navigation for the rest of the call.
            onError: (_) => _scheduleResubscribe(),
            onDone: _scheduleResubscribe,
          );
    } catch (_) {
      // Firestore unavailable this session.
    }
  }

  void _scheduleResubscribe() {
    _sub?.cancel();
    _sub = null;
    if (!_started) return;
    _resubscribe?.cancel();
    _resubscribe = Timer(_resubscribeDelay, () {
      _resubscribe = null;
      _listen();
    });
  }

  void _onDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data();
    if (data == null) return;
    final id = (data['id'] as String? ?? '').trim();
    if (id.isNotEmpty && id == _lastHandledId) return; // cache re-delivery
    if (_isStale(data)) {
      unawaited(_deleteIfStillCommand(snap.reference, id));
      return;
    }
    if (id.isNotEmpty) _lastHandledId = id;
    if (data['action'] == 'ui_action') {
      unawaited(_runUiAction(snap.reference, data, id));
      return;
    }
    if (data['action'] == 'go_back') {
      // Owns its ack like ui_action/tour_step: it may await a modal
      // dismissal, and its ack carries the outcome kind + where the user
      // ended up, so the backend tool can say it honestly.
      unawaited(_runGoBackCommand(snap.reference, id));
      return;
    }
    if (data['action'] == 'tour_step') {
      // The Ayma-driven tour spotlights one step and acks it only once the
      // overlay reports it shown (or its anchor absent), then waits for the
      // user's real tap on a separate `tour_event` doc — so it owns its ack,
      // like ui_action (§11.2b).
      _runTourStep(snap.reference, data, id);
      return;
    }
    var ok = false;
    try {
      ok = handleCommand(data);
    } catch (_) {
      ok = false; // ack the failure honestly rather than crash the stream
    }
    // Ack first (the backend tool is polling for this id right now), then
    // clear the pending doc.
    final acked = snap.reference.parent
        .doc('ack')
        .set(<String, dynamic>{
          'id': id,
          'ok': ok,
          'ts': FieldValue.serverTimestamp(),
        })
        .catchError((_) {});
    if (ok && id.isNotEmpty && data['action'] == 'search_explore') {
      _awaitingExploreId = id;
      _awaitingExploreQuery = (data['query'] as String? ?? '').trim();
      _listenForExploreReport(snap.reference.parent.doc('ack'));
    }
    final cleared = _deleteIfStillCommand(snap.reference, id);
    final after = _afterAck;
    _afterAck = null;
    if (after != null) {
      unawaited(Future.wait([acked, cleared]).then((_) => after()));
    }
  }

  /// Operate the control, then ack with the outcome: `ok`, plus what the
  /// screen shows now (`result`) or why it was refused (`reason`).
  Future<void> _runUiAction(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> cmd,
    String id,
  ) async {
    final out = await runUiAction(cmd);
    await ref.parent
        .doc('ack')
        .set(<String, dynamic>{
          'id': id,
          'ok': out.ok,
          if (out.ok) 'result': out.result else 'reason': out.reason,
          'ts': FieldValue.serverTimestamp(),
        })
        .catchError((_) {});
    await _deleteIfStillCommand(ref, id);
  }

  /// Show one Ayma-driven tour step (§11.2b) and wire its reports back to the
  /// backend: ack `ok:true` once spotlighted, ack `ok:false` (anchor absent) so
  /// the backend skips it, and — on the user's real tap or a "Skip tour" — a
  /// `tour_event` write the backend's `advance_guided_tour` is polling for.
  @visibleForTesting
  void runTourStep(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> cmd, {
    required String id,
  }) {
    _runTourStep(ref, cmd, id);
  }

  void _runTourStep(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> cmd,
    String id,
  ) {
    final index = (cmd['index'] as num?)?.toInt() ?? 0;
    final total = (cmd['total'] as num?)?.toInt() ?? 0;
    final anchor = (cmd['anchor'] as String?)?.trim();
    final tab = (cmd['tab'] as num?)?.toInt();
    final headline = (cmd['headline'] as String? ?? '').trim();
    final say = (cmd['say'] as String? ?? '').trim();
    final commands = ref.parent; // users/{uid}/app_commands
    final ackRef = commands.doc('ack');
    final eventRef = commands.doc('tour_event');

    Future<void> ack(bool ok) async {
      await ackRef
          .set(<String, dynamic>{
            'id': id,
            'ok': ok,
            if (!ok) 'reason': 'anchor_absent',
            'ts': FieldValue.serverTimestamp(),
          })
          .catchError((_) {});
      await _deleteIfStillCommand(ref, id);
    }

    void event(String name) {
      // Surface a failed write (don't swallow it): a silently-denied tour_event
      // write — e.g. a missing Firestore rule for the doc — is exactly what hung
      // the tour with no trace (founder/Scout, 2026-11-03). The tour degrades
      // honestly (advance_guided_tour times out), but the log makes the cause
      // obvious instead of invisible.
      eventRef
          .set(<String, dynamic>{
            'index': index,
            'event': name,
            'ts': FieldValue.serverTimestamp(),
          })
          .catchError((Object e) {
            debugPrint(
              'Ayma tour_event "$name" (step $index) write failed: $e',
            );
          });
    }

    // Starting a driven tour takes over the screen — close any passive
    // coach-mark tour that happens to be up (e.g. a first-run walkthrough) so
    // the two never fight over the overlay.
    TourController.instance.finish();
    final guided = GuidedTourController.instance;
    guided.show(
      GuidedTourStep(
        token: id,
        feature: TourFeature(
          featureId: 'guided_tour_step_$index',
          headline: headline,
          subtitle: say,
          anchorId: (anchor == null || anchor.isEmpty) ? null : anchor,
          tab: tab,
          // The composer step is the text box the user is meant to type in; it
          // must stay focusable for the whole step instead of advancing on every
          // tap inside the spotlight (Scout note 118 leg 4).
          typingAllowed: anchor == TourAnchors.homeComposer,
        ),
        index: index,
        total: total,
        onShown: () => unawaited(ack(true)),
        // Anchor not present: ack so the backend skips the step, and clear the
        // spotlight — but keep the SESSION active (the backend sends the next
        // step), so the passive tour can't slip in during the gap.
        onAbsent: () {
          guided.clearStep();
          unawaited(ack(false));
        },
        // The ONLY thing that advances a step: the user's real tap on the
        // spotlighted control (the press-through). It writes the tap event the
        // backend's advance_guided_tour consumes, clears this step's spotlight
        // (session stays active until tour_end), and KICKS a model turn so the
        // tour advances even if no blocking advance_guided_tour happened to be
        // mid-wait at tap time (founder/Scout live failure, 2026-11-03).
        onTapped: () {
          event('tapped');
          guided.clearStep();
          _kickTourAdvance(index);
        },
        // The "Skip tour" affordance ends the whole session.
        onStop: () {
          event('stop');
          guided.endSession();
          _kickTourStop(index);
        },
      ),
    );
  }

  /// Execute one `go_back` command and ack it with the outcome: `ok`,
  /// the outcome `kind`, the sayable line (`result` when it worked,
  /// `reason` when it honestly didn't), and the current/previous page
  /// labels after the step — the backend's `go_back` tool relays exactly
  /// this, so Ayma never claims a back that didn't happen.
  Future<void> _runGoBackCommand(
    DocumentReference<Map<String, dynamic>> ref,
    String id,
  ) async {
    final out = await runGoBack();
    await ref.parent
        .doc('ack')
        .set(<String, dynamic>{
          'id': id,
          'ok': out.ok,
          'kind': out.kind.name,
          if (out.ok) 'result': out.message else 'reason': out.message,
          'current': _history.current?.label ?? '',
          'previous': _history.previous?.label ?? '',
          'ts': FieldValue.serverTimestamp(),
        })
        .catchError((_) {});
    await _deleteIfStillCommand(ref, id);
  }

  /// One "go back" step (founder feedback item 15), in the order a user's
  /// own back press would resolve it:
  /// 1. a tour overlay is up — do NOT navigate or dismiss anything; the
  ///    tour owns the screen until it finishes or is skipped;
  /// 2. a modal/sheet is up — dismiss it and stay on the page (the
  ///    history is untouched; the NEXT go-back leaves the page);
  /// 3. otherwise unwind one history step and navigate to the page that
  ///    surfaces — whether the user got there themselves or Ayma took
  ///    them there, both are recorded in the one stack;
  /// 4. at the root there is nowhere to go: a graceful, sayable outcome,
  ///    never a silent failure and never an app exit.
  @visibleForTesting
  Future<GoBackOutcome> runGoBack() async {
    if (_tourActive()) {
      return GoBackOutcome.tourActive();
    }
    if (_popupOpen()) {
      var dismissed = false;
      try {
        dismissed = await _dismissPopup();
      } catch (_) {
        dismissed = false;
      }
      if (dismissed) {
        return GoBackOutcome.dismissedModal(
          currentLabel: _history.current?.label,
        );
      }
    }
    final target = _history.takeBackTarget();
    if (target == null) {
      return GoBackOutcome.atRoot(currentLabel: _history.current?.label);
    }
    // The history already sits on the target (takeBackTarget popped to
    // it), so this navigates WITHOUT recording a new visit — the router
    // listener's own record of the landing dedupes/unwinds consistently.
    if (_currentPath() != target.path) _navigate(target.path);
    return GoBackOutcome.navigated(target);
  }

  /// Runs one `ui_action` command; any failure is reported, never thrown.
  @visibleForTesting
  Future<UiActionResult> runUiAction(Map<String, dynamic> cmd) async {
    try {
      return await _uiAction(cmd);
    } catch (e) {
      debugPrint('Ayma ui_action failed: $e');
      return const UiActionResult.refused('the app could not do that');
    }
  }

  /// Once Explore finishes loading the searched feed, add its on-screen
  /// summary to the ack doc (same id) so `search_explore` can return what the
  /// user actually sees. Needs no extra Firestore rule: `ack` is already
  /// client-writable.
  void _listenForExploreReport(DocumentReference<Map<String, dynamic>> ackRef) {
    if (_reportListening) return;
    _reportListening = true;
    AppContext.instance.exploreReport.addListener(() {
      final report = AppContext.instance.exploreReport.value;
      if (report == null || _awaitingExploreId.isEmpty) return;
      if (report.query != _awaitingExploreQuery) return;
      final id = _awaitingExploreId;
      _awaitingExploreId = '';
      ackRef
          .set(<String, dynamic>{
            'id': id,
            'result': report.summary,
          }, SetOptions(merge: true))
          .catchError((_) {});
    });
  }

  bool _isStale(Map<String, dynamic> cmd) {
    final ts = cmd['ts'];
    if (ts is! Timestamp) return false;
    // Device clock vs server timestamp — seconds-level skew is fine here; a
    // clock far ahead only widens the window, never blocks fresh commands.
    return DateTime.now().difference(ts.toDate()) > _staleAfter;
  }

  /// Delete the pending doc only if it still holds the command we just
  /// handled — a blind delete could swallow a newer command that landed
  /// between our snapshot and the delete.
  Future<void> _deleteIfStillCommand(
    DocumentReference<Map<String, dynamic>> ref,
    String id,
  ) {
    return _db
        .runTransaction((tx) async {
          final cur = await tx.get(ref);
          if (((cur.data()?['id'] as String?) ?? '') == id) tx.delete(ref);
        })
        .catchError((_) {});
  }

  /// Route one command; true when it actually executed a navigation/action
  /// (what the ack's `ok` reports back to the waiting backend tool). Split
  /// out so it's testable without Firestore.
  @visibleForTesting
  bool handleCommand(Map<String, dynamic> cmd) {
    switch (cmd['action'] as String? ?? '') {
      case 'navigate':
        // The backend resolved this from the registry
        // (functions/bootstrap/app_registry.json); test/app_registry_test.dart
        // checks every registered path against the real router.
        final path = (cmd['path'] as String? ?? '').trim();
        if (!path.startsWith('/')) return false;
        _open(path);
        return true;
      case 'search_explore':
        AppContext.instance.pendingExploreQuery =
            (cmd['query'] as String? ?? '').trim();
        // Through [_open], not a bare push, like every other navigation
        // command: the destination must be visible, never left underneath
        // a still-open chat popup. (The live-query publish that also rode
        // with this case on the old staging line is part of the v2 live
        // UI updates feature and is intentionally not carried here.)
        _open(ExploreScreen.path);
        return true;
      case 'open_profile':
        final uid = (cmd['uid'] as String? ?? '').trim();
        if (uid.isEmpty) return false;
        _open('/profile/user/$uid');
        return true;
      case 'open_dm_thread':
        final uid = (cmd['uid'] as String? ?? '').trim();
        if (uid.isEmpty) return false;
        final me = _auth.currentUser?.uid;
        if (me == null || me.isEmpty) return false;
        // Through [_open], not a bare push (founder feedback item 6,
        // 2026-11-06: the opened conversation bounced straight back to the
        // conversations page): a bare push stacks the thread ON TOP of
        // Ayma's still-open chat popup, and the next popup-close pop —
        // which pops the top route assuming it is the popup — kills the
        // thread route instead. [_open] closes the popup first and skips
        // the push when the user is already on this thread, exactly like
        // the `navigate` and `open_notification` cases.
        _open('/dm/${sortedPairKey(me, uid)}');
        return true;
      case 'open_notification':
        // The backend already picked the latest unread notification and hands
        // over its `deep_link`; route it exactly like a notification-centre
        // tap (same `deepLinkToRoute`, same popup-close-then-push). Read
        // state stays the backend's job: it marks it read only once this
        // open acks (§ L6: one ask opens the destination directly).
        final link = (cmd['deep_link'] as String? ?? '').trim();
        if (link.isEmpty) return false;
        final self = _auth.currentUser?.uid;
        if (self == null || self.isEmpty) return false;
        _open(deepLinkToRoute(link, myUid: self));
        return true;
      case 'app_action':
        return _handleAppAction(
          (cmd['name'] as String? ?? '').trim(),
          (cmd['value'] as String? ?? '').trim(),
        );
      case 'reconnect_voice':
        // Apply a just-saved model stack (brain/voice/mode/model) to the live
        // call. Ack `true` only when a call is actually live, then do the
        // stop+start AFTER the ack (via `_afterAck`) so the backend tool can
        // confirm and Ayma's spoken "reconnecting" plays before the room drops.
        // No live call → `false`, and the backend tool tells the user it will
        // apply on their next call (`skills/set_model_stack.reconnect_voice`).
        if (!_hasActiveVoice()) return false;
        // Circuit breaker against an infinite reconnect loop (founder
        // 2026-11-03): the reconnected session is re-seeded with the "reconnect"
        // transcript, so the agent can re-fire reconnect_voice. Refuse a second
        // reconnect within the cooldown — this bounds LiveKit-minute burn on the
        // device even if the backend one-shot guard ever misses. Instance state
        // on the shared singleton, which survives the stop+start.
        final last = _lastReconnectAt;
        if (last != null &&
            DateTime.now().difference(last) < _reconnectCooldown) {
          return false;
        }
        _lastReconnectAt = DateTime.now();
        _afterAck = _reconnectVoice;
        return true;
      case 'go_back':
        // Async-owned (see _onDoc / _runGoBackCommand): the sync
        // dispatcher cannot await a modal dismissal, so it refuses here
        // rather than half-running the step.
        return false;
      case 'tour_end':
        // (clears the spotlight and lets the passive tour resume its normal
        // gating). Always acks ok (there's nothing that can fail).
        GuidedTourController.instance.endSession();
        return true;
    }
    return false;
  }

  /// Push [path] unless the user is already there, closing Ayma's chat
  /// popup first when it is open (e.g. the DM thread opened after Ayma sent
  /// a message from the popup chat). Every Ayma page-navigation command
  /// goes through here (`navigate`, `open_notification`, `search_explore`,
  /// `open_profile`, `open_dm_thread`), so no command can land its page
  /// invisibly underneath a still-open sheet, partial or expanded. When
  /// the user is already on [path] there is no navigation to make, but an
  /// open sheet is still dismissed — the destination being visible is the
  /// point — and that dismissal is not itself a page navigation (it
  /// records no route or go-back entry).
  void _open(String path) {
    if (_currentPath() == path) {
      if (_chatPopupOpen()) {
        unawaited(_closeChatPopup().catchError((Object e) {
          debugPrint('Ayma sheet dismissal on a same-page navigation '
              'failed: $e');
        }));
      }
      return;
    }
    if (!_chatPopupOpen()) {
      _navigate(path);
      _history.visit(path);
      return;
    }
    unawaited(
      _closeChatPopup()
          .then((_) {
            if (_currentPath() != path) {
              _navigate(path);
              _history.visit(path);
            }
          })
          .catchError((Object e) {
            debugPrint(
              'Ayma navigation after closing the chat popup failed: $e',
            );
          }),
    );
  }

  /// The registry's client-held settings and the confirmed sign out
  /// (`skills/app_control.py` sends these names). Each setting calls the
  /// exact method its screen's control already calls, never a raw widget
  /// tap. An unrecognised name or value is a no-op (false), matching the
  /// backend's own validation.
  bool _handleAppAction(String name, String value) {
    switch (name) {
      case 'dark_mode':
        _theme.set(ThemeMode.dark);
        return true;
      case 'light_mode':
        _theme.set(ThemeMode.light);
        return true;
      case 'system_theme':
        _theme.set(ThemeMode.system);
        return true;
      case 'accent_color':
        if (value == 'default') {
          _accent.resetToDefault();
          return true;
        }
        final color = AccentColorController.parseHex(value);
        if (color == null) return false;
        _accent.set(color);
        return true;
      case 'pause_matching':
        _profiles.setPaused(true).catchError((_) {});
        return true;
      case 'resume_matching':
        _profiles.setPaused(false).catchError((_) {});
        return true;
      case 'wing_flutter':
        final on = _onOff(value);
        if (on == null) return false;
        _orbAnim.setFlutterEnabled(on);
        return true;
      case 'nav_bar_flutter':
        final on = _onOff(value);
        if (on == null) return false;
        _orbAnim.setNavBarFlutterEnabled(on);
        return true;
      case 'sign_out':
        _afterAck = _signOut;
        return true;
    }
    return false;
  }

  static bool? _onOff(String value) => switch (value) {
    'on' => true,
    'off' => false,
    _ => null,
  };

  /// The same steps as the You tab's "Sign out" row.
  Future<void> _signOut() async {
    try {
      await (_clearPushTokenOverride ?? PushService().clearToken)();
      await _auth.signOut();
      _history.clear(); // session-scoped: the next session starts fresh
      _go(SignInScreen.path);
    } catch (e) {
      debugPrint('Ayma-requested sign-out failed: $e');
    }
  }

  /// Runs the sign out a just-handled command queued, as `_onDoc`
  /// does once the ack is written.
  @visibleForTesting
  Future<void> runAfterAck() async {
    final after = _afterAck;
    _afterAck = null;
    if (after != null) await after();
  }
}
/// How one `go_back` step resolved (see [AppCommandService.runGoBack]).
enum GoBackKind { navigated, dismissedModal, atRoot, tourActive }

/// The outcome of one `go_back` step: whether it did anything ([ok]),
/// which way it resolved ([kind]) and the sayable line Ayma relays
/// ([message]). At the root and during a tour, [ok] is false but the
/// message is the graceful answer itself — never a silent failure.
class GoBackOutcome {
  const GoBackOutcome._(this.kind, this.message);

  factory GoBackOutcome.navigated(NavPageEntry target) =>
      GoBackOutcome._(GoBackKind.navigated, 'Went back to ${target.label}.');

  factory GoBackOutcome.dismissedModal({String? currentLabel}) =>
      GoBackOutcome._(
        GoBackKind.dismissedModal,
        currentLabel == null
            ? 'Closed that first.'
            : 'Closed that first — you are still on $currentLabel.',
      );

  factory GoBackOutcome.atRoot({String? currentLabel}) => GoBackOutcome._(
    GoBackKind.atRoot,
    currentLabel == null
        ? "There's nowhere to go back to."
        : "There's nowhere to go back to — you're on $currentLabel, "
              "and that's the first page of this session.",
  );

  factory GoBackOutcome.tourActive() => const GoBackOutcome._(
    GoBackKind.tourActive,
    "A tour is showing right now, so I didn't go back — finish or "
    'skip the tour first, then ask me again.',
  );

  final GoBackKind kind;
  final String message;

  bool get ok =>
      kind == GoBackKind.navigated || kind == GoBackKind.dismissedModal;
}
