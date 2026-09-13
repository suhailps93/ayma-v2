import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// The platform calls behind a permission check/request, isolated behind an
/// interface so [CallPermissions] is testable without a real platform
/// channel (no plugin registered in a plain `flutter test` run).
abstract class PermissionGateway {
  Future<bool> isNotificationGranted();
  Future<bool> requestNotification();
  Future<bool> openAppSettings();
}

/// Wraps `permission_handler`. Android only needs POST_NOTIFICATIONS
/// (Android 13+) to keep the call-in-progress notification visible once
/// backgrounded — everything else here is a deliberate no-op:
///
/// - iOS never touches this: CallKit's system call UI isn't gated by
///   `UNUserNotificationCenter` authorization at all, so there is no iOS
///   notification permission to ask for here.
/// - Below Android 13, POST_NOTIFICATIONS doesn't exist as a runtime
///   permission — notifications are granted by default — so
///   `permission_handler` itself reports granted with nothing to request.
class _PermissionHandlerGateway implements PermissionGateway {
  const _PermissionHandlerGateway();

  bool get _appliesHere => !kIsWeb && Platform.isAndroid;

  @override
  Future<bool> isNotificationGranted() async {
    if (!_appliesHere) return true;
    try {
      return await ph.Permission.notification.isGranted;
    } catch (e) {
      // Fail open — a status-check hiccup should never be the reason a call
      // gets refused before it even starts.
      debugPrint('[call-permissions] notification status check failed: $e');
      return true;
    }
  }

  @override
  Future<bool> requestNotification() async {
    if (!_appliesHere) return true;
    try {
      final status = await ph.Permission.notification.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('[call-permissions] notification request failed: $e');
      return true;
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await ph.openAppSettings();
    } catch (e) {
      debugPrint('[call-permissions] openAppSettings failed: $e');
      return false;
    }
  }
}

/// Permission flow for a live voice call's background surface (F4/notif):
/// asked up front, when a call starts — not discovered mid-call by silently
/// failing once the app is backgrounded.
class CallPermissions {
  CallPermissions({PermissionGateway? gateway})
      : _gateway = gateway ?? const _PermissionHandlerGateway();

  final PermissionGateway _gateway;

  /// Call once, right as a voice session starts. Requests whatever the call
  /// will need later (Android's POST_NOTIFICATIONS) while the call is already
  /// underway in the foreground, so the OS prompt lands at a moment the user
  /// has context for, and the permission is (hopefully) already settled by
  /// the time the app is backgrounded and actually needs it.
  Future<void> ensureCallStartPermissions() async {
    if (await _gateway.isNotificationGranted()) return;
    await _gateway.requestNotification();
  }

  /// Checked right before the background call UI goes up. Never re-prompts —
  /// a second runtime request after a denial is a no-op on Android anyway,
  /// and re-asking mid-call would just interrupt it for nothing.
  Future<bool> ensureBackgroundCallPermission() =>
      _gateway.isNotificationGranted();

  /// Deep-link to the app's system settings page, for the "grant it" half of
  /// "explain + a way to grant it" after a denial.
  Future<bool> openSettings() => _gateway.openAppSettings();
}
