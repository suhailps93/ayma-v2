/// Shared "a transient in-app LOAD should silently self-heal before the user
/// ever sees an error" policy (founder 2026-11-01: a failed in-app load — a
/// backend cold-start blip, a transient timeout/5xx/network error — should
/// auto-retry transparently in the background, NOT drop the user on a manual
/// "Retry" screen; only once the retries are exhausted does the manual Retry
/// show as the final fallback).
///
/// This sits ABOVE whatever the HTTP layer already does per request: it covers
/// the case where the WHOLE load still failed. It is only ever applied to
/// idempotent GET-style reads (report / profile loads) — never to a mutating
/// POST, a message send/queue, or sign-in.
library;

/// Backoff before auto-retry attempt N (0-indexed): ~400ms, 900ms, 2s. Its
/// length is also the retry count ([kAutoRetryMax]).
const List<Duration> kAutoRetryBackoff = <Duration>[
  Duration(milliseconds: 400),
  Duration(milliseconds: 900),
  Duration(seconds: 2),
];

/// How many times a failed load is silently retried before the error is
/// surfaced. MUST equal `kAutoRetryBackoff.length` (there is one backoff delay
/// per retry); worst case is the initial attempt + [kAutoRetryMax] retries.
const int kAutoRetryMax = 3;

/// Runs [op] (an idempotent GET-style load), silently retrying a THROWN
/// failure up to [kAutoRetryMax] times with the [kAutoRetryBackoff] delays
/// before rethrowing the last error. A returned result — including a
/// legitimate `null` or empty — is handed back immediately and never retried;
/// only an exception triggers a retry. [retryIf] can exclude a definitive,
/// non-transient failure (e.g. a clean 404 "never existed") from retry; by
/// default every thrown error is treated as transient and retried. Worst case
/// is bounded (at most [kAutoRetryMax] extra attempts + the summed backoff),
/// so it can never retry forever.
Future<T> withAutoRetry<T>(
  Future<T> Function() op, {
  bool Function(Object error)? retryIf,
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await op();
    } catch (e) {
      final transient = retryIf?.call(e) ?? true;
      if (!transient || attempt >= kAutoRetryMax) rethrow;
      await Future<void>.delayed(kAutoRetryBackoff[attempt]);
    }
  }
}
