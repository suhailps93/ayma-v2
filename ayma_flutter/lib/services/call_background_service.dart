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
///   live status line, and Hang Up / Mute mic actions (plus Unmute Ayma
///   while she has been told to "shut up") — backed by a real
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
/// Started the moment Ayma is genuinely **conversing**
/// ([VoiceSessionController.isConversationReady] — the agent has joined, reached
/// `live`, AND produced its first real response), NOT while the call is still
/// `connecting`/`waking` or warming a cold open-weights brain, and kept running
/// for the rest of the call — **never** started only on backgrounding.
///
/// **Why gate on conversation-ready, and the Android microphone-FGS
/// constraint.** This service's notification is backed by a mandatory
/// `foregroundServiceType="microphone"` foreground service — on Android there
/// is no such thing as a silent FGS: `startForeground()` *requires* a
/// notification, so a running mic FGS always has a user-visible notification.
/// The founder's report (2026-11-03) was that the full ongoing-**call**
/// notification ("Ayma • Voice call" with Hang Up / Mute pills) appeared while
/// the app still showed "Warming up the open-weights model…", long before Ayma
/// could actually hear anything — because the agent reaches `live` *before* it
/// signals the warm-up. Gating on `isListening` (= `live`) alone therefore lit
/// the surface through the whole ~100s warm-up. The fix is to gate on
/// `isConversationReady` — Ayma's first genuine response — so the
/// connect/wake/warming window shows **no** call notification at all and the OS
/// surface appears exactly when Ayma starts conversing, the same `live`→first
/// response flip the in-app composer already uses ("Connecting…"→"Listening…").
///
/// Delaying is safe because a microphone FGS is only needed to keep mic
/// capture alive once the app is **backgrounded**: a foreground app records
/// audio freely without any FGS. Connecting/waking almost always completes
/// while the user is watching the connecting orb (foreground), so the FGS
/// starts in an "eligible state" at the listening moment just as it used to at
/// connect. Android requires a mic FGS to already be running before the app
/// leaves the foreground; starting one reactively after
/// `AppLifecycleState.paused` is the case Android rejects with an uncaught
/// `SecurityException` that crashes the whole app (confirmed on-device via
/// `adb logcat -b crash`, 2026-09-13 — "Ayma keeps stopping"). That crash
/// path is independently guarded: `CallForegroundService.onStartCommand`
/// wraps `startForeground()` in try/catch and tears the service down
/// gracefully instead of crashing. The one edge this trades for the cleaner
/// UX: if the user backgrounds the app *during* the connect/wake window and
/// the agent only reaches listening while still backgrounded, the FGS cannot
/// start then — no conversation is lost (the agent had not joined yet) and the
/// user simply refocuses the app; a missing notification is a far smaller
/// failure than losing the whole app mid-call.
///
/// Both native sides talk back over the same `ayma/call_ui` method channel:
/// this class only ever reflects [VoiceSessionController]'s state onto the
/// OS and relays the actions a user can trigger from that OS surface (hang
/// up / mute mic / unmute Ayma) straight back into the controller — it never
/// drives the call itself, so there is exactly one state machine (§ ask
/// item 4).
class CallBackgroundService {
  CallBackgroundService(
    this._voice, {
    CallPermissions? permissions,
    @visibleForTesting this._debugSupportedOverride,
  }) : _permissions = permissions ?? CallPermissions();

  static const _channel = MethodChannel('ayma/call_ui');

  /// The one service per [VoiceSessionController], shared by every
  /// [MainShellScreen] that shows it — see [acquire].
  static final Map<VoiceSessionController, CallBackgroundService> _shared = {};

  /// The instance whose [_onNativeCall] is installed on the process-wide
  /// [_channel], so a disposing instance never clears another's handler.
  static CallBackgroundService? _handlerOwner;

  /// Returns the single service for [voice], starting it on first use.
  /// Every caller must pair this with one [release].
  ///
  /// Routing is flat and Ayma's own `navigate` command pushes routes, so two
  /// `MainShellScreen`s can be mounted at once (one pushed over another, or a
  /// replacement built before the old one is disposed). When each owned its
  /// own service, the later one's `dispose()` cleared the shared channel
  /// handler while the earlier one kept the notification up — so Hang Up and
  /// Mute taps reached Dart with no handler and did nothing. One ref-counted
  /// service per call means the handler lives exactly as long as the last
  /// screen that shows the call.
  static CallBackgroundService acquire(
    VoiceSessionController voice, {
    CallPermissions? permissions,
    @visibleForTesting bool? debugSupportedOverride,
  }) {
    final service = _shared.putIfAbsent(
      voice,
      () => CallBackgroundService(
        voice,
        permissions: permissions,
        debugSupportedOverride: debugSupportedOverride,
      ),
    );
    if (service._refs++ == 0) service.start();
    return service;
  }

  /// Drops one [acquire] reference; the last one disposes the service.
  void release() {
    if (_refs == 0) return;
    if (--_refs > 0) return;
    if (identical(_shared[_voice], this)) _shared.remove(_voice);
    dispose();
  }

  int _refs = 0;

  final VoiceSessionController _voice;
  final CallPermissions _permissions;
  final bool? _debugSupportedOverride;

  bool _started = false;
  bool _uiActive = false;

  /// Set synchronously while a [_startUi] is in flight (between claiming the
  /// surface and the native `start` actually posting), so a second
  /// `_onVoiceChanged` tick during the permission await can neither launch a
  /// duplicate `start` nor race an `update` ahead of it. Distinct from
  /// [_uiActive] (the surface is actually up).
  bool _uiStarting = false;
  Timer? _ticker;
  DateTime? _liveSince;
  VoidCallback? _voiceListener;

