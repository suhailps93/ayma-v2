import 'dart:async';

import 'package:ayma_flutter/main.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/location_service.dart';
import 'package:ayma_flutter/services/permission_coordinator.dart';
import 'package:flutter/widgets.dart';
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

  test(
      'retry is held while a competing permission dialog is pending/showing, and fires once the app is idle with no other dialog up',
      () async {
    var calls = 0;
    var competingShowing = true;
    final idleCompleter = Completer<void>();

    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return calls > 1;
      },
      waitFirstPaint: () async {},
      settle: (_) async {},
      checkPermission: () async => LocationPermission.denied,
      isCompetingDialogShowing: () => competingShowing,
      waitForIdle: () => idleCompleter.future,
    );

    // Initial ask executes and returns empty/denied
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1,
        reason:
            'initial ask ran, but retry must be held while competing dialog is showing');

    // Competing dialog finishes, app is now idle
    competingShowing = false;
    idleCompleter.complete();

    await done;
    expect(calls, 2,
        reason: 'retry fires once the app is idle with no other dialog up');
  });

  test(
      'retry is held while PermissionCoordinator has active in-flight requests, and fires once requests finish',
      () async {
    PermissionCoordinator.instance.resetForTest();
    addTearDown(() => PermissionCoordinator.instance.resetForTest());

    var calls = 0;
    PermissionCoordinator.instance.setInFlightRequestsForTest(1);

    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return calls > 1;
      },
      waitFirstPaint: () async {},
      settle: (_) async {},
      checkPermission: () async => LocationPermission.denied,
    );

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1,
        reason:
            'retry is held while PermissionCoordinator has in-flight requests');

    PermissionCoordinator.instance.setInFlightRequestsForTest(0);
    await done;
    expect(calls, 2,
        reason: 'retry fires once in-flight requests are completed');
  });

  test(
      'retry is held while app lifecycle is inactive (competing system dialog showing), and fires once resumed',
      () async {
    PermissionCoordinator.instance.resetForTest();
    addTearDown(() => PermissionCoordinator.instance.resetForTest());

    var calls = 0;
    PermissionCoordinator.instance
        .setLifecycleStateForTest(AppLifecycleState.inactive);

    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return calls > 1;
      },
      waitFirstPaint: () async {},
      settle: (_) async {},
      checkPermission: () async => LocationPermission.denied,
    );

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1,
        reason:
            'retry is held while system permission dialog is showing (app inactive)');

    PermissionCoordinator.instance
        .setLifecycleStateForTest(AppLifecycleState.resumed);
    await done;
    expect(calls, 2,
        reason: 'retry fires once system permission dialog is dismissed (app resumed)');
  });

  test(
      'sequential competing dialogs: retry waits through both notification and mic dialogs before firing',
      () async {
    PermissionCoordinator.instance.resetForTest();
    addTearDown(() => PermissionCoordinator.instance.resetForTest());

    var calls = 0;
    // Notification dialog in flight
    PermissionCoordinator.instance.setInFlightRequestsForTest(1);

    final done = askStartupLocationPermission(
      ask: () async {
        calls++;
        return calls > 1;
      },
      waitFirstPaint: () async {},
      settle: (_) async {},
      checkPermission: () async => LocationPermission.denied,
    );

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: 'held during notification dialog');

    // Notification dialog finishes, but immediately mic dialog starts
    PermissionCoordinator.instance
        .setLifecycleStateForTest(AppLifecycleState.inactive);
    PermissionCoordinator.instance.setInFlightRequestsForTest(0);

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: 'still held during subsequent mic dialog');

    // Mic dialog dismissed, app resumed
    PermissionCoordinator.instance
        .setLifecycleStateForTest(AppLifecycleState.resumed);

    await done;
    expect(calls, 2,
        reason: 'retry fires after all sequential competing dialogs clear');
  });
}
