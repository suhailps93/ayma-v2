import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../core/dag/launch_intent_resolver.dart';
import '../screens/sign_in_screen.dart';
import 'auth_service.dart';
import 'pair_key.dart';

/// Deep-Link Queue enforcing the Hard Auth Invariant.
/// Deep links must NEVER resolve without confirmed authentication.
/// If an intent arrives while unauthenticated, it is stashed in [_pendingPostAuthIntent]
/// and the user is routed to /signin. After sign-in completes, the intent is drained
/// with the confirmed non-empty UID.
class DeepLinkQueue {
  DeepLinkQueue._();
  static final DeepLinkQueue instance = DeepLinkQueue._();

  Completer<void> _navigationSettledCompleter = Completer<void>();
  LaunchIntent? _pendingPostAuthIntent;
  bool _isNavigationSettled = false;

  LaunchIntent? get pendingPostAuthIntent => _pendingPostAuthIntent;
  bool get isNavigationSettled => _isNavigationSettled;

  void notifyNavigationSettled() {
    _isNavigationSettled = true;
    if (!_navigationSettledCompleter.isCompleted) {
      _navigationSettledCompleter.complete();
    }
  }

  Future<void> awaitNavigationSettled() async {
    if (_isNavigationSettled) return;
    await _navigationSettledCompleter.future;
  }

  @visibleForTesting
  void resetForTest() {
    _navigationSettledCompleter = Completer<void>();
    _pendingPostAuthIntent = null;
    _isNavigationSettled = false;
  }

  /// Processes a launch intent under the hard auth invariant.
  Future<void> handleIntent(
    LaunchIntent intent, {
    required GoRouter router,
    required AuthService authService,
    required void Function(String path) navigate,
  }) async {
    if (intent is IconLaunchIntent) return;

    // 1. Await confirmed auth restoration (NO TIMEOUT FALLBACK)
    final user = await authService.ensureAuthReady();

    if (user == null || user.isAnonymous) {
      // 2. Unauthenticated: Stash intent and route to sign-in
      debugPrint('[DeepLinkQueue] User unauthenticated; stashing intent for post-auth.');
      _pendingPostAuthIntent = intent;
      router.go(SignInScreen.path);
      return;
    }

    // 3. Authenticated: Resolve route with verified UID
    final path = _resolvePathForIntent(intent, myUid: user.uid);
    if (path != null) {
      await awaitNavigationSettled();
      navigate(path);
    }
  }

  /// Drains stashed intent upon successful sign-in.
  Future<void> drainPostAuth(
    String confirmedUid, {
    required void Function(String path) navigate,
  }) async {
    if (_pendingPostAuthIntent == null || confirmedUid.isEmpty) return;
    final intent = _pendingPostAuthIntent!;
    _pendingPostAuthIntent = null;

    final path = _resolvePathForIntent(intent, myUid: confirmedUid);
    if (path != null) {
      await awaitNavigationSettled();
      navigate(path);
    }
  }

  String? _resolvePathForIntent(LaunchIntent intent, {required String myUid}) {
    assert(myUid.isNotEmpty, 'DeepLinkQueue resolution requires non-empty myUid');
    switch (intent) {
      case PaywallDeepLinkIntent(:final targetPath):
        return targetPath;
      case DmDeepLinkIntent(:final threadId, :final recipientUid):
        if (threadId != null && threadId.isNotEmpty) {
          return '/dm/$threadId';
        }
        if (recipientUid != null && recipientUid.isNotEmpty) {
          return '/dm/${sortedPairKey(myUid, recipientUid)}';
        }
        return null;
      case GenericDeepLinkIntent(:final targetPath):
        return targetPath;
      case IconLaunchIntent():
        return null;
    }
  }
}
