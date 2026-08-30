import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config/auth_config.dart';

/// Upgrades the current anonymous Firebase session to a real credential
/// **in place** — same `uid`, same wiki, no data migration (ARCHITECTURE §3.3).
///
/// Every method calls `currentUser.linkWithCredential(...)`. On success the
/// anonymous account becomes a permanent account with the linked provider and
/// an unchanged `uid`.
class AuthLinkService {
  AuthLinkService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  bool _googleInitialized = false;

  User get _requireUser {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('No signed-in user to link a credential onto.');
    }
    return user;
  }

  /// Email / password. Throws [FirebaseAuthException] (e.g.
  /// `email-already-in-use`, `credential-already-in-use`, `weak-password`).
  Future<UserCredential> linkEmailPassword(String email, String password) {
    final credential = EmailAuthProvider.credential(
      email: email.trim(),
      password: password,
    );
    return _requireUser.linkWithCredential(credential);
  }

  /// Google. Throws [GoogleSignInException] (`canceled` when the user backs out)
  /// or [FirebaseAuthException] (`credential-already-in-use`).
  Future<UserCredential> linkGoogle() async {
    if (!_googleInitialized) {
      await GoogleSignIn.instance.initialize(
        serverClientId: AuthConfig.googleServerClientId,
      );
      _googleInitialized = true;
    }
    final account = await GoogleSignIn.instance.authenticate(
      scopeHint: const ['email'],
    );
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const _AuthLinkError('Google returned no ID token.');
    }
    final credential = GoogleAuthProvider.credential(idToken: idToken);
    return _requireUser.linkWithCredential(credential);
  }

  /// Apple (iOS / macOS only at runtime). Throws
  /// [SignInWithAppleAuthorizationException] on cancel/failure.
  Future<UserCredential> linkApple() async {
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final idToken = appleCredential.identityToken;
    if (idToken == null) {
      throw const _AuthLinkError('Apple returned no identity token.');
    }
    final oauthCredential = OAuthProvider('apple.com').credential(
      idToken: idToken,
      accessToken: appleCredential.authorizationCode,
    );
    return _requireUser.linkWithCredential(oauthCredential);
  }

  /// Phone — step 1: send the SMS. [codeSent] fires with a `verificationId` to
  /// pass to [confirmPhoneCode]; [verificationFailed] fires on error.
  /// [verificationCompleted] (Android auto-retrieval) links immediately.
  Future<void> startPhoneLink(
    String phoneNumber, {
    required void Function(String verificationId) codeSent,
    required void Function(FirebaseAuthException error) verificationFailed,
    void Function(UserCredential credential)? autoLinked,
  }) {
    return _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber.trim(),
      verificationCompleted: (phoneCredential) async {
        try {
          final result = await _requireUser.linkWithCredential(phoneCredential);
          autoLinked?.call(result);
        } on FirebaseAuthException catch (e) {
          verificationFailed(e);
        }
      },
      verificationFailed: verificationFailed,
      codeSent: (verificationId, _) => codeSent(verificationId),
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  /// Phone — step 2: link with the code the user typed.
  Future<UserCredential> confirmPhoneCode(
    String verificationId,
    String smsCode,
  ) {
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: smsCode.trim(),
    );
    return _requireUser.linkWithCredential(credential);
  }
}

class _AuthLinkError implements Exception {
  const _AuthLinkError(this.message);
  final String message;
  @override
  String toString() => 'AuthLinkError: $message';
}
