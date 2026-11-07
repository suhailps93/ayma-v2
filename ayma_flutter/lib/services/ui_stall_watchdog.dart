import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// One recorded UI stall: a single frame whose total span blew far past
/// the frame budget, with the phase split that says WHERE the time went —
/// build (Dart widget build + layout on the UI isolate), raster (the
/// raster thread compositing), or vsync overhead (time the frame spent
/// waiting to start, e.g. because an earlier frame was still busy).
class UiStall {
  const UiStall({
    required this.at,
    required this.total,
    required this.build,
    required this.raster,
    required this.vsyncOverhead,
  });

  final DateTime at;
  final Duration total;
  final Duration build;
  final Duration raster;
  final Duration vsyncOverhead;

  String describe() =>
      'frame ${total.inMilliseconds}ms (build ${build.inMilliseconds}ms, '
      'raster ${raster.inMilliseconds}ms, '
      'vsync ${vsyncOverhead.inMilliseconds}ms)';
}

/// Watches frame timings and records any frame that stalls the UI thread
/// past [threshold], logging a `[stall]` line with the phase split.
///
/// Why this exists (Scout NOTE 133): the 2026-11-07 02:41 ANR on the
/// practice composer ("Input dispatching timed out — waited 5001ms for
/// KeyEvent", build 2332) killed the process, but the ANR trace was taken
/// after the blocking work had finished — every thread was idle in the
/// dump, so the blocking call is unrecoverable from it, and profiling the
/// practice typing path in isolation shows a 2–4 ms keystroke frame that
/// does not grow with history. The next stall on ANY screen now names
/// itself in logcat at the moment it happens: a build-heavy split points
/// at Dart build/layout work, a raster-heavy split at compositing, and a
/// frame that is unremarkable in every phase never gets recorded (the
/// input queue starved some other way — platform side, not frame work).
class UiStallWatchdog {
  UiStallWatchdog._();

  static final UiStallWatchdog instance = UiStallWatchdog._();

  /// A fresh, unstarted recorder for tests (the singleton's ring buffer
  /// is shared app-wide and would leak between tests).
  @visibleForTesting
  factory UiStallWatchdog.forTest() => UiStallWatchdog._();

  /// A frame must exceed this total span to count as a stall. Normal
  /// frames are ~16 ms; even a heavy navigation frame stays well under
  /// 200 ms on the bench emulator. 700 ms is far below the 5 s input
  /// ANR, so a march toward an ANR shows up as a run of these first.
  static const Duration threshold = Duration(milliseconds: 700);

  static const int _keep = 20;

  final List<UiStall> _stalls = <UiStall>[];

  /// The most recent stalls, oldest first, capped at the last [_keep].
  List<UiStall> get stalls => List<UiStall>.unmodifiable(_stalls);

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      recordFrame(
        total: timing.totalSpan,
        build: timing.buildDuration,
        raster: timing.rasterDuration,
        vsyncOverhead: timing.vsyncOverhead,
      );
    }
  }

  /// Records one frame's phase split if its total span crosses
  /// [threshold]. Split out from the timings callback for tests.
  @visibleForTesting
  void recordFrame({
    required Duration total,
    required Duration build,
    required Duration raster,
    required Duration vsyncOverhead,
  }) {
    if (total < threshold) return;
    final stall = UiStall(
      at: DateTime.now(),
      total: total,
      build: build,
      raster: raster,
      vsyncOverhead: vsyncOverhead,
    );
    _stalls.add(stall);
    if (_stalls.length > _keep) _stalls.removeAt(0);
    debugPrint('[stall] ${stall.describe()}');
  }
}
