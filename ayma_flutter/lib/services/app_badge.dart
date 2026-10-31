import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sets the OS app-icon badge number so it mirrors the in-app notification
/// unread count (§7.6). On iOS this is the red icon badge
/// (`applicationIconBadgeNumber`); on Android it is the launcher's numeric
/// badge where the launcher supports one.
///
/// Platform-agnostic and best-effort over the tiny `ayma/badge` channel — a
/// missing native handler (unit tests) or a launcher with no badge support is
/// logged and ignored, never thrown, so badge sync can never block a tap.
class AppBadge {
  const AppBadge();

  static const _channel = MethodChannel('ayma/badge');

  /// Set the icon badge to [count] (clamped at 0; 0 clears it).
  Future<void> set(int count) async {
    try {
      await _channel
          .invokeMethod<void>('setBadge', {'count': count < 0 ? 0 : count});
    } catch (e) {
      debugPrint('AppBadge.set($count) failed: $e');
    }
  }
}
