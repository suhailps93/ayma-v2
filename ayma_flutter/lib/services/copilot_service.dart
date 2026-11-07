import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'copilot_highlight.dart';

/// One captured frame from the live share, held in memory only.
///
/// Frames are never written to disk or storage anywhere in this feature:
/// the native service JPEG-encodes in memory, this object holds the latest
/// frame's bytes, and an ask uploads exactly this frame to
/// `POST /copilot/locate`. When sharing stops, the reference is dropped.
class CopilotFrame {
  const CopilotFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.displayWidth,
    required this.displayHeight,
    required this.meanLuminance,
    required this.capturedAt,
  });

  /// JPEG bytes (downscaled on-device to <=720px wide).
  final Uint8List bytes;

  /// The encoded frame's size (after downscale).
  final int width;
  final int height;

  /// The full display's size at capture time (pre-downscale) — the frame
  /// covers exactly this, status bar included.
  final int displayWidth;
  final int displayHeight;

  final double meanLuminance;
  final DateTime capturedAt;

  CopilotGeometry geometry({int quarterTurns = 0}) => CopilotGeometry(
        displayWidthPx: displayWidth.toDouble(),
        displayHeightPx: displayHeight.toDouble(),
        frameWidthPx: displayWidth.toDouble(),
        frameHeightPx: displayHeight.toDouble(),
        frameIncludesStatusBar: true,
        quarterTurns: quarterTurns,
      );
}

/// Dart side of the `ayma/copilot` platform channel: MediaProjection
/// capture + the draw-over-apps highlight overlay (Android only — the
/// native side lives in CopilotProjectionService.kt / CopilotOverlay.kt /
/// MainActivity.kt).
///
/// Ayma's side of the bargain, enforced here and natively:
///  * sharing starts ONLY from [requestCaptureAndStart] (the co-pilot
///    screen's explicit button), which runs the per-session system consent;
///  * she can draw a highlight and nothing else — the overlay window is
///    FLAG_NOT_TOUCHABLE, so every tap lands on the user's real app;
///  * secure (FLAG_SECURE) screens pause the share natively on black
///    frames; [securePaused] mirrors that state for the UI;
///  * no frame is ever persisted — see [CopilotFrame].
class CopilotService extends ChangeNotifier {
  CopilotService({
    MethodChannel? channel,
    @visibleForTesting this.debugSupportedOverride,
  }) : _channel = channel ?? const MethodChannel('ayma/copilot') {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;

  @visibleForTesting
  final bool? debugSupportedOverride;

  /// Android is the only V1 platform (iOS gets an annotated-screenshot
  /// fallback in a later phase — it has no draw-over-apps API).
  bool get isSupported =>
      debugSupportedOverride ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  bool _sharing = false;
  bool get isSharing => _sharing;

  bool _securePaused = false;

  /// True while the shared screen is a secure (FLAG_SECURE) surface —
  /// banking / password screens. Capture is paused natively and no frame
  /// leaves the device.
  bool get securePaused => _securePaused;

  bool _lockPaused = false;
  bool get lockPaused => _lockPaused;

  CopilotFrame? _latestFrame;
  CopilotFrame? get latestFrame => _latestFrame;

  /// The user can ask about the current screen only with a live, unpaused
  /// frame in hand.
  bool get canAsk => _sharing && !_securePaused && !_lockPaused && _latestFrame != null;

  // ------------------------------------------------------------ native → Dart

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onFrame':
        final args = call.arguments as Map<dynamic, dynamic>;
        final bytes = args['bytes'] as Uint8List;
        final luminance = (args['meanLuminance'] as num?)?.toDouble() ?? 255;
        // Belt and braces: the native side already drops black frames, but
        // a black frame that somehow arrives is never kept or uploaded.
        if (copilotIsBlackFrame(luminance)) {
          if (!_securePaused) {
            _securePaused = true;
            notifyListeners();
          }
          return null;
        }
        _latestFrame = CopilotFrame(
          bytes: bytes,
          width: (args['width'] as num).toInt(),
          height: (args['height'] as num).toInt(),
          displayWidth: (args['displayWidth'] as num).toInt(),
          displayHeight: (args['displayHeight'] as num).toInt(),
          meanLuminance: luminance,
          capturedAt: DateTime.now(),
        );
        notifyListeners();
      case 'onSecurePause':
        final args = call.arguments as Map<dynamic, dynamic>?;
        _securePaused = args?['paused'] == true;
        if (_securePaused) _latestFrame = null;
        notifyListeners();
      case 'onPaused':
        _lockPaused = true;
        notifyListeners();
      case 'onResumed':
        _lockPaused = false;
        notifyListeners();
      case 'onSharingStarted':
        _sharing = true;
        notifyListeners();
      case 'onSharingStopped':
        _resetSession();
        notifyListeners();
    }
    return null;
  }

  @visibleForTesting
  Future<dynamic> debugHandleNativeCall(MethodCall call) => _onNativeCall(call);

  /// The most recent draft Ayma composed for a text field — from the
  /// co-pilot page's ask or a voice-driven `copilot_locate` command —
  /// held for the confirmation-gated copy (`copilot_copy_draft` in
  /// voice, the "Copy Ayma's draft" button on the page). In memory
  /// only; cleared when the share session resets.
  String? lastDraftText;

  void _resetSession() {
    _sharing = false;
    _securePaused = false;
    _lockPaused = false;
    _latestFrame = null;
    lastDraftText = null;
  }

  // ------------------------------------------------------------ Dart → native

  Future<bool> canDrawOverlays() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> openOverlaySettings() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('openOverlaySettings');
    } on PlatformException {
      // Settings would not open; the screen re-checks on resume and keeps
      // showing the explainer, so the user is never stuck silently.
    } on MissingPluginException {
      // Non-Android build: nothing to open.
    }
  }

  /// Runs the per-session system consent and, on grant, starts the capture
  /// service. Returns whether the user consented. This is the ONLY way a
  /// share starts.
  Future<bool> requestCaptureAndStart() async {
    if (!isSupported) return false;
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestCapture') ?? false;
      if (granted) {
        _sharing = true;
        notifyListeners();
      }
      return granted;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> stopSharing() async {
    _resetSession();
    notifyListeners();
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stopSharing');
    } on PlatformException {
      // Already stopped natively; local state above is the truth the UI needs.
    } on MissingPluginException {
      // Non-Android build: nothing running natively.
    }
  }

  Future<bool> isSharingNative() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isSharing') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Draw the highlight ring for [target] over the user's current app.
  /// [quarterTurns] accounts for rotation between the frame Ayma saw and
  /// the display now (normally 0 — frames stream at ~1 fps).
  Future<void> showHighlight(
    CopilotTarget target, {
    required CopilotGeometry geometry,
  }) async {
    if (!isSupported || !target.found) return;
    final rect = CopilotCoordinateMapper.mapTarget(target, geometry);
    try {
      await _channel.invokeMethod<void>('showHighlight', {
        'x': rect.centerX,
        'y': rect.centerY,
        'w': rect.width,
        'h': rect.height,
        'label': target.label,
      });
    } on PlatformException {
      // Overlay permission revoked mid-session: the guidance text still
      // reaches the user in the co-pilot screen.
    } on MissingPluginException {
      // Non-Android build: no overlay exists.
    }
  }

  Future<void> clearHighlight() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('clearHighlight');
    } on PlatformException {
      // Ring already gone (it also auto-clears natively after a few seconds).
    } on MissingPluginException {
      // Non-Android build: nothing to clear.
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

/// The app-wide co-pilot service (one share session at a time).
final copilotServiceGlobal = CopilotService();
