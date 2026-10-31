import 'dart:async';

import 'package:ayma_flutter/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// `main()` bounds its pre-first-frame network awaits (Firebase / Sentry init)
/// with [guardStartupStep] so a flaky-DNS hang can never stop `runApp` from
/// running (§11.2). These prove the guard's contract: it always returns.
void main() {
  test('returns on timeout even when the step never completes', () async {
    final sw = Stopwatch()..start();
    await guardStartupStep(
      'hang',
      () => Completer<void>().future, // never completes
      limit: const Duration(milliseconds: 200),
    );
    sw.stop();
    // Returned (did not hang) and did so around the deadline, not never.
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('swallows a thrown error and returns', () async {
    // Returning normally (no exception escaping) is the assertion.
    await guardStartupStep(
      'boom',
      () async => throw StateError('init blew up'),
      limit: const Duration(seconds: 1),
    );
  });

  test('awaits a fast step to completion', () async {
    var ran = false;
    await guardStartupStep('ok', () async => ran = true);
    expect(ran, isTrue);
  });
}
