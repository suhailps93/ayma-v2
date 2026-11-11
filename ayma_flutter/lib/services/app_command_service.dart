import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../routing/app_router.dart';
import '../screens/explore_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/sign_in_screen.dart';
import '../widgets/ask_ayma_overlay.dart';
import 'accent_color_controller.dart';
import 'api_client.dart';
import 'app_context.dart';
import 'guided_tour_controller.dart';
import 'inbox_actions.dart';
import 'navigation_history.dart';
import 'notification_service.dart';
import 'pair_key.dart';
import 'photo_carousel_registry.dart';
import 'profile_service.dart';
import 'push_service.dart';
import 'screen_capture.dart';
import 'theme_controller.dart';
import 'tab_request.dart';
import 'tour_anchors.dart';
import 'tour_content.dart';
import 'tour_controller.dart';
import 'voice_clip_playback.dart';
import 'voice_clip_registry.dart';
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
/// * `play_voice_clip` — play a voice clip from the open Ayma chat
///   ([VoiceClipRegistry] / [VoiceClipPlayback]; founder feedback items
///   7+8, 2026-11-06: Ayma said "I can't play it" because no such command
///   existed). It owns its ack like `ui_action`: the ack lands once
///   playback has started, reporting whether a live voice session was
///   disconnected to play the clip (the session reconnects, with
///   context, when the clip finishes).
/// * the inbox actions — `mark_all_notifications_read`,
///   `clear_all_notifications` and `mark_all_conversations_read`
///   ([InboxActions]; founder feedback
///   items 9–11, 2026-11-06: the buttons existed on the Notifications
///   page but Ayma had no commands for them). They own their acks like
///   `play_voice_clip`: the ack carries the count that actually moved.
/// * `carousel_photo` — move WITHIN the currently open profile's photo
///   carousel (`op`: `goto` with a 1-based `index` as users speak it,
///   `next`, `previous`), through [PhotoCarouselRegistry] — the handle the
///   mounted `ProfilePhotoHeader` registers for its `PageController`,
///   the same singleton-slot shape as `AppContext.pendingExploreQuery`.
///   It owns its ack (like `ui_action`): the ack carries `photo_count`
///   and `current_photo` either way, so an out-of-range ask ("photo 5"
///   of 3) acks `ok:false` with the real count and Ayma can say there
///   are only that many — the carousel does not move.
class AppCommandService {
  AppCommandService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    void Function(String path)? navigate,
    void Function(String path)? go,
    ThemeController? themeController,
    ProfileService? profileService,
    AccentColorController? accentController,
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
    VoiceClipRegistry? clipRegistry,
    VoiceClipPlayback? clipPlayback,
    InboxActions? inboxActions,
    PhotoCarouselRegistry? photoCarousel,
  })  : _inboxActions = inboxActions ?? InboxActions(),
        _clipRegistry = clipRegistry ?? VoiceClipRegistry.instance,
        _clipPlayback = clipPlayback ?? VoiceClipPlayback(),
        _photoCarousel = photoCarousel ?? PhotoCarouselRegistry.instance,
        _sendTourContinuation = sendTourContinuation ?? _postTourContinuation,
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
  final Future<void> Function()? _clearPushTokenOverride;
  final Future<UiActionResult> Function(Map<String, dynamic> cmd) _uiAction;

  /// The photo carousel currently on screen, reached through its
  /// registered handle (see [PhotoCarouselRegistry]). Injectable for
  /// tests; the default is the process-wide registry the mounted
  /// `ProfilePhotoHeader` registers itself into.
  final PhotoCarouselRegistry _photoCarousel;

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

  /// The one-line tour-response signal the model reads as "the user
  /// responded to the step — advance." A fixed control signal, not a
  /// persona/prompt template (it is never persisted; the backend drops it
  /// via `tour_continuation`).
  static const _tourTapSignal =
      'The user just responded to the highlighted step in the guided tour. '
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

  /// When each tour kick last fired, keyed by the `tour_event` it belongs
  /// to (`index|kind|attempt`) on [_tourKickClock]'s monotonic clock.
  final Map<String, int> _tourKickAt = <String, int>{};
  final Stopwatch _tourKickClock = Stopwatch()..start();

  /// How long an identical tour kick is treated as the SAME response. One
  /// physical response can surface through two paths (the tap itself and
  /// the state the tap produced), and both used to kick a fresh model turn:
  /// the second made Ayma abandon the line she was speaking and start over
  /// (founder, 2026-11-09). The `tour_event` doc persists either way, so
  /// the one surviving narration turn (or a blocking `advance_guided_tour`
  /// already waiting on it) still consumes it exactly once.
  static const _tourKickCoalesceMs = 5000;

  /// Bridge a tour response to a model-narrated turn (§11.2b): on voice,
  /// tell the live agent (data channel → `generate_reply`); otherwise fire the
  /// TEXT `/chat` continuation. Either way the model calls `advance_guided_tour`,
  /// which consumes the already-written `tour_event` and narrates/spotlights the
  /// next step — no dependence on a blocking advance being alive at tap time.
  /// Identical kicks for the same response ([kind] + [attempt]) inside the
  /// coalesce window are dropped (see [_tourKickCoalesceMs]).
  void _kickTourAdvance(int index, {required String kind, int? attempt}) {
    final key = '$index|$kind|${attempt ?? ''}';
    final now = _tourKickClock.elapsedMilliseconds;
    final last = _tourKickAt[key];
    if (last != null && now - last < _tourKickCoalesceMs) return;
    _tourKickAt[key] = now;
    final voice = VoiceSessionController.active;
    if (voice != null && voice.isActive) {
      unawaited(voice.notifyTourTapped(index: index, attempt: attempt));
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

  /// The backend's `tour_state` doc for the running driven tour, captured
  /// from the first `tour_step` command (see [_watchTourState]).
  DocumentReference<Map<String, dynamic>>? _tourStateRef;
  bool _tourStateListenerOn = false;
  DateTime? _lastTourStateCheck;

  /// How stale the backend `tour_state` may be before the client treats
  /// the tour as over on its own — mirrors the backend's own TTL
  /// (`_TOUR_STATE_TTL_SECONDS` in skills/guided_tour.py).
  static const _tourStateTtl = Duration(minutes: 15);

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
    GuidedTourController.instance.setVoiceOnly(true);
    _listen();
  }

  /// The voice session ended; keeps listening if the app is foregrounded.
  Future<void> stop() async {
    _voiceActive = false;
    GuidedTourController.instance.setVoiceOnly(false);
    await _detachIfUnwanted();
  }

  /// The app moved to/from the foreground (text chat can drive the app too).
  Future<void> setForeground(bool foreground) async {
    _foreground = foreground;
    if (foreground) {
      // Back in front: if the tour ended server-side while we were away,
      // its overlay must not still be standing there.
      unawaited(checkTourState());
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

  /// Keep one eye on the backend's `tour_state` while a driven tour is up.
  ///
  /// TEARDOWN GUARANTEE (founder, 2026-11-09): a tour that ends server-side
  /// must ALWAYS take its overlay — card included — down with it. The
  /// `tour_end` command alone is not that guarantee: `pending` is a single
  /// slot the next command overwrites, so an end queued behind other
  /// traffic can be lost unseen, and a tour state can simply expire (the
  /// backend's own 15-minute TTL) while the app sits open. Either used to
  /// leave the last step's card on screen forever. This check runs when
  /// the app returns to the foreground, when the screen changes, and when
  /// an unrelated command arrives, and it ends the local session only when
  /// the state actually says the tour is over (inactive, or stale past
  /// the TTL). A failed read never tears anything down.
  void _watchTourState(DocumentReference<Map<String, dynamic>> stateRef) {
    _tourStateRef = stateRef;
    if (_tourStateListenerOn) return;
    _tourStateListenerOn = true;
    AppContext.instance.current.addListener(_onScreenChangedForTour);
  }

  void _onScreenChangedForTour() {
    if (!GuidedTourController.instance.sessionActive) {
      AppContext.instance.current.removeListener(_onScreenChangedForTour);
      _tourStateListenerOn = false;
      _tourStateRef = null;
      return;
    }
    final last = _lastTourStateCheck;
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastTourStateCheck = now;
    unawaited(checkTourState());
  }

  /// One teardown check against the backend's `tour_state` (see
  /// [_watchTourState]). A no-op unless a driven session is up and a state
  /// ref was captured from a `tour_step`.
  @visibleForTesting
  Future<void> checkTourState() async {
    final guided = GuidedTourController.instance;
    if (!guided.sessionActive) return;
    final ref = _tourStateRef;
    if (ref == null) return;
    Map<String, dynamic>? data;
    try {
      data = (await ref.get()).data();
    } catch (_) {
      return; // unreadable is not "over" — never tear down on a guess
    }
    if (data == null) return;
    var over = data['active'] != true;
    final updated = data['updated_at'];
    if (!over &&
        updated is Timestamp &&
        DateTime.now().difference(updated.toDate()) > _tourStateTtl) {
      over = true;
    }
    if (over) guided.endSession();
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
    if (data['action'] != 'tour_step' && data['action'] != 'tour_end') {
      // A live tour whose backend state has moved on (ended / expired)
      // must not outlive the next unrelated command — its card included.
      unawaited(checkTourState());
    }
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
    if (data['action'] == 'set_notification_filter') {
      // Owns its ack like go_back: the ack carries the filter it
      // replaced, which the backend (and its self-check restore) needs
      // because the filter lives only in this client's shared state.
      unawaited(_runInboxCommand(snap.reference, data, id));
      return;
    }
    if (data['action'] == 'play_voice_clip') {
      // Playback owns its ack (like ui_action): it can only ack once it
      // knows whether the clip actually started — and, on a live call,
      // the disconnect-then-play sequence has begun.
      unawaited(_runPlayVoiceClipCommand(snap.reference, data, id));
      return;
    }
    if (data['action'] == 'mark_all_notifications_read' ||
        data['action'] == 'clear_all_notifications' ||
        data['action'] == 'mark_all_conversations_read') {
      // Inbox actions own their acks (like play_voice_clip): the ack
      // reports the count that actually moved, not a bare ok.
      unawaited(_runInboxCommand(snap.reference, data, id));
      return;
    }
    if (data['action'] == 'carousel_photo') {
      // Owns its ack, like ui_action: the ack must carry the real photo
      // count either way, so the backend tool can tell the user how many
      // photos there actually are when the ask was out of range.
      unawaited(_runCarouselPhoto(snap.reference, data, id));
      return;
    }
    if (data['action'] == 'tour_step') {
      // The Ayma-driven tour spotlights one step and acks it only once the
      // overlay reports it shown (or its anchor absent), then waits for the
      // user's response on a separate `tour_event` doc — so it owns its ack,
      // like ui_action (§11.2b).
      _runTourStep(snap.reference, data, id);
      return;
    }
    if (_navigationActions.contains(data['action'])) {
      // Owns its ack (like go_back / ui_action): the ack is written only
      // once the open has actually landed — destination current, no
      // sheet left covering it — never on dispatch alone.
      unawaited(_runNavigationCommand(snap.reference, data, id));
      return;
    }
    var ok = false;
    try {
      ok = handleCommand(data);
    } catch (_) {
      ok = false; // ack the failure honestly rather than crash the stream
    }
    _settleCommand(snap.reference, data, id, ok);
  }

  /// The page-opening commands (the registry destinations and the
  /// person / thread / notification opens). They own their acks: an
  /// ack written on dispatch alone can claim success for a page that
  /// never became visible, so these route to [_runNavigationCommand].
  static const _navigationActions = <String>{
    'navigate',
    'search_explore',
    'open_profile',
    'open_dm_thread',
    'open_notification',
  };

  /// How long a page-opening command may take to land before it acks
  /// `false` (a sheet dismissal that never completes must not hold the
  /// ack — and the backend's wait — hostage).
  static const _navigationAckCap = Duration(seconds: 10);

  /// Ack [id] with the command's real outcome, clear the pending doc
  /// and run any after-ack action — the tail every command path shares
  /// (the sync dispatcher above and the ack-owning runners). The ack is
  /// written first (the backend tool is polling for this id right now),
  /// then the pending doc is cleared.
  void _settleCommand(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> data,
    String id,
    bool ok,
  ) {
    final acked = ref.parent
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
      _listenForExploreReport(ref.parent.doc('ack'));
    }
    final cleared = _deleteIfStillCommand(ref, id);
    final after = _afterAck;
    _afterAck = null;
    if (after != null) {
      unawaited(Future.wait([acked, cleared]).then((_) => after()));
    }
  }

  /// Run one page-opening command and ack its REAL outcome: resolve the
  /// target with [_navigationTarget], open it through [openDestination]
  /// (which reports whether the destination actually ended up visible)
  /// and ack that — so a sheet dismissal that failed, or a push that
  /// never landed, acks `ok:false` and Ayma says so honestly, instead
  /// of the old dispatch-only ack claiming success for an invisible
  /// page (the ack path the self-check's nav checks also judge by).
  Future<void> _runNavigationCommand(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, dynamic> cmd,
    String id,
  ) async {
    var ok = false;
    try {
      final target = _navigationTarget(cmd);
      if (target != null) {
        ok = await openDestination(target).timeout(
          _navigationAckCap,
          onTimeout: () => false,
        );
      }
    } catch (_) {
      ok = false; // ack the failure honestly rather than crash the stream
    }
    _settleCommand(ref, cmd, id, ok);
  }

  /// Move the open profile's photo carousel, then ack with the outcome
  /// AND the real photo count: `photo_count` / `current_photo` ride along
  /// on success and on failure, so "show photo 5" on a 3-photo profile
  /// acks `ok:false, reason: out_of_range, photo_count: 3` and Ayma says
  /// there are only 3 — the carousel itself never moved.
  Future<void> _runCarouselPhoto(DocumentReference<Map<String, dynamic>> ref,
      Map<String, dynamic> cmd, String id) async {
    final out = await runCarouselPhotoConfirmed(cmd);
    await ref.parent.doc('ack').set(<String, dynamic>{
      'id': id,
      'ok': out.ok,
      'photo_count': out.photoCount,
      'current_photo': out.currentPhoto,
      if (out.requestedPhoto != null) 'requested_photo': out.requestedPhoto,
      'result': out.resultText,
      if (!out.ok) 'reason': out.reason,
      'ts': FieldValue.serverTimestamp(),
    }).catchError((_) {});
    await _deleteIfStillCommand(ref, id);
  }

  /// The ack delay before a carousel move is re-read for the landing
  /// confirmation: the header animates a page change over 250ms, so the
  /// re-read waits comfortably past the animation.
  static const _carouselConfirmDelay = Duration(milliseconds: 500);

  /// [runCarouselPhoto] plus a landing confirmation, so the ack means
  /// the photo is actually SHOWING — the same standard the navigation
  /// commands hold (founder, 2026-11-07: an open counts only when it
  /// lands). The registry reports a move the moment the page animation
  /// is DISPATCHED; if the controller was detached the header silently
  /// keeps the old page while the result claims the new one. After the
  /// animation window the live page is re-read: a mismatch (or the
  /// carousel having vanished) rewrites the outcome to
  /// `ok: false, reason: not_landed` with the page that is really
  /// showing, so Ayma reports the failure honestly instead of claiming
  /// a photo that never appeared.
  @visibleForTesting
  Future<PhotoCarouselResult> runCarouselPhotoConfirmed(
      Map<String, dynamic> cmd) async {
    final out = runCarouselPhoto(cmd);
    if (!out.ok) return out;
    await Future<void>.delayed(_carouselConfirmDelay);
    final handle = _photoCarousel.active;
    if (handle == null) {
      return PhotoCarouselResult(
        ok: false,
        photoCount: out.photoCount,
        currentPhoto: out.currentPhoto,
        requestedPhoto: out.requestedPhoto,
        reason: 'not_landed',
      );
    }
    final landed = handle.currentPage() + 1;
    if (landed == out.currentPhoto) return out;
    return PhotoCarouselResult(
      ok: false,
      photoCount: out.photoCount,
      currentPhoto: landed,
      requestedPhoto: out.requestedPhoto,
      reason: 'not_landed',
    );
  }

  /// Runs one `carousel_photo` command against the registered carousel;
  /// any failure is reported in the result, never thrown. The command is
  /// `{op: goto|next|previous, index: <1-based, for goto>}` — the index
  /// is 1-based exactly as users speak it ("the third picture" → 3).
  @visibleForTesting
  PhotoCarouselResult runCarouselPhoto(Map<String, dynamic> cmd) {
    try {
      final op = (cmd['op'] as String? ?? 'goto').trim().toLowerCase();
      final rawIndex = cmd['index'] ?? cmd['photo'];
      final index = rawIndex is num
          ? rawIndex.toInt()
          : int.tryParse((rawIndex as String? ?? '').trim());
      return _photoCarousel.perform(op: op, index: index);
    } catch (e) {
      debugPrint('Ayma carousel_photo failed: $e');
      return const PhotoCarouselResult(
        ok: false,
        photoCount: 0,
        currentPhoto: 0,
        reason: 'no_carousel',
      );
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

  /// The registry/playback pair `play_voice_clip` resolves and plays
  /// through. Injectable for tests; the defaults are the process-wide
  /// registry the chat screen publishes to and a playback orchestrator
  /// acting on the live voice session.
  final VoiceClipRegistry _clipRegistry;
  final VoiceClipPlayback _clipPlayback;

  /// Play the voice clip a `play_voice_clip` command names, then ack
  /// with the outcome: `ok`, what is playing (`result`), whether a live
  /// voice session was disconnected to play it (`voice_paused`), or why
  /// nothing played (`reason`).
  Future<void> _runPlayVoiceClipCommand(
      DocumentReference<Map<String, dynamic>> ref,
      Map<String, dynamic> cmd,
      String id) async {
    final out = await runPlayVoiceClip(cmd);
    await ref.parent.doc('ack').set(<String, dynamic>{
      'id': id,
      'ok': out.ok,
      if (out.ok) 'result': out.message else 'reason': out.message,
      if (out.ok) 'voice_paused': out.voicePaused,
      'ts': FieldValue.serverTimestamp(),
    }).catchError((_) {});
    await _deleteIfStillCommand(ref, id);
  }

  /// Resolve and start one `play_voice_clip` command; any failure is
  /// reported, never thrown. The returned [PlaybackStart] completes
  /// once playback has begun — the disconnect/play/reconnect sequence
  /// continues in the background from there.
  @visibleForTesting
  Future<PlaybackStart> runPlayVoiceClip(Map<String, dynamic> cmd) async {
    try {
      final clip =
          _clipRegistry.resolve((cmd['which'] as String? ?? '').trim());
      if (clip == null) {
        return const PlaybackStart.failed(
            'There is no voice clip in this chat to play.');
      }
      final run = _clipPlayback.begin(clip);
      return await run.started;
    } catch (e) {
      debugPrint('Ayma play_voice_clip failed: $e');
      return const PlaybackStart.failed('The clip could not be played.');
    }
  }

  /// The bulk inbox actions `mark_all_notifications_read` and friends
  /// run through. Injectable for tests; the default performs the same
  /// NotificationService / DmService writes the on-screen buttons run.
  final InboxActions _inboxActions;

  /// Run one inbox command, then ack with the outcome: `ok`, plus what
  /// actually happened (`result`) or why nothing did (`reason`).
  Future<void> _runInboxCommand(
      DocumentReference<Map<String, dynamic>> ref,
      Map<String, dynamic> cmd,
      String id) async {
    final out = await runInboxCommand(cmd);
    await ref.parent.doc('ack').set(<String, dynamic>{
      'id': id,
      'ok': out.ok,
      if (out.ok) 'result': out.message else 'reason': out.message,
      'ts': FieldValue.serverTimestamp(),
    }).catchError((_) {});
    await _deleteIfStillCommand(ref, id);
  }

  /// Execute one inbox command; any failure is reported, never thrown.
  @visibleForTesting
  Future<InboxActionResult> runInboxCommand(Map<String, dynamic> cmd) async {
    final action = (cmd['action'] as String? ?? '').trim();
    try {
      switch (action) {
        case 'mark_all_notifications_read':
          final n = await _inboxActions.markAllNotificationsRead();
          return InboxActionResult(
              true,
              n == 0
                  ? 'No unread notifications.'
                  : 'Marked $n notification${n == 1 ? '' : 's'} as read.');
        case 'clear_all_notifications':
          final n = await _inboxActions.clearAllNotifications();
          return InboxActionResult(
              true,
              n == 0
                  ? 'No notifications to clear.'
                  : 'Cleared $n notification${n == 1 ? '' : 's'}.');
        case 'mark_all_conversations_read':
          final n = await _inboxActions.markAllConversationsRead();
          return InboxActionResult(
              true,
              n == 0
                  ? 'No unread conversations.'
                  : 'Marked $n conversation${n == 1 ? '' : 's'} as read.');
        case 'set_notification_filter':
          // The backend self-check needs the filter it replaced so it
          // can restore it afterwards: this client-only state has no
          // other read path, so the previous key rides in the ack line.
          final previous = NotificationFilterState.instance.current.value;
          final filter = NotificationFilter.fromKey(
              (cmd['filter'] as String? ?? '').trim());
          NotificationFilterState.instance.setFilter(filter);
          _navigate(NotificationCenterScreen.path);
          return InboxActionResult(true,
              'Showing ${filter.label} notifications. (was: ${previous.key})');
        default:
          return InboxActionResult(false, 'Unknown inbox action: $action');
      }
    } catch (e) {
      debugPrint('Ayma inbox action $action failed: $e');
      return const InboxActionResult(false, 'That inbox action failed.');
    }
  }

  /// Show one Ayma-driven tour step (§11.2b) and wire its reports back to the
  /// backend: ack `ok:true` once spotlighted, ack `ok:false` (anchor absent) so
  /// the backend skips it, and report the user's response on `tour_event`,
  /// which the backend's `advance_guided_tour` polls: the confirmed outcome
  /// of the step's command (`performed` / `action_failed`), a tap on a step
  /// with nothing to perform (`tapped`), Next (`skip`) or "Skip tour" (`stop`).
  /// A step WITH a command is performed by Ayma the moment it is shown —
  /// never on the user's tap (founder, 2026-11-08/09) — and a step whose
  /// goal state is already true completes from the state instead.
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
    final stepRoute = (cmd['route'] as String? ?? '').trim();
    final headline = (cmd['headline'] as String? ?? '').trim();
    final say = (cmd['say'] as String? ?? '').trim();
    final commands = ref.parent; // users/{uid}/app_commands
    final ackRef = commands.doc('ack');
    final eventRef = commands.doc('tour_event');
    _watchTourState(commands.doc('tour_state'));

    Future<void> ack(bool ok, {String? reason}) async {
      final cur = AppContext.instance.current.value;
      await ackRef
          .set(<String, dynamic>{
            'id': id,
            'ok': ok,
            if (!ok) 'reason': reason ?? 'anchor_absent',
            // Where the user actually is — read back by the backend when
            // it decides how to get them to the step's screen.
            'screen': cur.screen,
            'route': cur.route,
            'ts': FieldValue.serverTimestamp(),
          })
          .catchError((_) {});
      await _deleteIfStillCommand(ref, id);
    }

    void event(String name, {int? attempt}) {
      // Surface a failed write (don't swallow it): a silently-denied tour_event
      // write — e.g. a missing Firestore rule for the doc — is exactly what hung
      // the tour with no trace (founder/Scout, 2026-11-03). The tour degrades
      // honestly (advance_guided_tour times out), but the log makes the cause
      // obvious instead of invisible.
      eventRef
          .set(<String, dynamic>{
            'index': index,
            'event': name,
            if (attempt != null) 'attempt': attempt,
            'ts': FieldValue.serverTimestamp(),
          })
          .catchError((Object e) {
            debugPrint(
              'Ayma tour_event "$name" (step $index) write failed: $e',
            );
          });
    }

    // LOOK BEFORE HIGHLIGHTING (rewire, founder 2026-11-07): the step is
    // shown ONLY when the user is on the step's screen right now — a tab
    // step needs its tab in front, a pushed-page step needs its route in
    // front, a shell-level step (orb, bell) needs the shell uncovered. An
    // unknown screen (pre-capture) falls through to the anchor, which
    // still gates the ack through the overlay's measure.
    bool onStepScreen() {
      final cur = AppContext.instance.current.value;
      final slug = cur.screen;
      if (slug.isEmpty) return true;
      if (tab != null) {
        return tab >= 0 && tab < _tabSlugs.length && slug == _tabSlugs[tab];
      }
      if (stepRoute.isNotEmpty) return cur.route == stepRoute;
      return _tabSlugs.contains(slug) &&
          (cur.route.isEmpty || cur.route == '/');
    }

    // A page explainer step (§11.2c) only explains: it never carries an
    // action to run, whatever the command says.
    final explainer = cmd['explainer'] == true;
    final command =
        explainer ? null : (cmd['command'] as Map?)?.cast<String, dynamic>();
    final guided = GuidedTourController.instance;
    var attempt = 0;
    var inFlight = false;
    var performed = false;

    // STATE-BASED COMPLETION (founder, 2026-11-09 — "fix this for once and
    // for all. No repeat"): a step with a command is complete when the app
    // LOOKS the way the command would leave it — the destination route is
    // the current one, or the shell sits on the command's tab — however it
    // got that way. Completion used to depend on the overlay intercepting
    // one tap on the highlight, so a user who did exactly what Ayma asked
    // by tapping the REAL bell (Notifications opened) left the tour
    // insisting nothing had happened: that tap never reached the tour.
    bool goalReached() {
      final c = command;
      if (c == null) return false;
      if (c['action'] == 'switch_tab') {
        final t = (c['tab'] as num?)?.toInt() ?? -1;
        return t >= 0 &&
            t < _tabSlugs.length &&
            AppContext.instance.current.value.screen == _tabSlugs[t];
      }
      final target = _navigationTarget(c);
      if (target == null) return false;
      final bare = target.split('?').first;
      return bare.isNotEmpty && _currentPath() == bare;
    }

    // The one outcome report every completion path shares: the confirmed
    // outcome on `tour_event`, and the step resting as performed/failed
    // until the user's go.
    void reportOutcome(bool ok) {
      event(ok ? 'performed' : 'action_failed', attempt: attempt);
      final go = _hasActiveVoice() ? 'say next' : 'tap Next';
      guided.recordOutcome(
        id,
        performed: ok,
        notice: ok
            ? "Have a look. When you're ready, $go."
            : "That didn't open. Tap the highlight to try again, or $go to "
                'move on.',
      );
      if (_hasActiveVoice()) {
        _kickTourAdvance(
          index,
          kind: ok ? 'performed' : 'action_failed',
          attempt: attempt,
        );
      }
    }

    // The step's goal turned true WITHOUT the tour performing it — the
    // user did it themselves. Complete the step from the state, with the
    // same bookkeeping as a performed tap (one attempt, one event).
    void completeFromState() {
      if (inFlight || performed || !guided.isShowing(id)) return;
      performed = true;
      attempt++;
      reportOutcome(true);
    }

    // Ayma performs the step: run its command, report the confirmed outcome
    // and stay on the step. Only the user's go moves the tour. On a call the
    // live agent is told so she can say so; in text the card already does.
    Future<void> perform(Map<String, dynamic> stepCommand) async {
      final ok = await runTourCommand(stepCommand);
      inFlight = false;
      if (!guided.isShowing(id)) return; // the user moved on meanwhile
      performed = ok;
      reportOutcome(ok);
    }

    // Start the step's performance, at most one attempt in flight and never
    // again once performed (by Ayma, or from the state via completeFromState
    // — both latch [performed]). Fired from presentation (onShown): Ayma
    // handles the tap herself, so the tour never waits on a user tap for
    // her to act (founder, 2026-11-09). The one later trigger admitted is a
    // tap after a FAILED attempt (the retry the failure notice offers) —
    // every other tap is a no-op here.
    void startPerform() {
      final stepCommand = command;
      if (stepCommand == null || inFlight || performed) return;
      inFlight = true;
      attempt++;
      unawaited(perform(stepCommand));
    }

    // While this step is up, follow the app's ACTUAL state: AppContext
    // republishes on every screen/route change, which is exactly when a
    // step's goal may have become true — so each republication re-checks
    // the goal, and the step completes the moment it is true, whoever
    // made it true. For an explainer step (nothing to perform; page-scoped
    // by construction) the same watch is the leave-page teardown: a user
    // who leaves the explained page for good ends the explainer instead
    // of leaving its card standing over another page. The watch removes
    // itself when the step leaves the screen or is performed.
    void watchGoal() {
      if (command == null && !explainer) return;
      var offPagePublishes = 0;
      void check() {
        if (!guided.isShowing(id) || performed) {
          AppContext.instance.current.removeListener(check);
          return;
        }
        if (command != null) {
          if (!inFlight && goalReached()) {
            AppContext.instance.current.removeListener(check);
            completeFromState();
          }
          return;
        }
        // Explainer: the page it explains is gone — and stays gone (two
        // consecutive off-page publications: the leave itself and the
        // landing after it, never a single transitional frame). The
        // sequence is over, exactly as the backend treats a blocked
        // explainer on a left page. Report the stop so Ayma ends it her
        // side too, and take the card down here and now.
        if (onStepScreen()) {
          offPagePublishes = 0;
          return;
        }
        if (++offPagePublishes >= 2) {
          AppContext.instance.current.removeListener(check);
          event('stop');
          guided.endSession();
          _kickTourStop(index);
        }
      }

      AppContext.instance.current.addListener(check);
    }

    void showStep() {
      // Starting a driven tour takes over the screen — close any passive
      // coach-mark tour that happens to be up (e.g. a first-run
      // walkthrough) so the two never fight over the overlay.
      TourController.instance.finish();
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
          typingAllowed: !explainer && anchor == TourAnchors.homeComposer,
        ),
        index: index,
        total: total,
        explainer: explainer,
        onShown: () {
          unawaited(ack(true));
          // Perform on presentation, not on tap (founder, 2026-11-09): a
          // step carrying a command runs it the moment the spotlight is
          // confirmed up. If the goal was already reached as the step
          // landed, completeFromState has latched performed and this is a
          // no-op; the state watch below covers the user getting there
          // first while the step is up.
          startPerform();
          // VOICE, nothing to perform (the orb "this is me" step): on a live
          // call the orb IS the call bar, so the user can't tap the highlight
          // to complete the step — and advance_guided_tour would wait the full
          // ~110s tap window for a tour_event that can never come (founder,
          // 2026-11-08). Rest the step the instant it's shown: report it as
          // performed-and-waiting, so the tour moves on the user's SPOKEN "go"
          // (skip_guided_tour) and never on an orb tap. (A page explainer is
          // already treated as performed server-side, so it needs none of
          // this; a text step still completes on the tap below.)
          if (command == null && !explainer && _hasActiveVoice()) {
            if (!guided.isShowing(id)) return;
            performed = true;
            attempt++;
            event('performed', attempt: attempt);
            guided.recordOutcome(
              id,
              performed: true,
              notice: "Have a look. When you're ready, say next.",
            );
            _kickTourAdvance(index, kind: 'performed', attempt: attempt);
          }
        },
        // Anchor not present: ack so the backend skips the step, and clear the
        // spotlight — but keep the SESSION active (the backend sends the next
        // step), so the passive tour can't slip in during the gap.
        onAbsent: () {
          guided.clearStep();
          unawaited(ack(false));
        },
        // The tap on the highlight. A step with a command is Ayma's to
        // perform, and she performs it from presentation (onShown) — a tap
        // here is never the trigger and never the go; startPerform admits
        // only the retry after a failed attempt. A step with nothing to
        // perform completes on the tap: it writes the event the backend's
        // advance_guided_tour consumes, clears the spotlight (session stays
        // active until tour_end), and KICKS a model turn so the tour
        // advances even if no blocking advance_guided_tour happened to be
        // mid-wait (founder/Scout live failure, 2026-11-03). On a call the
        // go is spoken only, so that tap does nothing.
        onTapped: () {
          if (command != null) {
            startPerform();
            return;
          }
          if (_hasActiveVoice()) return;
          event('tapped');
          guided.clearStep();
          _kickTourAdvance(index, kind: 'tapped');
        },
        // The "Skip tour" affordance ends the whole session.
        onStop: () {
          event('stop');
          guided.endSession();
          _kickTourStop(index);
        },
        // The card's Next button: the go after a performed step, or a move
        // on without performing it — a 'skip' event the backend consumes
        // exactly like a spoken "next".
        onSkip: () {
          event('skip');
          guided.clearStep();
          _kickTourAdvance(index, kind: 'skip');
        },
      ),
      voiceOnly: _hasActiveVoice(),
      );
      // The goal may ALREADY be true as the step lands (the user got there
      // first, or did it during the previous step): complete from the
      // state at once instead of waiting for a tap that already happened.
      if (command != null && goalReached()) completeFromState();
      watchGoal();
    }

    if (onStepScreen()) {
      showStep();
      return;
    }
    // Not on the step's screen: give the screen state a brief moment to
    // catch up (a step can land a frame after the navigation that brought
    // the user here), then refuse honestly — the backend navigates the
    // user to the step's screen and retries the SAME step. Nothing is
    // ever highlighted blind.
    unawaited(() async {
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (onStepScreen() || goalReached()) {
          showStep();
          return;
        }
      }
      // Parking this step honestly: a PRIOR step's spotlight may still be up
      // (a voice no-command step the user left on their own "go", or any step
      // whose session outlived its screen). Drop that zombie overlay before we
      // ack — it must not sit as a stale scrim over the screen the backend is
      // about to navigate us to for the re-presented step. The SESSION stays
      // active (so the passive tour can't slip in), only the stale spotlight
      // clears.
      if (guided.active && !guided.isShowing(id)) guided.clearStep();
      await ack(false, reason: 'not_on_screen');
    }());
  }

  /// The shell's tabs, by [IndexedStack] slot, as [AppContext] names them.
  static const _tabSlugs = ['ayma', 'explore', 'messages', 'profile_tab'];

  /// How long a tour action may take to show up after it was dispatched.
  static const _tourConfirmPolls = 40;
  static const _tourConfirmInterval = Duration(milliseconds: 50);

  /// Run one tour step's command and report whether it really happened. The
  /// tour advances on the user's word after this, so unlike a spoken open it
  /// waits for the router or the shell to show the result rather than
  /// trusting the dispatch. Any failure is reported, never thrown.
  @visibleForTesting
  Future<bool> runTourCommand(Map<String, dynamic> cmd) async {
    try {
      final done = cmd['action'] == 'switch_tab'
          ? _switchShellTab((cmd['tab'] as num?)?.toInt() ?? -1)
          : _openAndConfirm(cmd);
      return await done.timeout(_navigationAckCap, onTimeout: () => false);
    } catch (e) {
      debugPrint('Ayma tour action ${cmd['action']} failed: $e');
      return false;
    }
  }

  /// Open a page and confirm the router left where it was: on the target, or
  /// wherever the target redirects to.
  Future<bool> _openAndConfirm(Map<String, dynamic> cmd) async {
    final target = _navigationTarget(cmd);
    if (target == null) return false;
    final before = _currentPath();
    if (!await openDestination(target)) return false;
    final bare = target.split('?').first;
    return _confirmedWithin(() {
      final now = _currentPath();
      return now == bare || now != before;
    });
  }

  /// Switch the shell's [IndexedStack] tab. Tabs share route '/', so the
  /// confirmation is the slug the shell publishes once it has switched. A
  /// request nobody picked up is withdrawn, so it can't fire later.
  Future<bool> _switchShellTab(int tab) async {
    if (tab < 0 || tab >= _tabSlugs.length) return false;
    if (_chatPopupOpen()) await _closeChatPopup();
    TabRequest.instance.request(tab);
    final switched = await _confirmedWithin(
      () => AppContext.instance.current.value.screen == _tabSlugs[tab],
    );
    if (!switched) TabRequest.instance.consume();
    return switched;
  }

  Future<bool> _confirmedWithin(bool Function() landed) async {
    for (var i = 0; i < _tourConfirmPolls; i++) {
      if (landed()) return true;
      await Future<void>.delayed(_tourConfirmInterval);
    }
    return landed();
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

  /// Route one command synchronously; true when it executed the
  /// action (for the non-navigation commands, what the ack's `ok`
  /// reports back to the waiting backend tool — the page-opening
  /// family acks through [_runNavigationCommand] instead, which
  /// awaits the actual landing). Split out so it's testable without
  /// Firestore.
  @visibleForTesting
  bool handleCommand(Map<String, dynamic> cmd) {
    switch (cmd['action'] as String? ?? '') {
      case 'navigate':
      case 'search_explore':
      case 'open_profile':
      case 'open_dm_thread':
      case 'open_notification':
        // The page-opening family: [_navigationTarget] resolves (and
        // validates) the route, [_open] dispatches it. The Firestore
        // listener routes these commands to [_runNavigationCommand]
        // instead, so their ack waits until the destination is
        // actually visible; this sync dispatch stays for direct
        // callers and tests.
        final target = _navigationTarget(cmd);
        if (target == null) return false;
        _open(target);
        return true;
      case 'carousel_photo':
        // The Firestore listener intercepts this action before
        // handleCommand so its ack can carry the photo count (see
        // _runCarouselPhoto); this case keeps a direct handleCommand
        // call honest too.
        return runCarouselPhoto(cmd).ok;
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

  /// The route a page-opening command wants opened, or null when the
  /// command is malformed and must ack `false` (no route path, an empty
  /// uid, nobody signed in). Performs the command's non-navigation side
  /// effects (Explore's search publishing) exactly as the dispatcher
  /// always has. Shared by the sync [handleCommand] and the ack-owning
  /// [_runNavigationCommand], so both resolve a command identically.
  String? _navigationTarget(Map<String, dynamic> cmd) {
    switch (cmd['action'] as String? ?? '') {
      case 'navigate':
        // The backend resolved this from the registry
        // (functions/bootstrap/app_registry.json); test/app_registry_test.dart
        // checks every registered path against the real router.
        final path = (cmd['path'] as String? ?? '').trim();
        return path.startsWith('/') ? path : null;
      case 'search_explore':
        final query = (cmd['query'] as String? ?? '').trim();
        AppContext.instance.pendingExploreQuery = query;
        // Also publish live: an Explore screen already built/visible must
        // run this search now, not only on its next build (founder,
        // 2026-11-06 - Ayma-driven changes update the visible UI live;
        // ported to staging 2026-11-07 per founder order).
        AppContext.instance.liveExploreQuery.value = query;
        // Through [_open] / [openDestination], not a bare push, like
        // every other navigation command: the destination must be
        // visible, never left underneath a still-open chat popup.
        // (Staging adaptation of f5ac63c9: the v2 original used
        // _navigate; staging routes through _open.)
        return ExploreScreen.path;
      case 'open_profile':
        final uid = (cmd['uid'] as String? ?? '').trim();
        return uid.isEmpty ? null : '/profile/user/$uid';
      case 'open_dm_thread':
        final uid = (cmd['uid'] as String? ?? '').trim();
        if (uid.isEmpty) return null;
        final me = _auth.currentUser?.uid;
        if (me == null || me.isEmpty) return null;
        // Through [_open], not a bare push (founder feedback item 6,
        // 2026-11-06: the opened conversation bounced straight back to
        // the conversations page): a bare push stacks the thread ON TOP
        // of Ayma's still-open chat popup, and the next popup-close
        // pop — which pops the top route assuming it is the popup —
        // kills the thread route instead. [_open] closes the popup
        // first and skips the push when the user is already on this
        // thread, exactly like the `navigate` and `open_notification`
        // cases.
        return '/dm/${sortedPairKey(me, uid)}';
      case 'open_notification':
        // The backend already picked the latest unread notification and
        // hands over its `deep_link`; route it exactly like a
        // notification-centre tap (same `deepLinkToRoute`, same
        // popup-close-then-push). Read state stays the backend's job:
        // it marks it read only once this open acks (§ L6: one ask
        // opens the destination directly).
        final link = (cmd['deep_link'] as String? ?? '').trim();
        if (link.isEmpty) return null;
        final self = _auth.currentUser?.uid;
        if (self == null || self.isEmpty) return null;
        return deepLinkToRoute(link, myUid: self);
    }
    return null;
  }

  /// Open [path] and report whether the destination actually ended up
  /// VISIBLE — the awaited, verified form of [_open] (same dispatch:
  /// close the chat sheet first, skip the push when already there, and
  /// a same-page open still dismisses an open sheet without recording
  /// a navigation). Visible means: the router is on the destination
  /// (compared by bare path, so query forms and router-normalized
  /// paths count) or a navigation to it was dispatched during this
  /// call, AND no chat sheet is left covering it. A sheet dismissal
  /// that throws, or a destination still covered afterwards, reports
  /// false. The page-opening commands ack this result (see
  /// [_runNavigationCommand]): the old dispatch-only ack claimed
  /// success the moment the open was STARTED, so neither a real turn
  /// nor the self-check could tell a landed open from an invisible one.
  @visibleForTesting
  Future<bool> openDestination(String path) async {
    final target = path.split('?').first;
    var dispatched = false;
    try {
      if (_currentPath() != path) {
        if (_chatPopupOpen()) {
          await _closeChatPopup();
        }
        if (_currentPath() != path) {
          _navigate(path);
          _history.visit(path);
          dispatched = true;
        }
      } else if (_chatPopupOpen()) {
        await _closeChatPopup();
      }
    } catch (e) {
      debugPrint('Ayma navigation to $path failed: $e');
      return false;
    }
    if (_destinationVisible(target, dispatched)) return true;
    // One settle beat: a just-dispatched navigation can report its
    // route a frame after the call returns.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _destinationVisible(target, dispatched);
  }

  bool _destinationVisible(String targetPath, bool dispatched) {
    if (_chatPopupOpen()) return false;
    return _currentPath() == targetPath || dispatched;
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
      case 'date_moments_on':
        _profiles.setDateMoments(true).catchError((_) {});
        return true;
      case 'date_moments_off':
        _profiles.setDateMoments(false).catchError((_) {});
        return true;
      case 'sign_out':
        _afterAck = _signOut;
        return true;
    }
    return false;
  }


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
