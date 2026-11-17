import 'dart:async';

import 'package:flutter/widgets.dart';

/// Coordinates and serializes OS runtime permission requests across the app.
///
/// Android allows only one runtime permission dialog to be displayed at a
/// time: calling `requestPermissions()` while another system permission dialog
/// is showing or pending drops the new request with empty `grantResults`, leaving
/// the permission in an unasked / denied state (NOTE 242, NOTE 244).
///
/// [PermissionCoordinator] tracks:
/// 1. In-flight permission requests across subsystems (Push, Location, Voice/Mic, Camera).
/// 2. App lifecycle focus ([AppLifecycleState.inactive] / [AppLifecycleState.paused]
///    while a system dialog obscures MainActivity).
///
/// Callers like `askStartupLocationPermission` wait on [waitForIdle] before
/// firing deferred retries so prompts only surface when the app is fully idle
/// and no competing system dialog is showing.
class PermissionCoordinator with WidgetsBindingObserver {
  PermissionCoordinator._() {
    _init();
  }

  void _init() {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // In headless unit tests WidgetsBinding might not be bound.
    }
  }

  static final PermissionCoordinator instance = PermissionCoordinator._();

  int _inFlightRequests = 0;
  AppLifecycleState? _lifecycleState;
  final List<Completer<void>> _idleWaiters = [];

  @visibleForTesting
  int get inFlightRequests => _inFlightRequests;

  @visibleForTesting
  AppLifecycleState? get lifecycleState => _lifecycleState;

  AppLifecycleState? get _currentLifecycleState {
    if (_lifecycleState != null) return _lifecycleState;
    try {
      return WidgetsBinding.instance.lifecycleState;
    } catch (_) {
      return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _checkIdle();
    }
  }

  /// Whether a competing system permission dialog is currently pending or showing.
  bool get isCompetingDialogShowing {
    if (_inFlightRequests > 0) return true;
    final state = _currentLifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      return true;
    }
    return false;
  }

  /// Tracks a permission request execution, ensuring [_inFlightRequests]
  /// is incremented for the duration and decremented on completion or timeout.
  Future<T> trackRequest<T>(
    Future<T> Function() action, {
    Duration? timeout,
  }) async {
    _inFlightRequests++;
    try {
      if (timeout != null) {
        return await action().timeout(timeout);
      }
      return await action();
    } finally {
      _inFlightRequests--;
      if (_inFlightRequests <= 0) {
        _inFlightRequests = 0;
      }
      _checkIdle();
    }
  }

  /// Awaits until no competing permission dialog is showing or pending,
  /// bounded by [timeout].
  Future<void> waitForIdle({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isCompetingDialogShowing) return;

    final completer = Completer<void>();
    _idleWaiters.add(completer);

    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      // On timeout, proceed rather than starving callers indefinitely.
    } finally {
      _idleWaiters.remove(completer);
    }
  }

  void _checkIdle() {
    if (!isCompetingDialogShowing) {
      final waiters = List<Completer<void>>.from(_idleWaiters);
      _idleWaiters.clear();
      for (final w in waiters) {
        if (!w.isCompleted) w.complete();
      }
    }
  }

  @visibleForTesting
  void resetForTest() {
    _inFlightRequests = 0;
    _lifecycleState = null;
    _idleWaiters.clear();
  }

  @visibleForTesting
  void setInFlightRequestsForTest(int count) {
    _inFlightRequests = count;
    _checkIdle();
  }

  @visibleForTesting
  void setLifecycleStateForTest(AppLifecycleState? state) {
    _lifecycleState = state;
    _checkIdle();
  }
}