  bool get _supported =>
      _debugSupportedOverride ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  void start() {
    if (!_supported || _started) return;
    _started = true;
    _handlerOwner = this;
    _channel.setMethodCallHandler(_onNativeCall);
    _voiceListener = _onVoiceChanged;
    _voice.addListener(_voiceListener!);
    // Cover attaching to an already-ready call (e.g. a hot restart mid-call,
    // or the shared shell acquiring the service after the call is live) — the
    // edge-triggered listener above only fires on a *future* change. Gated on
    // `isConversationReady`, not `isActive`/`isListening`: a service attached
    // while the call is still connecting/waking/warming must wait until Ayma is
    // genuinely conversing.
    if (_voice.isConversationReady) unawaited(_startUi());
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    if (_voiceListener != null) _voice.removeListener(_voiceListener!);
    _voiceListener = null;
    if (identical(_handlerOwner, this)) {
      _handlerOwner = null;
      _channel.setMethodCallHandler(null);
    }
    unawaited(_stopUi());
  }

  /// Ayma became (or stopped being) genuinely conversation-ready, or the call
  /// muted while the OS surface is up — keep it honest without waiting for the
  /// next tick. Gating on [VoiceSessionController.isConversationReady] (not
  /// `isActive`/`isListening`) is what holds the call notification back through
  /// connecting/waking AND the open-weights warm-up: the surface appears only
  /// once Ayma is actually conversing (her first response has landed), and
  /// tears down the moment the call ends (ended, failed, or idle-timed-out).
  void _onVoiceChanged() {
    if (!_voice.isConversationReady) {
      if (_uiActive || _uiStarting) unawaited(_stopUi());
      return;
    }
    if (!_uiActive && !_uiStarting) {
      unawaited(_startUi());
    } else if (_uiActive) {
      unawaited(_pushUpdate());
    }
    // While only `_uiStarting` (start in flight): drop the update — the
    // pending `start` already serializes the latest state via `_statusArgs()`.
  }

  Future<void> _startUi() async {
    if (!_voice.isConversationReady || _uiActive || _uiStarting) return;
    // Claim the start SYNCHRONOUSLY, before the first await below. The
    // conversation-ready transition rides on more than one `notifyListeners`
    // (the controller flips `_agentRespondedOnce` and then its agent-speaking
    // state on the same first response), so a second `_onVoiceChanged` tick can
    // reach here before the permission await resolves — without this latch it
    // would post a duplicate `start`, or an `update` ahead of the `start`.
    // Reset on every early-out below.
    _uiStarting = true;

    final granted = await _permissions.ensureBackgroundCallPermission();
    // The call may have ended (or dropped out of the ready state) while the
    // permission check awaited — don't put up an OS surface for a dead call.
    if (!_voice.isConversationReady) {
      _uiStarting = false;
      return;
    }
    if (!granted) {
      // Same reasoning the old bubble had: holding the mic open with no way
      // for the user to see or end it would block every other app's mic
      // access for as long as the call lasts. The difference now is the
      // user is actually told why, with a way to fix it for next time,
      // instead of the call just silently dying.
      _uiStarting = false;
      await _voice.stop();
      _voice.reportBackgroundBlocked();
      return;
    }

    _liveSince = DateTime.now();
    try {
      await _channel.invokeMethod('start', _statusArgs());
    } catch (e) {
      debugPrint('[call-ui] start failed: $e');
      _uiStarting = false;
      _liveSince = null;
      await _voice.stop();
      return;
    }
    _uiActive = true;
    _uiStarting = false;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _pushUpdate());
  }

  Future<void> _stopUi() async {
    _ticker?.cancel();
    _ticker = null;
    _liveSince = null;
    // Abandon any start still in flight so its post is discarded on resume.
    _uiStarting = false;
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
        'muted': _voice.muted || _voice.micYielded,
        // Ayma told to "shut up": the notification adds an "Unmute Ayma"
        // action (distinct from "Mute mic", the user's own mic).
        'aymaQuiet': _voice.aymaQuiet,
        // The native side renders the live MM:SS itself (Notification
        // chronometer, driven off elapsedRealtime) from this wall-clock
        // start time, rather than trusting a string this class recomputes
        // every second — that manual re-post was what went stale/frozen
        // on-device whenever the backgrounded Dart isolate got throttled.
        if (_liveSince != null)
          'startTimeMillis': _liveSince!.millisecondsSinceEpoch,
      };

  /// Notification line under "Ayma". Ayma's quiet state wins over the
  /// user's mic state: it is the one that needs an action to undo.
  @visibleForTesting
  static const quietStatus = 'Shut up mode: tap Unmute to bring her back';

  String _statusText() {
    if (_voice.aymaQuiet) return quietStatus;
    if (_voice.micYielded) return 'Mic yielded';
    return _voice.muted ? 'Mic muted' : 'Voice call';
  }

  /// Handles calls arriving *from* native — a tap on the notification's Hang
  /// Up / Mute mic / Unmute Ayma action (Android) or on CallKit's own end-call / mute controls
  /// (iOS). Exposed for tests as [debugHandleNativeCall].
  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'hangUp':
        await _voice.stop();
      case 'toggleMute':
        await _voice.toggleMute();
        unawaited(_pushUpdate());
      case 'unmuteAyma':
        // The notification is updated by the agent's `agent_mute` echo
        // (via [_onVoiceChanged]), not optimistically here.
        await _voice.unmuteAyma();
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
