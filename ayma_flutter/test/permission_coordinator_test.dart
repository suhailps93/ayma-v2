import 'dart:async';

import 'package:ayma_flutter/services/permission_coordinator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    PermissionCoordinator.instance.resetForTest();
  });

  tearDown(() {
    PermissionCoordinator.instance.resetForTest();
  });

  test('reports not showing when idle with no in-flight requests', () {
    expect(PermissionCoordinator.instance.isCompetingDialogShowing, isFalse);
    expect(PermissionCoordinator.instance.inFlightRequests, 0);
  });

  test('reports showing while trackRequest is executing', () async {
    final completer = Completer<String>();
    final future = PermissionCoordinator.instance.trackRequest(
      () => completer.future,
    );

    expect(PermissionCoordinator.instance.inFlightRequests, 1);
    expect(PermissionCoordinator.instance.isCompetingDialogShowing, isTrue);

    completer.complete('done');
    final result = await future;

    expect(result, 'done');
    expect(PermissionCoordinator.instance.inFlightRequests, 0);
    expect(PermissionCoordinator.instance.isCompetingDialogShowing, isFalse);
  });

  test('decrements inFlightRequests even when trackRequest throws', () async {
    await expectLater(
      PermissionCoordinator.instance.trackRequest(() async {
        throw StateError('failed');
      }),
      throwsStateError,
    );

    expect(PermissionCoordinator.instance.inFlightRequests, 0);
    expect(PermissionCoordinator.instance.isCompetingDialogShowing, isFalse);
  });

  test('decrements inFlightRequests when trackRequest times out', () async {
    final completer = Completer<void>();
    await expectLater(
      PermissionCoordinator.instance.trackRequest(
        () => completer.future,
        timeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(PermissionCoordinator.instance.inFlightRequests, 0);
    expect(PermissionCoordinator.instance.isCompetingDialogShowing, isFalse);
  });

  test('waitForIdle returns immediately when no competing dialog is showing',
      () async {
    final stopwatch = Stopwatch()..start();
    await PermissionCoordinator.instance.waitForIdle();
    stopwatch.stop();

    expect(stopwatch.elapsedMilliseconds, lessThan(100));
  });

  test('waitForIdle waits until in-flight requests complete', () async {
    final completer = Completer<void>();
    unawaited(PermissionCoordinator.instance.trackRequest(
      () => completer.future,
    ));

    var idleDone = false;
    unawaited(PermissionCoordinator.instance.waitForIdle().then((_) {
      idleDone = true;
    }));

    await Future<void>.delayed(Duration.zero);
    expect(idleDone, isFalse);

    completer.complete();
    await Future<void>.delayed(Duration.zero);
    expect(idleDone, isTrue);
  });

  test('waitForIdle waits until lifecycle resumes from inactive state',
      () async {
    PermissionCoordinator.instance
        .setLifecycleStateForTest(AppLifecycleState.inactive);

    var idleDone = false;
    unawaited(PermissionCoordinator.instance.waitForIdle().then((_) {
      idleDone = true;
    }));

    await Future<void>.delayed(Duration.zero);
    expect(idleDone, isFalse);

    PermissionCoordinator.instance
        .setLifecycleStateForTest(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(idleDone, isTrue);
  });
}
