import 'dart:async';

import 'package:ayma_flutter/main.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// NOTE 239 Leg 4 & NOTE 242 Leg 1 — the startup OS location-permission prompt
/// must never fire inside the cold-start window, but must reach the user even
/// when the initial ask is dropped/empty due to a route transition or competing
/// startup dialog (NOTE 242).
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

  test(
      'empty-result retry: retries once settled when first ask returns empty / still denied',
      () async {
    var calls = 0;
    final settles = <Duration>[];
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        // First ask returns empty / still denied (false), retry succeeds (true).
        return calls > 1;
      },
      waitFirstPaint: () async {},
      settle: (d) async => settles.add(d),
      checkPermission: () async => LocationPermission.denied,
    );

    await done;
    expect(calls, 2,
        reason: 'retries once when initial ask returns empty / still denied');
    expect(settles, [startupLocationAskSettle, startupLocationAskRetrySettle],
        reason:
            'waits for initial settle before 1st ask and retry settle before 2nd');
  });

  test('retry is still held until the first frame paints', () async {
    var calls = 0;
    final firstPaint = Completer<void>();
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return calls > 1;
      },
      waitFirstPaint: () => firstPaint.future,
      settle: (_) async {},
      checkPermission: () async => LocationPermission.denied,
    );

    await Future<void>.delayed(Duration.zero);
    expect(calls, 0, reason: 'held on firstPaint gate before first ask');

    firstPaint.complete();
    await done;
    expect(calls, 2, reason: 'both ask and retry run after first paint');
  });

  test('normal case: fires exactly once when first ask is granted', () async {
    var calls = 0;
    final settles = <Duration>[];
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return true;
      },
      waitFirstPaint: () async {},
      settle: (d) async => settles.add(d),
      checkPermission: () async => LocationPermission.whileInUse,
    );

    await done;
    expect(calls, 1,
        reason: 'fires exactly once per path when initially granted');
    expect(settles, [startupLocationAskSettle],
        reason: 'no retry settle needed when granted');
  });

  test('does not retry when permission is deniedForever', () async {
    var calls = 0;
    final settles = <Duration>[];
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return false;
      },
      waitFirstPaint: () async {},
      settle: (d) async => settles.add(d),
      checkPermission: () async => LocationPermission.deniedForever,
    );

    await done;
    expect(calls, 1,
        reason: 'does not retry when permission is permanently denied');
    expect(settles, [startupLocationAskSettle],
        reason: 'no retry settle when denied forever');
  });

  test('retry is bounded: does not retry more than maxRetries', () async {
    var calls = 0;
    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return false;
      },
      waitFirstPaint: () async {},
      settle: (_) async {},
      checkPermission: () async => LocationPermission.denied,
      maxRetries: 1,
    );

    await done;
    expect(calls, 2, reason: 'initial ask (1) + maxRetries (1) = 2 calls total');
  });
}
