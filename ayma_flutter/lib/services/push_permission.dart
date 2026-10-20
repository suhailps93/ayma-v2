import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// OS-level notification permission as the user sees it in system settings.
enum PushPermissionState { granted, denied, notAsked }

/// Reads, requests and deep-links to the OS notification permission on both
/// Android (13+) and iOS, through `firebase_messaging` so the state matches
/// what FCM delivery actually depends on.
class PushPermission {
  PushPermission({
    this._messaging,
    Future<bool> Function()? openSettings,
  }) : _openSettings = openSettings ?? ph.openAppSettings;

  FirebaseMessaging? _messaging;
  final Future<bool> Function() _openSettings;

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
      return _map((await _m.getNotificationSettings()).authorizationStatus);
    } catch (e) {
      debugPrint('PushPermission.status failed: $e');
      return PushPermissionState.notAsked;
    }
  }

  /// Triggers the OS prompt (iOS and Android 13+). Returns the resulting state.
  Future<PushPermissionState> request() async {
    try {
      return _map((await _m.requestPermission()).authorizationStatus);
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
