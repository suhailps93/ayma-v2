import 'dart:async';

import '../services/api_client.dart';

/// Cold-start-tolerant retry for on-open data loads (founder bug, 2026-11-03:
/// "I would rather have it load until failure").
///
/// The staging backend scales to zero, so the first request after idle pays a
/// Cloud Run cold start (~18s+). A screen that fetches on open with the default
/// ~8s interactive budget therefore hard-fails on that first cold request. This
/// helper lets such loads ride through the cold start: it auto-retries a
/// transient failure with exponential backoff over a generous overall budget,
/// and only surfaces the failure (so the caller shows its manual Retry state)
/// once that whole budget is spent — never on the first timeout. It mirrors the
/// splash's bootstrap retry (`splash_screen.dart`) so every primary load heals
/// the same way.
///
/// Distinct from `services/auto_retry.dart` (`withAutoRetry`) on purpose: that
/// policy is a *fast* silent self-heal for a transient blip against an
/// already-warm backend (short ~400ms/900ms/2s backoff, default 8s per call).
/// This one is sized for a scale-to-zero COLD START: it pairs a raised
/// per-call timeout ([kColdStartCallTimeout], so the first call can itself ride
/// an ~18s+ cold start) with a long exponential backoff over a generous overall
/// [kColdStartBudget]. The report family (`LivingReportView`) keeps using
/// `withAutoRetry`; the on-open loads that were hard-failing on cold start use
/// this.

/// Per-call timeout for a cold-start-sensitive first fetch. Longer than the
/// interactive budget so a single call can itself complete through a ~18s+ cold
/// start, instead of timing out and relying solely on a later retry.
const kColdStartCallTimeout = Duration(seconds: 20);

/// Exponential backoff gaps between cold-start retries: 1s, 2s, 4s, 8s (capped).
const kColdStartBackoff = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// Overall backoff budget for a cold-start load: the total time spent *waiting
/// between* retries before the load gives up and the caller shows its manual
/// Retry affordance. Bounds only the backoff (not the per-call time, which
/// [kColdStartCallTimeout] bounds), which keeps the loop deterministic under a
/// test's fake clock. Comfortably spans a Cloud Run cold start plus retries.
const kColdStartBudget = Duration(seconds: 45);

/// Whether [error] is a transient, worth-retrying failure (network / timeout /
/// 5xx) rather than a deterministic client error. Mirrors the splash's
/// classifier: a status-less [ApiException] (timeout / DNS / socket), a 408
/// (client-side budget timeout), a 429, or any 5xx is retryable; a definite
/// other 4xx (incl. 401/403) is not, and a raw [TimeoutException] is transient.
bool isColdStartRetryable(Object error) {
  if (error is ApiException) {
    final s = error.statusCode;
    if (s == null) return true;
    return s == 408 || s == 429 || s >= 500;
  }
  return error is TimeoutException;
}

/// Runs [attempt] with cold-start-tolerant auto-retry and returns its first
/// success.
///
/// Retries only failures accepted by [retryable], waiting [backoff] gaps
/// between tries, until [budget] is spent — then rethrows the last error so the
/// caller can show its manual "couldn't load — Retry" state ONLY after
/// sustained failure, never on the first timeout. A non-retryable error (e.g. a
/// 401) is rethrown immediately. [onRetry] fires before each wait, so a caller
/// can surface a quiet "Reconnecting…" hint while staying in its loading state.
Future<T> withColdStartRetry<T>(
  Future<T> Function() attempt, {
  Duration budget = kColdStartBudget,
  List<Duration> backoff = kColdStartBackoff,
  bool Function(Object error) retryable = isColdStartRetryable,
  void Function()? onRetry,
}) async {
  var waited = Duration.zero;
  var i = 0;
  while (true) {
    try {
      return await attempt();
    } catch (e) {
      if (!retryable(e)) rethrow;
      final gap = backoff[i < backoff.length ? i : backoff.length - 1];
      // Stop once the next wait would push the summed backoff past the budget:
      // give up now rather than start a retry we can't honour. Enforcing the
      // budget by summing the waits (not a wall-clock deadline) keeps this loop
      // deterministic under a widget test's fake clock.
      if (waited + gap > budget) rethrow;
      onRetry?.call();
      await Future<void>.delayed(gap);
      waited += gap;
      i++;
    }
  }
}
