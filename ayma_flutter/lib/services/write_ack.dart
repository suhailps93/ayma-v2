import 'api_client.dart' show kInteractiveTimeout;

/// Binds a Firestore write's confirmation to the server ack (PERF_PLAN
/// Phase 1): a `set()`/`update()`/`commit()` future only completes once the
/// server has the write, so awaiting it *is* the ack — but offline it would
/// hang forever. This bounds the wait at the interactive budget and turns an
/// unconfirmed write into a catchable [WriteAckException] instead of a
/// spinner that never settles or a success toast that was never earned.
///
/// The write itself stays queued locally and still lands on reconnect — the
/// caller reports "not confirmed" honestly and can offer Retry (a `set` with
/// merge is idempotent, so a retry after a reconnected landing is harmless).
Future<void> awaitServerAck(
  Future<void> write, {
  Duration timeout = kInteractiveTimeout,
}) =>
    write.timeout(timeout, onTimeout: () => throw const WriteAckException());

/// The server didn't confirm a write within budget (offline, or a mid-session
/// drop). Renders as a plain sentence so screens can interpolate it directly
/// into their `'… failed ($e)'` toasts.
class WriteAckException implements Exception {
  const WriteAckException([
    this.message =
        'the server did not confirm the write — check your connection and retry',
  ]);

  final String message;

  @override
  String toString() => message;
}
