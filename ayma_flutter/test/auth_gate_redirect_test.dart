import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/services/auth_session_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// NOTE 274 (PROFILE fresh install): the router auth gate must never throw
/// `[core/no-app]` when Firebase has not initialized yet (N7 timed out under
/// cold-start pressure). In this unit test Firebase is never initialized, so
/// `Firebase.apps` is empty and the guarded FirebaseAuth read is skipped —
/// exactly the fresh-install race. The gate must fall back to
/// [AuthSessionState] and return a real route, never throw.
void main() {
  tearDown(() => AuthSessionState.instance.clear());

  test('Firebase not initialized + signed-out: protected route -> sign-in, '
      'no core/no-app throw', () {
    AuthSessionState.instance.clear();
    // The bug path: a GoException/[core/no-app] here would land on a dead
    // "Page Not Found". Instead we get a clean redirect.
    expect(authGateRedirect('/plan'), SignInScreen.path);
    expect(authGateRedirect('/profile/me'), SignInScreen.path);
  });

  test('open routes stay reachable signed-out, even with Firebase down', () {
    AuthSessionState.instance.clear();
    expect(authGateRedirect(SplashScreen.path), isNull);
    expect(authGateRedirect(SignInScreen.path), isNull);
    expect(authGateRedirect(TermsScreen.path), isNull);
    // Public share links need no auth.
    expect(authGateRedirect('/s/abc123'), isNull);
    expect(authGateRedirect('/p/xyz'), isNull);
  });

  test('a signed-in session (listener ticked AuthSessionState) is NOT '
      'stranded while Firebase is still coming up', () {
    AuthSessionState.instance.update(signedIn: true, uid: 'u1');
    // Protected route stays; sign-in bounces back to splash.
    expect(authGateRedirect('/plan'), isNull);
    expect(authGateRedirect(SignInScreen.path), SplashScreen.path);
  });
}
