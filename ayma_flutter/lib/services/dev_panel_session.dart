import 'package:flutter/widgets.dart';

/// In-memory unlock state for the hidden Developer panel.
///
/// The panel's sensitive contents — build / mode / account diagnostics,
/// real-money spend, the free reload, per-conversation cost, the detailed
/// release notes and the AI-notes flag toggle — are shown only while
/// [unlocked] is true. That happens after the developer password is verified
/// server-side (`POST /dev/verify`); nothing is persisted, so a fresh app
/// launch always starts locked. The verified password is kept only in memory
/// while unlocked so the AI-notes toggle can reuse it without a second prompt.
///
/// Registered as a [WidgetsBindingObserver] in `main.dart`: once unlocked, the
/// panel auto-relocks if the app has been backgrounded at least
/// [_backgroundRelock].
class DevPanelSession with WidgetsBindingObserver {
  DevPanelSession._();

  static final DevPanelSession instance = DevPanelSession._();

  /// Relock once the app has been in the background at least this long.
  static const _backgroundRelock = Duration(minutes: 5);

  /// Whether the panel's contents are currently visible.
  final ValueNotifier<bool> unlocked = ValueNotifier(false);

  String? _password;
  DateTime? _backgroundedAt;

  /// The verified developer password while unlocked, or null when locked.
  String? get password => _password;

  /// Marks the session unlocked and keeps [password] for the AI-notes toggle.
  void unlock(String password) {
    _password = password;
    _backgroundedAt = null;
    unlocked.value = true;
  }

  /// Re-locks the panel and forgets the password.
  void lock() {
    _password = null;
    _backgroundedAt = null;
    unlocked.value = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!unlocked.value) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null &&
          DateTime.now().difference(since) >= _backgroundRelock) {
        lock();
      }
    }
  }
}
