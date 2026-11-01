import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Lightweight debug-only performance logger for Ayma.
///
/// Logs app-start milestones with elapsed milliseconds, API request timings,
/// and Firestore snapshot metadata (cache vs server).
///
/// All logging is strictly debug-only ([kDebugMode]); release builds execute
/// zero logging and incur no runtime overhead.
class PerfLog {
  PerfLog._();

  static final Stopwatch _stopwatch = Stopwatch();
  static bool _started = false;
  static bool _firstFrameTracked = false;

  /// Optional test hook to capture log messages without inspecting stdout.
  @visibleForTesting
  static void Function(String message)? customLogger;

  /// Resets internal state for unit tests.
  @visibleForTesting
  static void resetForTest() {
    _stopwatch.reset();
    _started = false;
    _firstFrameTracked = false;
    customLogger = null;
  }

  static void _log(String message) {
    if (customLogger != null) {
      customLogger!(message);
    } else {
      debugPrint(message);
    }
  }

  /// Starts the app-start stopwatch if in debug mode.
  static void start() {
    if (!kDebugMode) return;
    if (!_started) {
      _started = true;
      _stopwatch.start();
      _log('[PerfLog] [app_start] timer initialized');
    }
  }

  /// Elapsed milliseconds since [start] was called.
  static int get elapsedMs => _stopwatch.elapsedMilliseconds;

  /// Records an app-start milestone with elapsed milliseconds from start.
  static void milestone(String name) {
    if (!kDebugMode) return;
    if (!_started) {
      start();
    }
    _log('[PerfLog] [milestone] $name (+${_stopwatch.elapsedMilliseconds}ms)');
  }

  /// Registers a post-frame callback to record the first frame rendered milestone.
  static void trackFirstFrame() {
    if (!kDebugMode || _firstFrameTracked) return;
    _firstFrameTracked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      milestone('First frame rendered');
    });
  }

  /// Logs request timing in the API client.
  static void apiCall({
    required String method,
    required Uri uri,
    required int? statusCode,
    required int durationMs,
    required bool success,
    String? error,
  }) {
    if (!kDebugMode) return;
    final statusStr = statusCode != null ? '$statusCode' : 'ERROR';
    final resultStr = success ? 'SUCCESS' : 'FAILED';
    final errStr = error != null && error.isNotEmpty ? ' ($error)' : '';
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    _log('[PerfLog] [api] $method $path -> $statusStr ($resultStr) in ${durationMs}ms$errStr');
  }

  /// Logs Firestore snapshot origin (cache vs server).
  static void firestoreSnapshot({
    required String path,
    required bool isFromCache,
    bool hasPendingWrites = false,
    int? docCount,
  }) {
    if (!kDebugMode) return;
    final source = isFromCache ? 'CACHE' : 'SERVER';
    final countStr = docCount != null ? ' ($docCount docs)' : '';
    final pendingStr = hasPendingWrites ? ' [pending writes]' : '';
    _log('[PerfLog] [firestore] $path snapshot from $source$countStr$pendingStr');
  }
}
