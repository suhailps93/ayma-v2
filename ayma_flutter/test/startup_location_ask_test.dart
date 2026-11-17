import 'dart:async';

import 'package:ayma_flutter/main.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// NOTE 239 Leg 4 — the startup OS location-permission prompt must never fire
/// inside the cold-start window. Firing it there dropped a modal dialog onto a
/// still-stalling main thread (compounding an "input dispatching timed out"
/// ANR) and paused MainActivity behind the dialog, where a memory-pressured
/// first-launch process got silently reaped (app vanished to the launcher, no
/// FATAL). The ask is now gated on the splash's first paint plus a settle.
void main() {
  test('the startup location ask does NOT fire before the first frame paints',
      () async {
    var calls = 0;
    final firstPaint = Completer<void>();
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return true;
      },
      waitFirstPaint: () => firstPaint.future,
      settle: (_) async {},
    );

    // Give microtasks a chance: the ask must still be held on the gate.
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0, reason: 'the prompt must wait for the first frame');

    firstPaint.complete();
    await done;
    expect(calls, 1, reason: 'asks exactly once, after the first frame');
  });

  test('the ask gates on SplashFirstPaint and fires only after the settle',
      () async {
    SplashFirstPaint.resetForTest();
    final savedSettle = startupLocationAskSettle;
    startupLocationAskSettle = Duration.zero;
    addTearDown(() => startupLocationAskSettle = savedSettle);

    var calls = 0;
    // No injected waitFirstPaint: exercises the real SplashFirstPaint.done gate.
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return true;
      },
    );

    await Future<void>.delayed(Duration.zero);
    expect(calls, 0, reason: 'held until the splash reports its first paint');

    SplashFirstPaint.markPainted();
    await done;
    expect(calls, 1);
  });
}
