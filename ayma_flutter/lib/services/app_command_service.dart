import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../routing/app_router.dart';
import '../screens/explore_screen.dart';
import '../screens/sign_in_screen.dart';
import 'accent_color_controller.dart';
import 'app_context.dart';
import 'orb_animation_settings.dart';
import 'pair_key.dart';
import 'profile_service.dart';
import 'push_service.dart';
import 'screen_capture.dart';
import 'theme_controller.dart';

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
///   unexecuted — by then the backend tool has long since told the user it
///   didn't work, and surprise-navigating a minute later (or on the *next*
///   call, off a doc a dead listener left behind) is worse than skipping;
/// * the post-handle delete is transactional on the command `id`, so it can
///   never swallow a newer command that landed between our read and our
///   delete.
///
/// Three kinds of command land here, all dispatched by `action`:
/// * navigation — `navigate` (the route `path` the backend resolved from
///   `functions/bootstrap/app_registry.json`, the single source of truth for
///   destinations), `search_explore`, `open_profile`, `open_dm_thread`;
/// * `app_action` — the registry's client-held settings (theme, accent,
///   pause matching, orb animation), each calling the exact method its
///   screen's switch/radio calls, plus the confirmed `sign_out`, which the
///   backend only sends after the user explicitly confirmed and which runs
///   after the ack is written. Deleting the account and withdrawing consent
///   are never commands: Ayma only opens those pages (founder rule);
/// * `ui_action` — operate one on-screen control through [ScreenCapture]
///   (which refuses the registry's denylist), acked with the outcome and
///   what the screen shows afterwards.
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
  })  : _accentOverride = accentController,
        _uiAction = uiAction ?? _performUiAction,
        _fsOverride = firestore,
        _authOverride = auth,
        _navigate = navigate ?? appRouter.push,
        _go = go ?? appRouter.go,
        _theme = themeController ?? themeControllerGlobal,
        _orbAnim = orbAnimationSettings ?? orbAnimationSettingsGlobal,
        _clearPushTokenOverride = clearPushToken,
        _profilesOverride = profileService;

  final FirebaseFirestore? _fsOverride;
  final FirebaseAuth? _authOverride;
  final void Function(String path) _navigate;
  final void Function(String path) _go;
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

  /// A confirmed sign out waiting to run once the ack and the pending-doc
  /// cleanup are written — both live under `users/{uid}`, which signing out
  /// would break.
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

  /// A command older than this on arrival is dropped unexecuted — the
  /// backend's own ack wait (`_ACK_TIMEOUT_SECONDS`, 3s) gave up on it long
  /// ago and the user was already told it didn't work.
  static const _staleAfter = Duration(seconds: 25);

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
      _sub = _db.doc('users/$uid/app_commands/pending').snapshots().listen(
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
    var ok = false;
    try {
      ok = handleCommand(data);
    } catch (_) {
      ok = false; // ack the failure honestly rather than crash the stream
    }
    // Ack first (the backend tool is polling for this id right now), then
    // clear the pending doc.
    final acked = snap.reference.parent.doc('ack').set(<String, dynamic>{
      'id': id,
      'ok': ok,
      'ts': FieldValue.serverTimestamp(),
    }).catchError((_) {});
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
  Future<void> _runUiAction(DocumentReference<Map<String, dynamic>> ref,
      Map<String, dynamic> cmd, String id) async {
    final out = await runUiAction(cmd);
    await ref.parent.doc('ack').set(<String, dynamic>{
      'id': id,
      'ok': out.ok,
      if (out.ok) 'result': out.result else 'reason': out.reason,
      'ts': FieldValue.serverTimestamp(),
    }).catchError((_) {});
    await _deleteIfStillCommand(ref, id);
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
  void _listenForExploreReport(
      DocumentReference<Map<String, dynamic>> ackRef) {
    if (_reportListening) return;
    _reportListening = true;
    AppContext.instance.exploreReport.addListener(() {
      final report = AppContext.instance.exploreReport.value;
      if (report == null || _awaitingExploreId.isEmpty) return;
      if (report.query != _awaitingExploreQuery) return;
      final id = _awaitingExploreId;
      _awaitingExploreId = '';
      ackRef.set(<String, dynamic>{'id': id, 'result': report.summary},
          SetOptions(merge: true)).catchError((_) {});
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
      DocumentReference<Map<String, dynamic>> ref, String id) {
    return _db.runTransaction((tx) async {
      final cur = await tx.get(ref);
      if (((cur.data()?['id'] as String?) ?? '') == id) tx.delete(ref);
    }).catchError((_) {});
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
        _navigate(path);
        return true;
      case 'search_explore':
        AppContext.instance.pendingExploreQuery =
            (cmd['query'] as String? ?? '').trim();
        _navigate(ExploreScreen.path);
        return true;
      case 'open_profile':
        final uid = (cmd['uid'] as String? ?? '').trim();
        if (uid.isEmpty) return false;
        _navigate('/profile/user/$uid');
        return true;
      case 'open_dm_thread':
        final uid = (cmd['uid'] as String? ?? '').trim();
        if (uid.isEmpty) return false;
        final me = _auth.currentUser?.uid;
        if (me == null || me.isEmpty) return false;
        _navigate('/dm/${sortedPairKey(me, uid)}');
        return true;
      case 'app_action':
        return _handleAppAction(
          (cmd['name'] as String? ?? '').trim(),
          (cmd['value'] as String? ?? '').trim(),
        );
    }
    return false;
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
        _profiles.setPaused(true);
        return true;
      case 'resume_matching':
        _profiles.setPaused(false);
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
