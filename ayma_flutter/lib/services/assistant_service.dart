import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'assist_context.dart';

/// Dart side of the `ayma/assistant` platform channel — the bridge to
/// Ayma's Android default-assistant registration.
///
/// Every call is safe on any platform and any build: a missing plugin
/// (iOS, tests, older APKs) reads as "not the default assistant, no
/// pending summon" instead of throwing, so the feature degrades to
/// dormant exactly as specified.
class AssistantService {
  AssistantService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'ayma/assistant';

  /// The app-wide instance; bound once from `main()`.
  static final AssistantService instance = AssistantService();

  final MethodChannel _channel;

  /// True when Ayma is currently the device's default digital
  /// assistant (RoleManager ROLE_ASSISTANT on Android 10+, the
  /// voice-interaction secure setting below that).
  Future<bool> isDefaultAssistant() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultAssistant') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Deep-links to the system UI where the user makes Ayma the
  /// default assistant: the role request on Android 10+, the
  /// default-apps settings page below that. True when a settings
  /// surface was opened.
  Future<bool> openDefaultAssistantSettings() async {
    try {
      return await _channel
              .invokeMethod<bool>('openDefaultAssistantSettings') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Consumes the pending summon, if any. One-shot on the native side
  /// too: the snapshot (and its screenshot) is cleared by reading it.
  Future<AssistCapture?> takePendingAssist() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'takePendingAssist',
      );
      if (raw == null) return null;
      return AssistCapture.fromMap(raw);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether a summon is waiting, without consuming it.
  Future<bool> hasPendingAssist() async {
    try {
      return await _channel.invokeMethod<bool>('hasPendingAssist') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Drops any pending summon without reading its content.
  Future<void> clearPendingAssist() async {
    try {
      await _channel.invokeMethod<void>('clearPendingAssist');
    } on PlatformException {
      // Nothing to clear on a platform without the feature.
    } on MissingPluginException {
      // Same.
    }
  }

  /// Wires the warm-summon signal: when Android relaunches
  /// MainActivity for a summon while the engine is alive, native calls
  /// `onAssistSummon`; we then take the snapshot, hold it for the
  /// assistant surface and hand it to [onSummon]. Also performs the
  /// cold-start check (a summon that launched the process), where the
  /// invoke may have raced Dart handler registration.
  Future<void> bindSummons({
    required void Function(AssistCapture capture) onSummon,
  }) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onAssistSummon') return null;
      final capture = await takePendingAssist();
      if (capture != null) {
        AssistantSessionStore.instance.hold(capture);
        onSummon(capture);
      }
      return null;
    });
    final initial = await takePendingAssist();
    if (initial != null) {
      AssistantSessionStore.instance.hold(initial);
      onSummon(initial);
    }
  }

  /// Removes the summon handler (tests).
  @visibleForTesting
  void unbindSummons() => _channel.setMethodCallHandler(null);
}
