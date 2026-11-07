import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// The platform pieces of an in-call screen share that sit OUTSIDE the
/// LiveKit room (feedback item 13): the Android MediaProjection consent
/// dialog and the media-projection foreground service Android 14 requires
/// before a projection can run. Isolated behind an interface so
/// `VoiceSessionController` is testable without a real platform channel
/// (same pattern as `CallPermissions`' `PermissionGateway`).
///
/// Flow on Android, in order — skipping or reordering a step fails on
/// Android 14:
/// 1. [requestConsent] — the standard per-session system consent dialog
///    (flutter_webrtc runs `createScreenCaptureIntent`); the grant is held
///    inside the WebRTC plugin and consumed when the screen track is
///    created. A denial returns `false` and nothing else has happened —
///    the voice call is untouched.
/// 2. [startProjectionService] — upgrades the call's foreground service
///    (`CallForegroundService`, via the existing `ayma/call_ui` channel)
///    to carry the mediaProjection type. Android requires a running
///    mediaProjection-typed FGS before `getMediaProjection` is used,
///    which happens inside the plugin when the screen track is created.
/// 3. The caller publishes the screen track into the LiveKit room
///    (`VoiceTransport.setScreenShareEnabled`).
/// [stopProjectionService] downgrades the service back to microphone-only
/// when the share ends (toggle off, session end, or system revoke).
abstract class ScreenSharePlatform {
  /// Whether screen share can work at all on this platform in this build.
  /// Android only: iOS screen capture needs a ReplayKit broadcast upload
  /// extension (a separate native target this app does not ship), so iOS
  /// reports unsupported and the controller refuses the toggle while
  /// leaving the voice call running.
  bool get isSupported;

  /// Shows the per-session MediaProjection consent dialog (Android).
  /// Returns whether the user granted it. Never throws — a platform
  /// failure reads as "not granted".
  Future<bool> requestConsent();

  /// Starts (or upgrades) the media-projection foreground service.
  /// Best-effort: failures are logged, never thrown into the call.
  Future<void> startProjectionService();

  /// Removes the mediaProjection type from the call foreground service.
  /// Best-effort, like [startProjectionService].
  Future<void> stopProjectionService();
}

/// Real [ScreenSharePlatform] backed by flutter_webrtc's consent helper
/// and the `ayma/call_ui` method channel `CallBackgroundService` already
/// uses for the call foreground service.
class LiveKitScreenSharePlatform implements ScreenSharePlatform {
  const LiveKitScreenSharePlatform();

  static const _channel = MethodChannel('ayma/call_ui');

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> requestConsent() async {
    if (!isSupported) return false;
    try {
      // The standard Android MediaProjection consent dialog for this
      // session; the plugin keeps the grant for the track creation that
      // follows immediately after.
      return await webrtc.Helper.requestCapturePermission();
    } catch (e) {
      debugPrint('[voice] screen-share consent failed: $e');
      return false;
    }
  }

  @override
  Future<void> startProjectionService() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('startMediaProjectionFgs');
    } catch (e) {
      debugPrint('[voice] media-projection FGS start failed: $e');
    }
  }

  @override
  Future<void> stopProjectionService() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopMediaProjectionFgs');
    } catch (e) {
      debugPrint('[voice] media-projection FGS stop failed: $e');
    }
  }
}
