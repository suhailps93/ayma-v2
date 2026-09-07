import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config/auth_config.dart';

/// Signs a user in with a real credential (§3.3). The app requires sign-in up
/// front — there is no anonymous session — so every method creates or resumes
/// a permanent Firebase account and its stable `uid`.
class AuthService {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  /// Email / password. Tries to sign in; if the account doesn't exist yet,
  /// creates it. Throws [FirebaseAuthException] (`wrong-password`,
  /// `invalid-email`, `weak-password`, …).
  Future<UserCredential> signInWithEmailPassword(
      String email, String password) async {
    final e = email.trim();
    try {
      return await _auth.signInWithEmailAndPassword(
          email: e, password: password);
    } on FirebaseAuthException catch (err) {
      if (err.code == 'user-not-found' || err.code == 'invalid-credential') {
        return _auth.createUserWithEmailAndPassword(
            email: e, password: password);
      }
      rethrow;
    }
  }

  /// Google. Throws [GoogleSignInException] (`canceled` when the user backs
  /// out) or [FirebaseAuthException].
  Future<UserCredential> signInWithGoogle() async {
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId: AuthConfig.googleServerClientId,
      );
      _googleInitialized = true;
    }
    final account =
        await GoogleSignIn.instance.authenticate(scopeHint: const ['email']);
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const _AuthError('Google returned no ID token.');
    }
    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  /// Apple (iOS / macOS only at runtime). Throws
  /// [SignInWithAppleAuthorizationException] on cancel/failure, or a plain
  /// exception when the provider isn't configured yet.
  Future<UserCredential> signInWithApple() async {
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final idToken = appleCredential.identityToken;
    if (idToken == null) {
      throw const _AuthError('Apple returned no identity token.');
    }
    return _auth.signInWithCredential(
      OAuthProvider('apple.com').credential(
        idToken: idToken,
        accessToken: appleCredential.authorizationCode,
      ),
    );
  }

  /// Phone — step 1: send the SMS. [codeSent] fires with a `verificationId` to
  /// pass to [confirmPhoneCode]; [verificationFailed] on error;
  /// [autoSignedIn] (Android auto-retrieval) signs in immediately.
  Future<void> startPhoneSignIn(
    String phoneNumber, {
    required void Function(String verificationId) codeSent,
    required void Function(FirebaseAuthException error) verificationFailed,
    void Function(UserCredential credential)? autoSignedIn,
  }) {
    return _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber.trim(),
      verificationCompleted: (phoneCredential) async {
        try {
          autoSignedIn?.call(
              await _auth.signInWithCredential(phoneCredential));
        } on FirebaseAuthException catch (e) {
          verificationFailed(e);
        }
      },
      verificationFailed: verificationFailed,
      codeSent: (verificationId, _) => codeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  /// Phone — step 2: sign in with the code the user typed.
  Future<UserCredential> confirmPhoneCode(
      String verificationId, String smsCode) {
    return _auth.signInWithCredential(
      PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      ),
    );
  }

  Future<void> signOut() => _auth.signOut();
}

class _AuthError implements Exception {
  const _AuthError(this.message);
  final String message;
  @override
  String toString() => 'AuthError: $message';
}
