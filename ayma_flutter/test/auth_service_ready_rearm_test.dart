import 'package:ayma_flutter/services/auth_service.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// Startup audit risk §5: `AuthService.ensureAuthReady` was single-use — after
/// the first completion it returned the first user forever, even after
/// sign-out / sign-in as a different account in the same process. These pin
/// that the completer now re-arms on an identity change.
void main() {
  test('ensureAuthReady re-arms when the signed-in identity changes', () async {
    final svc = AuthService(auth: MockFirebaseAuth());

    svc.notifyAuthSessionRestored(MockUser(uid: 'A'));
    expect((await svc.ensureAuthReady())?.uid, 'A');

    // Idempotent repeat for the same uid: still A, nothing re-armed.
    svc.notifyAuthSessionRestored(MockUser(uid: 'A'));
    expect((await svc.ensureAuthReady())?.uid, 'A');

    // Sign-out: a fresh ensureAuthReady now resolves null.
    svc.notifyAuthSessionRestored(null);
    expect(await svc.ensureAuthReady(), isNull);

    // Sign-in as a DIFFERENT account: ensureAuthReady reflects B, not A.
    svc.notifyAuthSessionRestored(MockUser(uid: 'B'));
    expect((await svc.ensureAuthReady())?.uid, 'B',
        reason: 'the completer must re-arm on a switch, not return A forever');
  });

  test('ensureAuthReady is pending before the first restore, then resolves',
      () async {
    final svc = AuthService(auth: MockFirebaseAuth());
    var resolved = false;
    final f = svc.ensureAuthReady().then((u) {
      resolved = true;
      return u;
    });
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse, reason: 'pending until the first restore');

    svc.notifyAuthSessionRestored(MockUser(uid: 'A'));
    expect((await f)?.uid, 'A');
  });

  test('an initial null settling tick still re-arms to the real user', () async {
    final svc = AuthService(auth: MockFirebaseAuth());
    // Cold-start settling tick fires null first.
    svc.notifyAuthSessionRestored(null);
    expect(await svc.ensureAuthReady(), isNull);
    // Then the real session restores.
    svc.notifyAuthSessionRestored(MockUser(uid: 'A'));
    expect((await svc.ensureAuthReady())?.uid, 'A');
  });
}
