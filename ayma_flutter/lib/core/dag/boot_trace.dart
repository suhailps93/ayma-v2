import 'package:flutter/foundation.dart';

/// Lightweight boot timeline tracer for diagnosing cold-start latency.
///
/// A single process-wide stopwatch, started at the first line of `main()`,
/// with [mark] emitting `[boot+NNNNms] label` lines. Active in debug and
/// profile builds (where boot timing matters and `debugPrint` is live) and a
/// no-op in release, so it never costs a shipped user anything.
abstract final class BootTrace {
  static final Stopwatch _sw = Stopwatch();

  /// Called once, at the very top of `main()`.
  static void start() {
    if (kReleaseMode) return;
    if (!_sw.isRunning) _sw.start();
  }

  /// Emits `[boot+NNNNms] label` once the stopwatch is running.
  static void mark(String label) {
    if (kReleaseMode || !_sw.isRunning) return;
    debugPrint('[boot+${_sw.elapsedMilliseconds}ms] $label');
  }
}
