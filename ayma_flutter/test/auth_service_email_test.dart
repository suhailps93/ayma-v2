import 'package:ayma_flutter/services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';

/// The email flow's service contract: sign-in and sign-up are two explicit
/// calls (sign-in no longer silently creates an account on an unknown email
/// — that auto-create is exactly what made the old screen read as having no
/// sign-up), and password reset goes through Firebase's reset email.
class _RecordingAuth extends MockFirebaseAuth {
  final calls = <String>[];
  FirebaseAuthException? signInError;

  @override
  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    calls.add('signIn:$email');
    final e = signInError;
    if (e != null) throw e;
    return super.signInWithEmailAndPassword(email: email, password: password);
  }

  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) {
    calls.add('create:$email');
    return super
        .createUserWithEmailAndPassword(email: email, password: password);
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    ActionCodeSettings? actionCodeSettings,
  }) {
    calls.add('reset:$email');
    return super.sendPasswordResetEmail(
        email: email, actionCodeSettings: actionCodeSettings);
  }
}

void main() {
  test('signInWithEmailPassword only signs in — trims the email', () async {
    final mock = _RecordingAuth();
    final service = AuthService(auth: mock);

    await service.signInWithEmailPassword(' a@b.com ', 'secret1');

    expect(mock.calls, ['signIn:a@b.com']);
  });

  test(
      'signInWithEmailPassword rethrows unknown-email instead of '
      'auto-creating an account', () async {
    final mock = _RecordingAuth()
      ..signInError = FirebaseAuthException(code: 'user-not-found');
    final service = AuthService(auth: mock);

    await expectLater(
      service.signInWithEmailPassword('a@b.com', 'secret1'),
      throwsA(isA<FirebaseAuthException>()
          .having((e) => e.code, 'code', 'user-not-found')),
    );
    expect(mock.calls.where((c) => c.startsWith('create:')), isEmpty);
  });

  test(
      'signInWithEmailPassword rethrows invalid-credential (a wrong '
      'password) instead of auto-creating', () async {
    final mock = _RecordingAuth()
      ..signInError = FirebaseAuthException(code: 'invalid-credential');
    final service = AuthService(auth: mock);

    await expectLater(
      service.signInWithEmailPassword('a@b.com', 'oops'),
      throwsA(isA<FirebaseAuthException>()
          .having((e) => e.code, 'code', 'invalid-credential')),
    );
    expect(mock.calls.where((c) => c.startsWith('create:')), isEmpty);
  });

  test('createAccountWithEmailPassword calls createUser', () async {
    final mock = _RecordingAuth();
    final service = AuthService(auth: mock);

    await service.createAccountWithEmailPassword(' new@b.com ', 'secret1');

    expect(mock.calls, ['create:new@b.com']);
    expect(mock.currentUser?.email, 'new@b.com');
  });

  test('sendPasswordResetEmail forwards the trimmed email', () async {
    final mock = _RecordingAuth();
    final service = AuthService(auth: mock);

    await service.sendPasswordResetEmail(' a@b.com ');

    expect(mock.calls, ['reset:a@b.com']);
  });
}
