import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'call_permissions.dart';
import 'voice_session_controller.dart';

/// Keeps a live voice call visible and controllable — a real OS call surface
/// on both platforms, the same idea as how a normal phone call (or ChatGPT's
/// voice mode) behaves, replacing the old `flutter_overlay_window` floating
/// bubble:
///
/// - **Android**: an ongoing foreground-service notification — "Ayma", a
///   live status line, and Hang Up / Mute actions — backed by a real
///   `Service` (`CallForegroundService.kt`), not just a displayed
///   notification. Requires `POST_NOTIFICATIONS` on Android 13+
///   ([CallPermissions] asks for it up front, when the call starts).
/// - **iOS**: a CallKit-reported call (`CallKitManager.swift`), which is what
///   gives the system green status-bar pill, the lock-screen call card, and
///   a native end-call control — Apple's only supported way to keep a
///   persistent, user-controllable call surface once backgrounded. CallKit
///   needs no extra runtime permission (it doesn't go through
///   `UNUserNotificationCenter`); the trade-off is every call surfaces in the
///   Phone app's Recents list — see CallKitManager's doc comment.
///
/// Started the moment the call goes live, kept running for the whole call —
/// **never** started only on backgrounding. Android requires a
/// `foregroundServiceType="microphone"` service to already be running (in an
/// "eligible state") *before* the app leaves the foreground; starting one
/// reactively, after `AppLifecycleState.paused` already fired, is exactly the
/// case Android rejects with an uncaught `SecurityException` that crashes the
/// whole app (confirmed on-device via `adb logcat -b crash`, 2026-09-13 —
/// "Ayma keeps stopping" every time a call was backgrounded). Real call/VoIP
/// apps show this notification the whole time a call is up, foreground or
/// not, which is normal Android UX and trivially satisfies the eligibility
/// rule, so that's what this does now.
///
/// Both native sides talk back over the same `ayma/call_ui` method channel:
/// this class only ever reflects [VoiceSessionController]'s state onto the
/// OS and relays the two actions a user can trigger from that OS surface
/// (hang up / mute) straight back into the controller — it never drives the
/// call itself, so there is exactly one state machine (§ ask item 4).
class CallBackgroundService {
  CallBackgroundService(
    this._voice, {
    CallPermissions? permissions,
    @visibleForTesting this._debugSupportedOverride,
  }) : _permissions = permissions ?? CallPermissions();

  static const _channel = MethodChannel('ayma/call_ui');

  final VoiceSessionController _voice;
  final CallPermissions _permissions;
  final bool? _debugSupportedOverride;

  bool _started = false;
  bool _uiActive = false;
  Timer? _ticker;
  DateTime? _liveSince;
  VoidCallback? _voiceListener;

  bool get _supported =>
      _debugSupportedOverride ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  void start() {
    if (!_supported || _started) return;
    _started = true;
    _channel.setMethodCallHandler(_onNativeCall);
    _voiceListener = _onVoiceChanged;
    _voice.addListener(_voiceListener!);
    // Cover attaching to an already-live call (e.g. a hot restart mid-call)
    // — the edge-triggered listener above only fires on a *future* change.
    if (_voice.isActive) unawaited(_startUi());
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    if (_voiceListener != null) _voice.removeListener(_voiceListener!);
    _voiceListener = null;
    _channel.setMethodCallHandler(null);
    unawaited(_stopUi());
  }

  /// The call started, ended (from either side), or muted while the OS
  /// surface is up — keep it honest without waiting for the next tick.
  void _onVoiceChanged() {
    if (!_voice.isActive) {
      if (_uiActive) unawaited(_stopUi());
      return;
    }
    if (!_uiActive) {
      unawaited(_startUi());
    } else {
      unawaited(_pushUpdate());
    }
  }

  Future<void> _startUi() async {
    if (!_voice.isActive || _uiActive) return;

    final granted = await _permissions.ensureBackgroundCallPermission();
    if (!granted) {
      // Same reasoning the old bubble had: holding the mic open with no way
      // for the user to see or end it would block every other app's mic
      // access for as long as the call lasts. The difference now is the
      // user is actually told why, with a way to fix it for next time,
      // instead of the call just silently dying.
      await _voice.stop();
      _voice.reportBackgroundBlocked();
      return;
    }

    _uiActive = true;
    _liveSince = DateTime.now();
    try {
      await _channel.invokeMethod('start', _statusArgs());
    } catch (e) {
      debugPrint('[call-ui] start failed: $e');
      _uiActive = false;
      _liveSince = null;
      await _voice.stop();
      return;
    }
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _pushUpdate());
  }

  Future<void> _stopUi() async {
    _ticker?.cancel();
    _ticker = null;
    _liveSince = null;
    if (!_uiActive) return;
    _uiActive = false;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('[call-ui] stop failed: $e');
    }
  }

  Future<void> _pushUpdate() async {
    if (!_uiActive) return;
    try {
      await _channel.invokeMethod('update', _statusArgs());
    } catch (e) {
      debugPrint('[call-ui] update failed: $e');
    }
  }

  Map<String, dynamic> _statusArgs() => {
        'status': _statusText(),
        'muted': _voice.muted,
        // The native side renders the live MM:SS itself (Notification
        // chronometer, driven off elapsedRealtime) from this wall-clock
        // start time, rather than trusting a string this class recomputes
        // every second — that manual re-post was what went stale/frozen
        // on-device whenever the backgrounded Dart isolate got throttled.
        if (_liveSince != null)
          'startTimeMillis': _liveSince!.millisecondsSinceEpoch,
      };

  String _statusText() => _voice.muted ? 'Muted' : 'Voice call';

  /// Handles calls arriving *from* native — a tap on the notification's Hang
  /// Up / Mute action (Android) or on CallKit's own end-call / mute controls
  /// (iOS). Exposed for tests as [debugHandleNativeCall].
  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'hangUp':
        await _voice.stop();
      case 'toggleMute':
        await _voice.toggleMute();
        unawaited(_pushUpdate());
      case 'setMuted':
        // CallKit's own in-call mute button (iOS has no separate "Mute"
        // notification action — the system supplies this one) drives the
        // mic directly; mirror it into the one state machine rather than
        // letting CallKit and VoiceSessionController disagree.
        final muted = (call.arguments as Map?)?['muted'] as bool? ?? false;
        if (muted != _voice.muted) await _voice.toggleMute();
      case 'startFailed':
        debugPrint('[call-ui] native start failed: ${call.arguments}');
    }
    return null;
  }

  @visibleForTesting
  Future<dynamic> debugHandleNativeCall(MethodCall call) => _onNativeCall(call);

  @visibleForTesting
  bool get debugUiActive => _uiActive;
}
