import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import 'app_command_service.dart';

/// Keeps [AppCommandService] listening whenever the app is foregrounded, so
/// Ayma's text chat can drive the app (navigation, theme, pause matching)
/// the same way voice does — not only during a live call. Pauses the
/// listener in the background (the backend's ack wait then times out
/// honestly) and re-points it after a sign-in/out, since the watched
/// `users/{uid}/app_commands/pending` path changes with the user.
class AppCommandHost with WidgetsBindingObserver {
  AppCommandHost(this._service);

  final AppCommandService _service;
  StreamSubscription<User?>? _authSub;

  /// Begin observing app lifecycle and auth. Call once, after Firebase init.
  void attach() {
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    unawaited(_service.setForeground(
      state == null || state == AppLifecycleState.resumed,
    ));
    _authSub = FirebaseAuth.instance
        .authStateChanges()
        .listen((_) => unawaited(_service.restart()));
  }

  Future<void> detach() async {
    WidgetsBinding.instance.removeObserver(this);
    await _authSub?.cancel();
    _authSub = null;
    await _service.setForeground(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_service.setForeground(state == AppLifecycleState.resumed));
  }
}
