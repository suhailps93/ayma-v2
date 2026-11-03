import 'dart:async';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/util/cold_start_retry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the shared cold-start retry helper (`withColdStartRetry`) and
/// its transient-error classifier. Tiny backoff durations keep these fast.
void main() {
  const fast = [Duration(milliseconds: 1), Duration(milliseconds: 1)];

  group('isColdStartRetryable', () {
    test('network / timeout / 408 / 429 / 5xx are retryable', () {
      expect(isColdStartRetryable(ApiException('x')), isTrue); // null status
      expect(isColdStartRetryable(ApiException('x', statusCode: 408)), isTrue);
      expect(isColdStartRetryable(ApiException('x', statusCode: 429)), isTrue);
      expect(isColdStartRetryable(ApiException('x', statusCode: 500)), isTrue);
      expect(isColdStartRetryable(ApiException('x', statusCode: 503)), isTrue);
      expect(isColdStartRetryable(TimeoutException('t')), isTrue);
    });

    test('a definite other 4xx is NOT retryable', () {
      expect(isColdStartRetryable(ApiException('x', statusCode: 400)), isFalse);
      expect(isColdStartRetryable(ApiException('x', statusCode: 401)), isFalse);
      expect(isColdStartRetryable(ApiException('x', statusCode: 403)), isFalse);
      expect(isColdStartRetryable(ApiException('x', statusCode: 404)), isFalse);
    });
  });

  test('returns the first success without retrying', () async {
    var calls = 0;
    final r = await withColdStartRetry(() async {
      calls++;
      return 'ok';
    }, backoff: fast);
    expect(r, 'ok');
    expect(calls, 1);
  });

  test('retries a transient failure, then succeeds (never surfaces it)',
      () async {
    var calls = 0;
    final r = await withColdStartRetry(() async {
      calls++;
      if (calls <= 2) throw ApiException('cold', statusCode: 503);
      return 'ok';
    }, backoff: fast);
    expect(r, 'ok');
    expect(calls, 3);
  });

  test('a non-retryable error is rethrown immediately (no retry)', () async {
    var calls = 0;
    await expectLater(
      withColdStartRetry(() async {
        calls++;
        throw ApiException('no', statusCode: 401);
      }, backoff: fast),
      throwsA(isA<ApiException>()),
    );
    expect(calls, 1);
  });

  test('gives up once the backoff budget is spent, rethrowing the last error',
      () async {
    var calls = 0;
    await expectLater(
      withColdStartRetry(
        () async {
          calls++;
          throw ApiException('down', statusCode: 503);
        },
        backoff: const [Duration(milliseconds: 1), Duration(milliseconds: 1)],
        budget: const Duration(milliseconds: 2),
      ),
      throwsA(isA<ApiException>()),
    );
    // budget 2ms, 1ms gaps: waits of 1ms then 1ms fit (summed 2ms), a third
    // would exceed the budget → initial attempt + 2 retries = 3 calls.
    expect(calls, 3);
  });

  test('onRetry fires once per scheduled retry', () async {
    var retries = 0;
    var calls = 0;
    await withColdStartRetry(() async {
      calls++;
      if (calls <= 2) throw ApiException('x', statusCode: 503);
      return 1;
    }, backoff: fast, onRetry: () => retries++);
    expect(retries, 2);
  });
}
