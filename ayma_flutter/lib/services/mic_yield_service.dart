import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef MicYieldCallback = FutureOr<void> Function(String reason);

/// Monitors system-level microphone interruptions on Android: audio focus loss
/// and AudioManager active recording configuration changes (e.g. when Gemini,
/// News, Google Assistant, or a phone call requests audio focus or captures audio).
///
/// When another app captures audio, native dispatches `onMicYielded`, which notifies
/// all registered handlers (the live voice session, dictation, and voice-note recorders)
/// to release the microphone immediately and update their UI state.
class MicYieldService {
  MicYieldService({
    MethodChannel? channel,
    @visibleForTesting this._debugSupportedOverride,
  }) : _channel = channel ?? const MethodChannel('ayma/mic_yield');

  static MicYieldService? _instance;
  static MicYieldService get instance => _instance ??= MicYieldService();

  @visibleForTesting
  static set instance(MicYieldService service) => _instance = service;

  final MethodChannel _channel;
  final bool? _debugSupportedOverride;
  final Set<MicYieldCallback> _handlers = {};
  int _activeMonitors = 0;
  bool _handlerAttached = false;

  bool get _supported =>
      _debugSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  @visibleForTesting
  int get activeMonitors => _activeMonitors;

  /// Registers a callback invoked whenever the microphone must be yielded.
  void addHandler(MicYieldCallback handler) {
    _handlers.add(handler);
  }

  /// Removes a registered yield callback.
  void removeHandler(MicYieldCallback handler) {
    _handlers.remove(handler);
  }

  /// Tells the native platform that a local mic-holding path has started capturing audio.
  /// Ref-counted so multiple concurrent paths (e.g. quick transitions) keep monitoring active.
  Future<void> startMonitoring() async {
    if (!_supported) return;
    _activeMonitors++;
    if (_activeMonitors == 1) {
      _attachHandler();
      try {
        await _channel.invokeMethod('startMonitoring');
      } catch (e) {
        debugPrint('[mic_yield] startMonitoring failed: $e');
      }
    }
  }

  /// Tells the native platform that a local mic-holding path has stopped capturing audio.
  Future<void> stopMonitoring() async {
    if (!_supported) return;
    if (_activeMonitors > 0) {
      _activeMonitors--;
      if (_activeMonitors == 0) {
        _detachHandler();
        try {
          await _channel.invokeMethod('stopMonitoring');
        } catch (e) {
          debugPrint('[mic_yield] stopMonitoring failed: $e');
        }
      }
    }
  }

  /// Forces monitor count to zero (e.g. after a yield or session teardown).
  Future<void> resetMonitoring() async {
    if (!_supported) return;
    _activeMonitors = 0;
    _detachHandler();
    try {
      await _channel.invokeMethod('stopMonitoring');
    } catch (_) {}
  }

  void _attachHandler() {
    if (!_handlerAttached) {
      try {
        _channel.setMethodCallHandler(_onMethodCall);
        _handlerAttached = true;
      } catch (e) {
        debugPrint('[mic_yield] setMethodCallHandler failed: $e');
      }
    }
  }

  void _detachHandler() {
    if (_handlerAttached) {
      try {
        _channel.setMethodCallHandler(null);
        _handlerAttached = false;
      } catch (e) {
        debugPrint('[mic_yield] setMethodCallHandler(null) failed: $e');
      }
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'onMicYielded') {
      final reason =
          (call.arguments as Map?)?['reason'] as String? ?? 'audio_focus_loss';
      _activeMonitors = 0;
      await notifyYielded(reason);
    }
    return null;
  }

  /// Invokes all registered yield handlers with [reason]. Exposed for testing.
  Future<void> notifyYielded(String reason) async {
    final copy = List<MicYieldCallback>.from(_handlers);
    for (final handler in copy) {
      try {
        await handler(reason);
      } catch (e, st) {
        debugPrint('[mic_yield] handler threw: $e\n$st');
      }
    }
  }

  @visibleForTesting
  Future<dynamic> debugHandleMethodCall(MethodCall call) => _onMethodCall(call);

  void dispose() {
    _handlers.clear();
    _activeMonitors = 0;
    _detachHandler();
  }
}
