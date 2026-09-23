import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// The slice of Firebase Cloud Messaging [PushService] needs — pulled behind an
/// interface so the service is unit-testable without the plugin.
abstract class FcmTokens {
  /// Ask the OS for notification permission. Returns false only on an explicit
  /// denial (provisional / not-determined-but-granted count as true).
  Future<bool> ensurePermission();

  Future<String?> currentToken();

  Stream<String> tokenRefreshes();

  Future<void> deleteToken();

  /// The `data` payload of the push that cold-started the app (the user
  /// tapped a notification while the app wasn't running), or null if it
  /// wasn't launched that way.
  Future<Map<String, dynamic>?> initialTapData();

  /// The `data` payload of every push tapped while the app is already
  /// running (foreground or background) — `onMessageOpenedApp` (§7.6).
  Stream<Map<String, dynamic>> tapsWhileRunning();
}

class FirebaseFcmTokens implements FcmTokens {
  FirebaseFcmTokens([FirebaseMessaging? messaging])
      : _m = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _m;

  @override
  Future<bool> ensurePermission() async {
    final settings = await _m.requestPermission();
    return settings.authorizationStatus != AuthorizationStatus.denied;
  }

  @override
  Future<String?> currentToken() => _m.getToken();

  @override
  Stream<String> tokenRefreshes() => _m.onTokenRefresh;

  @override
  Future<void> deleteToken() => _m.deleteToken();

  @override
  Future<Map<String, dynamic>?> initialTapData() async =>
      (await _m.getInitialMessage())?.data;

  @override
  Stream<Map<String, dynamic>> tapsWhileRunning() =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);
}

/// FCM device-token lifecycle (ARCHITECTURE.md §7.2, §7.9 step 2).
///
/// [syncToken] runs once per launch after the user is signed in: it asks for
/// notification permission, reads the current token, and registers it with the
/// backend (`fcm_tokens` array on `users/{uid}`), then subscribes to token
/// refreshes for the rest of the process lifetime.
///
/// Best-effort throughout — a denied permission, a missing APNs token on iOS,
/// or a network failure logs and returns; push is an enhancement, never a gate
/// on using the app.
class PushService {
  PushService({FcmTokens? tokens, ApiClient? apiClient})
      : _tokens = tokens ?? FirebaseFcmTokens(),
        _api = apiClient ?? ApiClient();

  final FcmTokens _tokens;
  final ApiClient _api;

  StreamSubscription<String>? _refreshSub;
  StreamSubscription<Map<String, dynamic>>? _tapSub;
  String? _lastRegistered;

  Future<void> syncToken() async {
    try {
      if (!await _tokens.ensurePermission()) return;
      await _register(await _tokens.currentToken());
      _refreshSub ??= _tokens.tokenRefreshes().listen(_register);
    } catch (e) {
      debugPrint('PushService.syncToken failed: $e');
    }
  }

  Future<void> _register(String? token) async {
    if (token == null || token.isEmpty || token == _lastRegistered) return;
    try {
      await _api.registerFcmToken(token);
      _lastRegistered = token;
    } catch (e) {
      debugPrint('PushService register token failed: $e');
    }
  }

  /// Sign-out cleanup: unregister the current token and drop it from the device.
  Future<void> clearToken() async {
    try {
      final token = await _tokens.currentToken();
      if (token != null && token.isNotEmpty) {
        await _api.removeFcmToken(token);
      }
      await _tokens.deleteToken();
    } catch (e) {
      debugPrint('PushService.clearToken failed: $e');
    } finally {
      _lastRegistered = null;
    }
  }

  /// Routes a tap on a push notification straight to the screen its
  /// `deep_link` data names (§7.6) — a match request, a DM thread, the
  /// matches list — instead of leaving the tap to just open the app on
  /// whatever screen it defaults to. Checks the cold-start tap first
  /// (`getInitialMessage`), then keeps listening for the rest of the
  /// process lifetime. [navigate] and [resolveRoute] are injectable for
  /// tests; they default to the real router and [deepLinkToRoute].
  ///
  /// Best-effort like [syncToken] — a failure here never blocks the app.
  Future<void> listenForTaps({
    required void Function(String path) navigate,
    required String Function(String deepLink) resolveRoute,
  }) async {
    void route(Map<String, dynamic> data) {
      final link = data['deep_link'] as String?;
      if (link == null || link.isEmpty) return;
      navigate(resolveRoute(link));
    }

    try {
      final initial = await _tokens.initialTapData();
      if (initial != null) route(initial);
    } catch (e) {
      debugPrint('PushService initial tap failed: $e');
    }
    _tapSub ??= _tokens.tapsWhileRunning().listen(route);
  }

  Future<void> dispose() async {
    await _refreshSub?.cancel();
    _refreshSub = null;
    await _tapSub?.cancel();
    _tapSub = null;
  }
}
