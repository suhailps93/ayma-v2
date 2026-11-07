import 'package:ayma_flutter/services/ui_stall_watchdog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UiStallWatchdog.recordFrame', () {
    test('ignores frames under the threshold', () {
      final watchdog = UiStallWatchdog.forTest();
      watchdog.recordFrame(
        total: const Duration(milliseconds: 16),
        build: const Duration(milliseconds: 8),
        raster: const Duration(milliseconds: 6),
        vsyncOverhead: const Duration(milliseconds: 2),
      );
      watchdog.recordFrame(
        total: const Duration(milliseconds: 200),
        build: const Duration(milliseconds: 120),
        raster: const Duration(milliseconds: 60),
        vsyncOverhead: const Duration(milliseconds: 20),
      );
      expect(watchdog.stalls, isEmpty);
    });

    test('records a build-heavy stall with its phase split', () {
      final watchdog = UiStallWatchdog.forTest();
      watchdog.recordFrame(
        total: const Duration(milliseconds: 3200),
        build: const Duration(milliseconds: 3000),
        raster: const Duration(milliseconds: 120),
        vsyncOverhead: const Duration(milliseconds: 80),
      );
      expect(watchdog.stalls, hasLength(1));
      final stall = watchdog.stalls.single;
      expect(stall.total, const Duration(milliseconds: 3200));
      expect(stall.build, const Duration(milliseconds: 3000));
      expect(stall.raster, const Duration(milliseconds: 120));
      expect(stall.describe(), contains('build 3000ms'));
    });

    test('records a raster-heavy stall distinctly from a build stall', () {
      final watchdog = UiStallWatchdog.forTest();
      watchdog.recordFrame(
        total: const Duration(milliseconds: 1500),
        build: const Duration(milliseconds: 40),
        raster: const Duration(milliseconds: 1400),
        vsyncOverhead: const Duration(milliseconds: 60),
      );
      expect(watchdog.stalls.single.raster,
          const Duration(milliseconds: 1400));
      expect(watchdog.stalls.single.describe(), contains('raster 1400ms'));
    });

    test('keeps only the most recent stalls', () {
      final watchdog = UiStallWatchdog.forTest();
      for (var i = 0; i < 25; i++) {
        watchdog.recordFrame(
          total: Duration(milliseconds: 800 + i),
          build: const Duration(milliseconds: 700),
          raster: const Duration(milliseconds: 50),
          vsyncOverhead: const Duration(milliseconds: 50),
        );
      }
      expect(watchdog.stalls, hasLength(20));
      expect(watchdog.stalls.first.total,
          const Duration(milliseconds: 805));
      expect(watchdog.stalls.last.total, const Duration(milliseconds: 824));
    });
  });

  testWidgets('start() survives real frames and records nothing fast',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    UiStallWatchdog.instance.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Real frames on the test host are far under the threshold; the
    // wiring must simply not crash and not record noise.
    expect(UiStallWatchdog.instance.stalls, isEmpty);
  });
}
