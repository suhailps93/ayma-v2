import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for the user's stored notification permission choice,
/// ensuring prompt-once semantics across sign-in and app relaunch (A2).
class NotificationPermissionStore {
  static const _key = 'ayma_notification_permission_choice';

  @visibleForTesting
  static String? debugOverride;

  static Future<String?> getChoice() async {
    if (debugOverride != null) return debugOverride;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setChoice(bool granted) async {
    final value = granted ? 'granted' : 'denied';
    debugOverride = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value);
    } catch (_) {}
  }

  @visibleForTesting
  static Future<void> clear() async {
    debugOverride = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}

/// OS-level notification permission as the user sees it in system settings.
enum PushPermissionState { granted, denied, notAsked }

/// Reads, requests and deep-links to the OS notification permission on both
/// Android (13+) and iOS, through `firebase_messaging` so the state matches
/// what FCM delivery actually depends on.
class PushPermission {
  PushPermission({
    this._messaging,
    Future<bool> Function()? openSettings,
    Future<String?> Function()? getStoredChoice,
    Future<void> Function(bool granted)? setStoredChoice,
  })  : _openSettings = openSettings ?? ph.openAppSettings,
        _getStoredChoice = getStoredChoice ?? NotificationPermissionStore.getChoice,
        _setStoredChoice = setStoredChoice ?? NotificationPermissionStore.setChoice;

  FirebaseMessaging? _messaging;
  final Future<bool> Function() _openSettings;
  final Future<String?> Function() _getStoredChoice;
  final Future<void> Function(bool granted) _setStoredChoice;

  FirebaseMessaging get _m => _messaging ??= FirebaseMessaging.instance;

  static PushPermissionState _map(AuthorizationStatus s) => switch (s) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional =>
          PushPermissionState.granted,
        AuthorizationStatus.denied ||
        AuthorizationStatus.deniedPermanently =>
          PushPermissionState.denied,
        AuthorizationStatus.notDetermined => PushPermissionState.notAsked,
      };

  Future<PushPermissionState> status() async {
    try {
      final s = _map((await _m.getNotificationSettings()).authorizationStatus);
      if (s == PushPermissionState.granted) {
        await _setStoredChoice(true);
        return s;
      }
      final choice = await _getStoredChoice();
      if (choice == 'denied') return PushPermissionState.denied;
      if (choice == 'granted') return PushPermissionState.granted;
      return s;
    } catch (e) {
      debugPrint('PushPermission.status failed: $e');
      return PushPermissionState.notAsked;
    }
  }

  /// Triggers the OS prompt (iOS and Android 13+). Returns the resulting state.
  Future<PushPermissionState> request() async {
    try {
      final s = _map((await _m.requestPermission()).authorizationStatus);
      await _setStoredChoice(s == PushPermissionState.granted);
      return s;
    } catch (e) {
      debugPrint('PushPermission.request failed: $e');
      return PushPermissionState.denied;
    }
  }

  Future<bool> openSystemSettings() async {
    try {
      return await _openSettings();
    } catch (e) {
      debugPrint('PushPermission.openSystemSettings failed: $e');
      return false;
    }
  }
}
