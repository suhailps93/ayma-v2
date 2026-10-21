import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;

import '../routing/app_router.dart';
import '../screens/accent_color_screen.dart';
import '../screens/ayma_settings_screen.dart';
import '../screens/explore_screen.dart';
import '../screens/feedback_screen.dart';
import '../screens/main_shell_screen.dart';
import '../screens/my_public_profile_screen.dart';
import '../screens/matches_screen.dart';
import '../screens/messages_screen.dart';
import '../screens/notification_center_screen.dart';
import '../screens/notification_prefs_screen.dart';
import '../screens/privacy_screen.dart';
import '../screens/profile_settings_screen.dart';
import '../screens/profile_tab_screen.dart';
import '../screens/release_notes_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/skills_screen.dart';
import '../screens/story_editor_screen.dart';
import '../screens/terms_screen.dart';
import '../screens/usage_screen.dart';
import '../screens/voice_preference_screen.dart';
import 'app_context.dart';
import 'pair_key.dart';
import 'profile_service.dart';
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
/// Two kinds of command land here, both dispatched by `action`:
/// * navigation — `navigate` (any fixed screen, `_pathFor`), `search_explore`,
///   `open_profile`, `open_dm_thread` (a specific person or conversation);
/// * `app_action` — a small, curated set of common named actions
///   (`_handleAppAction`) that aren't navigation at all, e.g. switching the
///   theme or pausing matching. This is deliberately NOT generic UI
///   automation — see `skills/app_control.py`'s `_APP_ACTIONS` for the exact
///   list and why it stops there.
class AppCommandService {
  AppCommandService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    void Function(String path)? navigate,
    ThemeController? themeController,
    ProfileService? profileService,
  })  : _fsOverride = firestore,
        _authOverride = auth,
        _navigate = navigate ?? appRouter.push,
        _theme = themeController ?? themeControllerGlobal,
        _profilesOverride = profileService;

  final FirebaseFirestore? _fsOverride;
  final FirebaseAuth? _authOverride;
  final void Function(String path) _navigate;
  final ThemeController _theme;
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
      _deleteIfStillCommand(snap.reference, id);
      return;
    }
    if (id.isNotEmpty) _lastHandledId = id;
    var ok = false;
    try {
      ok = handleCommand(data);
    } catch (_) {
      ok = false; // ack the failure honestly rather than crash the stream
    }
    // Ack first (the backend tool is polling for this id right now), then
    // clear the pending doc.
    snap.reference.parent.doc('ack').set(<String, dynamic>{
      'id': id,
      'ok': ok,
      'ts': FieldValue.serverTimestamp(),
    }).catchError((_) {});
    _deleteIfStillCommand(snap.reference, id);
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
  void _deleteIfStillCommand(
      DocumentReference<Map<String, dynamic>> ref, String id) {
    _db.runTransaction((tx) async {
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
        final path = _pathFor(cmd['screen'] as String? ?? '');
        if (path == null) return false;
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
        return _handleAppAction((cmd['name'] as String? ?? '').trim());
    }
    return false;
  }

  /// Every fixed destination `open_screen` (`skills/app_control.py`) can
  /// name — kept in lock-step with that tool's `_SCREENS`. `null` for an
  /// unrecognised key is a deliberate no-op, matching the backend's own
  /// validation (it never queues a command for a screen it didn't allow).
  String? _pathFor(String screen) {
    switch (screen) {
      case 'ayma':
        return MainShellScreen.path;
      case 'explore':
        return ExploreScreen.path;
      case 'messages':
        return MessagesScreen.path;
      case 'profile':
        return ProfileTabScreen.path;
      case 'matches':
        return MatchesScreen.path;
      case 'story':
        return StoryEditorScreen.path;
      case 'settings':
        return SettingsScreen.path;
      case 'ayma_settings':
        return AymaSettingsScreen.path;
      case 'profile_details':
        return ProfileSettingsScreen.path;
      case 'photos':
        return MyPublicProfileScreen.editPhotosPath;
      case 'skills':
        return SkillsScreen.path;
      case 'voice_preference':
        return VoicePreferenceScreen.path;
      case 'credits':
        return UsageScreen.path;
      case 'accent_color':
        return AccentColorScreen.path;
      case 'notifications':
        return NotificationCenterScreen.path;
      case 'notification_settings':
        return NotificationPrefsScreen.path;
      case 'feedback':
        return FeedbackScreen.path;
      case 'terms':
        return TermsScreen.path;
      case 'privacy':
        return PrivacyScreen.path;
      case 'release_notes':
        return ReleaseNotesScreen.path;
    }
    return null;
  }

  /// The curated actions `app_action` (`skills/app_control.py`'s
  /// `_APP_ACTIONS`) can trigger — each one calls the exact same method a
  /// button's `onPressed`/`onChanged` already calls (`SettingsScreen`'s theme
  /// radios and "Pause matching" switch), never a raw widget tap. An
  /// unrecognised name is a no-op (false), matching the backend's own
  /// validation.
  bool _handleAppAction(String name) {
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
      case 'pause_matching':
        _profiles.setPaused(true);
        return true;
      case 'resume_matching':
        _profiles.setPaused(false);
        return true;
    }
    return false;
  }
}
