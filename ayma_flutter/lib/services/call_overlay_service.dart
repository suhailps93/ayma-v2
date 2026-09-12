import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'voice_session_controller.dart';

/// Keeps a live voice call honest when the app is backgrounded (F4).
///
/// Android only — `SYSTEM_ALERT_WINDOW` floating overlays don't exist on iOS,
/// and iOS's own `UIBackgroundModes: [audio]` entitlement (already set) lets a
/// call keep running in the background under Apple's own audio-session
/// policy, so there's nothing for this service to add there.
///
/// - Overlay permission granted -> show a small floating bubble with a Stop
///   control, so the call visibly continues under the user's control instead
///   of silently holding the mic with no UI at all.
/// - Permission **not** granted -> stop the call outright. Holding the mic
///   open in the background with no way for the user to see or end it would
///   block every other app's mic access for as long as the call lasts.
class CallOverlayService with WidgetsBindingObserver {
  CallOverlayService(this._voice);

  final VoiceSessionController _voice;

  /// Looked up by `overlayMain()` (main.dart) to send the Stop tap back here.
  static const portName = 'ayma_call_overlay_main';

  ReceivePort? _port;
  bool _started = false;

  bool get _supported => !kIsWeb && Platform.isAndroid;

  void start() {
    if (!_supported || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _port?.close();
    _port = null;
    IsolateNameServer.removePortNameMapping(portName);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_supported) return;
    if (state == AppLifecycleState.paused) {
      unawaited(_onBackground());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_onForeground());
    }
  }

  Future<void> _onBackground() async {
    if (!_voice.isActive) return;

    var granted = false;
    try {
      granted = await FlutterOverlayWindow.isPermissionGranted();
    } catch (e) {
      debugPrint('[call-overlay] permission check failed: $e');
    }

    if (!granted) {
      await _voice.stop();
      return;
    }

    _listenForOverlayMessages();
    try {
      await FlutterOverlayWindow.showOverlay(
        height: 200,
        width: 200,
        alignment: OverlayAlignment.topRight,
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        enableDrag: true,
        positionGravity: PositionGravity.auto,
        overlayTitle: 'Ayma',
        overlayContent: 'Voice call in progress',
      );
    } catch (e) {
      // Couldn't put anything on screen after all — same reasoning as a
      // denied permission: don't hold the mic with nothing to show for it.
      debugPrint('[call-overlay] showOverlay failed: $e');
      await _voice.stop();
    }
  }

  Future<void> _onForeground() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } catch (e) {
      debugPrint('[call-overlay] closeOverlay failed: $e');
    }
  }

  void _listenForOverlayMessages() {
    if (_port != null) return;
    _port = ReceivePort();
    IsolateNameServer.registerPortWithName(_port!.sendPort, portName);
    _port!.listen((message) {
      if (message == 'stop') {
        unawaited(_voice.stop());
        unawaited(FlutterOverlayWindow.closeOverlay());
      }
    });
  }
}
