import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../config/auth_config.dart';
import 'profile_service.dart';

/// Signs a user in with a real credential (§3.3). The app requires sign-in up
/// front — there is no anonymous session — so every method creates or resumes
/// a permanent Firebase account and its stable `uid`.
class AuthService {
  AuthService({FirebaseAuth? auth, ProfileService? profileService})
      : _auth = auth ?? FirebaseAuth.instance,
        _profileService =
            profileService ?? ProfileService(auth: auth ?? FirebaseAuth.instance);

  final FirebaseAuth _auth;
  final ProfileService _profileService;
  bool _googleInitialized = false;

  /// Email / password — sign in to an *existing* account. Throws
  /// [FirebaseAuthException] (`user-not-found`, `wrong-password`,
  /// `invalid-credential`, …). This used to silently create an account when
  /// the email was unknown, which made "sign in" and "sign up" one ambiguous
  /// flow — and worse, `invalid-credential` (how newer Firebase reports a
  /// wrong password, for email-enumeration protection) sent a mistyped
  /// password down the create path. The screen now offers the two modes
  /// explicitly, so this only ever signs in.
  Future<UserCredential> signInWithEmailPassword(
      String email, String password) {
    return _auth.signInWithEmailAndPassword(
        email: email.trim(), password: password);
  }

  /// Email / password — create a *new* account. Throws
  /// [FirebaseAuthException] (`email-already-in-use`, `weak-password`,
  /// `invalid-email`, …).
  Future<UserCredential> createAccountWithEmailPassword(
      String email, String password) {
    return _auth.createUserWithEmailAndPassword(
        email: email.trim(), password: password);
  }

  /// Sends Firebase's password-reset email. Throws [FirebaseAuthException]
  /// (`user-not-found`, `invalid-email`, `too-many-requests`, …).
  Future<void> sendPasswordResetEmail(String email) {
    return _auth.sendPasswordResetEmail(email: email.trim());
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
  ///
  /// Apple includes `givenName`/`familyName` on the credential ONLY the very
  /// first time a given Apple ID ever authorizes this app — every later
  /// sign-in comes back with both fields `null`, permanently. So this is the
  /// one chance to capture them; [_captureAppleName] does that best-effort
  /// right after the Firebase sign-in succeeds.
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
    final userCredential = await _auth.signInWithCredential(
      OAuthProvider('apple.com').credential(
        idToken: idToken,
        accessToken: appleCredential.authorizationCode,
      ),
    );
    await captureAppleName(appleCredential, userCredential.user);
    return userCredential;
  }

  /// Persists the one-time name Apple just handed us, if any, so it isn't
  /// lost: (1) onto the Firebase user's `displayName`, which the preboarding
  /// screen already reads to prefill its name step for every other provider,
  /// and (2) onto the structured profile doc's `first_name`/`last_name`,
  /// which that same screen also watches and autofills from (§4.2) — belt
  /// and suspenders, since either path alone getting the timing right is
  /// enough. `givenName`/`familyName` are `null` on every sign-in but the
  /// first, and whenever the user chose to hide their name — in both cases
  /// this is a no-op and the manual-entry onboarding flow stays the fallback,
  /// exactly as today. Never throws — a failure here must not break sign-in.
  ///
  /// Public (not private, and no `@visibleForTesting` — that would pull in a
  /// `meta` dependency this package doesn't otherwise declare) so tests can
  /// drive it directly with a hand-built [AuthorizationCredentialAppleID] —
  /// the real credential only ever comes from Apple's native platform
  /// channel, which unit tests can't invoke.
  Future<void> captureAppleName(
    AuthorizationCredentialAppleID credential,
    User? user,
  ) async {
    final given = credential.givenName?.trim() ?? '';
    final family = credential.familyName?.trim() ?? '';
    if (given.isEmpty && family.isEmpty) return;
    final fullName = [given, family].where((s) => s.isNotEmpty).join(' ');

    if (user != null &&
        (user.displayName == null || user.displayName!.trim().isEmpty)) {
      try {
        await user.updateDisplayName(fullName);
      } catch (_) {
        // Best-effort — sign-in already succeeded, don't fail it over this.
      }
    }

    try {
      await _profileService.updateStructuredFields(
        firstName: given.isEmpty ? null : given,
        lastName: family.isEmpty ? null : family,
      );
    } catch (_) {
      // Best-effort — e.g. no network, or the profile doc path isn't
      // writable yet for a brand-new account.
    }
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

  /// Instagram — step 2 of "Sign in with Instagram" (§8, new). Firebase Auth
  /// has no built-in Instagram provider, so the backend verifies the
  /// Instagram identity via OAuth and mints a custom token
  /// (`POST /instagram/signin` — see `InstagramService.signin`); this just
  /// redeems it for a real Firebase session, same as every other sign-in
  /// method here.
  Future<UserCredential> signInWithInstagramCustomToken(String customToken) {
    return _auth.signInWithCustomToken(customToken);
  }

  Future<void> signOut() => _auth.signOut();
}

class _AuthError implements Exception {
  const _AuthError(this.message);
  final String message;
  @override
  String toString() => 'AuthError: $message';
}
