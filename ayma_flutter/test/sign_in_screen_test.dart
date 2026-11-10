import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/legal/biometric_consent_text.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/screens/sign_in_critical_consent_dialog.dart';
import 'package:ayma_flutter/screens/biometric_info_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/biometric_consent.dart';
import 'package:ayma_flutter/services/legal_links.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_auth_mocks/src/mock_user_credential.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuth extends AuthService {
  _FakeAuth() : super(auth: MockFirebaseAuth());
  final List<String> calls = [];

  /// When set, the next sign-in / create / reset call throws this.
  Object? nextError;

  /// When true, the next email sign-in succeeds with a mock credential.
  bool succeedSignIn = false;

  /// When set, signInWithGoogle returns this future (for simulating in-flight/hung calls).
  Future<UserCredential>? hangGoogle;

  Never _throwNext() {
    final e = nextError!;
    nextError = null;
    throw e;
  }

  @override
  Future<UserCredential> signInWithGoogle() async {
    calls.add('google');
    if (hangGoogle != null) return hangGoogle!;
    if (nextError != null) _throwNext();
    if (succeedSignIn) {
      succeedSignIn = false;
      return MockUserCredential(false);
    }
    throw StateError('stubbed');
  }

  @override
  Future<UserCredential> signInWithEmailPassword(
      String email, String password) async {
    calls.add('signIn:$email');
    if (nextError != null) _throwNext();
    if (succeedSignIn) {
      succeedSignIn = false;
      return MockUserCredential(false);
    }
    throw StateError('stubbed');
  }

  @override
  Future<UserCredential> createAccountWithEmailPassword(
      String email, String password) async {
    calls.add('create:$email');
    if (nextError != null) _throwNext();
    throw StateError('stubbed');
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    calls.add('reset:$email');
    if (nextError != null) _throwNext();
  }
}

/// Inert voice controller so the greeting orb never opens a real session.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());
  bool _active = false;
  void setVoiceActive(bool v) {
    _active = v;
    notifyListeners();
  }
  @override
  bool get isActive => _active;
  @override
  Future<void> start({bool forceRelayFirst = false}) async {
    _active = true;
    notifyListeners();
  }
  @override
  Future<void> stop() async {
    _active = false;
    notifyListeners();
  }
}

/// Ticks the two required clickwrap boxes (Terms/Privacy, face recognition).
Future<void> _acceptConsents(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('signin_terms_checkbox')));
  await tester.tap(find.byKey(const Key('signin_biometric_checkbox')));
  await tester.pump();
}

Future<void> _pump(WidgetTester tester, _FakeAuth auth,
    {bool accept = true, ApiClient? apiClient}) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: SignInScreen(
        auth: auth, voiceController: _FakeVoice(), apiClient: apiClient),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  if (accept) await _acceptConsents(tester);
}

/// Opens the email stage (sign-in mode).
Future<void> _openEmail(WidgetTester tester, _FakeAuth auth,
    {ApiClient? apiClient}) async {
  await _pump(tester, auth, apiClient: apiClient);
  await tester.tap(find.text('Email'));
  await tester.pump();
}

/// An ApiClient whose POST /auth/email-exists answers [exists] (or [status]),
/// recording every email it was asked about in [asked].
ApiClient _oracle({bool? exists, int status = 200, List<String>? asked}) {
  return ApiClient(
    httpClient: MockClient((req) async {
      expect(req.url.path, '/auth/email-exists');
      asked?.add((jsonDecode(req.body) as Map)['email'] as String? ?? '');
      if (status != 200) return http.Response('boom', status);
      return http.Response(jsonEncode({'exists': exists}), 200,
          headers: {'content-type': 'application/json'});
    }),
    auth: MockFirebaseAuth(),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('sign-in stays disabled until both separate boxes are ticked, '
      'and the face-recognition consent is held for after sign-in',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth, accept: false);

    final terms = find.byKey(const Key('signin_terms_checkbox'));
    final bio = find.byKey(const Key('signin_biometric_checkbox'));
    expect(tester.widget<CheckboxListTile>(terms).value, isFalse);
    expect(tester.widget<CheckboxListTile>(bio).value, isFalse);
    expect(find.textContaining(kBiometricConsentSignInLine), findsOneWidget);

    await tester.tap(find.text('Google'));
    await tester.tap(find.text('Email'));
    await tester.pump();
    expect(auth.calls, isEmpty);
    expect(find.widgetWithText(TextField, 'Email'), findsNothing);

    await tester.tap(terms);
    await tester.pump();
    await tester.tap(find.text('Google'));
    await tester.pump();
    expect(auth.calls, isEmpty, reason: 'Terms alone is not enough');

    await tester.tap(bio);
    await tester.pump();
    expect(await PendingBiometricConsent.read(), kBiometricConsentVersion);
    await tester.tap(find.text('Google'));
    await tester.pump();
    expect(auth.calls, ['google']);

    await tester.tap(bio);
    await tester.pump();
    expect(await PendingBiometricConsent.read(), isNull);
  });

  testWidgets('shows the provider choices and a Terms line', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.textContaining('Terms'), findsOneWidget);
    expect(
      find.textContaining('including use of my data for advertising',
          findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets(
      'the email choice reveals a sign-in form: email + password, '
      'a Sign in button, Forgot password?, and a Sign up switch',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Don’t have an account? Sign up'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(auth.calls, contains('signIn:a@b.com'));
    expect(auth.calls.where((c) => c.startsWith('create:')), isEmpty);
  });

  testWidgets(
      'the mode switch flips to Create account (confirm-password field, '
      'button label, footer) and back', (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsOneWidget);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text('Already have an account? Sign in'), findsOneWidget);

    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('sign-up mode calls createAccount, not signIn', (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);
    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'new@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();

    expect(auth.calls, contains('create:new@b.com'));
    expect(auth.calls.where((c) => c.startsWith('signIn:')), isEmpty);
  });

  testWidgets(
      'the referral field appears only in sign-up mode and is optional',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);
    expect(find.widgetWithText(TextField, 'Referral code (optional)'),
        findsNothing);

    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Referral code (optional)'),
        findsOneWidget);

    // Left empty, sign-up still proceeds to createAccount.
    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'new@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();
    expect(auth.calls, contains('create:new@b.com'));
  });

  testWidgets('a typed referral code is passed to POST /referral/redeem '
      'right after the account is created', (tester) async {
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Real AuthService over MockFirebaseAuth: createAccount genuinely
    // succeeds, so the post-create redeem call actually fires.
    final mockAuth = MockFirebaseAuth();
    final auth = AuthService(auth: mockAuth);
    final redeemed = <String>[];
    final api = ApiClient(
      httpClient: MockClient((req) async {
        if (req.url.path == '/referral/redeem') {
          redeemed
              .add((jsonDecode(req.body) as Map)['code'] as String? ?? '');
          return http.Response(jsonEncode({'applied': true}), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 200);
      }),
      auth: mockAuth,
    );
    final router = GoRouter(
      initialLocation: SignInScreen.path,
      routes: [
        GoRoute(
          path: SignInScreen.path,
          builder: (_, __) => SignInScreen(
            auth: auth,
            voiceController: _FakeVoice(),
            apiClient: api,
          ),
        ),
        GoRoute(
          path: SplashScreen.path,
          builder: (_, __) => const Scaffold(body: Text('SPLASH')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await _acceptConsents(tester);

    await tester.tap(find.text('Email'));
    await tester.pump();
    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'new@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'secret1');
    await tester.enterText(
        find.widgetWithText(TextField, 'Referral code (optional)'),
        'FRIEND7');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();

    expect(redeemed, ['FRIEND7']);
    expect(find.text('SPLASH'), findsOneWidget);
  });

  testWidgets('sign-up mode refuses mismatched passwords locally',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);
    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'new@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'different');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();

    expect(auth.calls, isEmpty);
    expect(find.text('Those passwords don’t match.'), findsOneWidget);
  });

  testWidgets(
      'Forgot password? sends the reset email and shows the confirmation',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pump();

    expect(auth.calls, contains('reset:a@b.com'));
    expect(
      find.text('Check your email — we sent a reset link to a@b.com.'),
      findsOneWidget,
    );
  });

  testWidgets('Forgot password? with no email prompts for one, sends nothing',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    await tester.tap(find.text('Forgot password?'));
    await tester.pump();

    expect(auth.calls, isEmpty);
    expect(
      find.text('Enter your email above first, then tap “Forgot password?”.'),
      findsOneWidget,
    );
  });

  testWidgets('Forgot password? maps unknown-email to a friendly message',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    auth.nextError = FirebaseAuthException(code: 'user-not-found');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pump();

    expect(
      find.text('No account with that email — tap “Sign up” to create one.'),
      findsOneWidget,
    );
    expect(find.textContaining('user-not-found'), findsNothing);
  });

  String fieldText(WidgetTester tester, String label) =>
      tester.widget<TextField>(find.widgetWithText(TextField, label))
          .controller!
          .text;

  testWidgets(
      'unknown email: invalid-credential + oracle says not-exists '
      'auto-switches into create mode: confirm field, a nudge, '
      'a back-to-login toggle, typed values kept — no raw code leak',
      (tester) async {
    final auth = _FakeAuth();
    final asked = <String>[];
    await _openEmail(tester, auth,
        apiClient: _oracle(exists: false, asked: asked));

    // Starts in sign-in mode.
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);

    // Newer Firebase lumps unknown-email AND wrong-password into this code —
    // the oracle breaks the tie; here the email is unknown.
    auth.nextError = FirebaseAuthException(code: 'invalid-credential');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    // The sign-in was attempted, the oracle was asked, then the UI flipped.
    expect(auth.calls, contains('signIn:a@b.com'));
    expect(asked, ['a@b.com']);
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsOneWidget);
    expect(
      find.text('New here? Confirm your password to create your account.'),
      findsOneWidget,
    );
    // Always a way back to login.
    expect(find.text('Already have an account? Sign in'), findsOneWidget);
    // Typed email + password are kept.
    expect(fieldText(tester, 'Email'), 'a@b.com');
    expect(fieldText(tester, 'Password'), 'secret1');
    // Raw Firebase code never surfaces.
    expect(find.textContaining('invalid-credential'), findsNothing);
  });

  testWidgets(
      'existing email + wrong password: invalid-credential + oracle says '
      'exists STAYS on sign-in with a wrong-password error — never flips',
      (tester) async {
    final auth = _FakeAuth();
    final asked = <String>[];
    await _openEmail(tester, auth,
        apiClient: _oracle(exists: true, asked: asked));

    auth.nextError = FirebaseAuthException(code: 'invalid-credential');
    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'test1@gmail.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'wrongpw1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(auth.calls, contains('signIn:test1@gmail.com'));
    expect(asked, ['test1@gmail.com']);
    // Still the sign-in form: no confirm field, no Create-account button.
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(find.text('That password is wrong — try again.'), findsOneWidget);
    expect(find.textContaining('invalid-credential'), findsNothing);
  });

  testWidgets(
      'user-not-found on sign-in auto-switches into create mode without '
      'asking the oracle (the code itself means unknown email)',
      (tester) async {
    final auth = _FakeAuth();
    final asked = <String>[];
    await _openEmail(tester, auth,
        apiClient: _oracle(exists: true, asked: asked));

    auth.nextError = FirebaseAuthException(code: 'user-not-found');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsOneWidget);
    expect(find.textContaining('user-not-found'), findsNothing);
    expect(asked, isEmpty);
  });

  testWidgets(
      'an explicit wrong-password error stays on sign-in with the '
      'wrong-password message (no oracle needed)', (tester) async {
    final auth = _FakeAuth();
    final asked = <String>[];
    await _openEmail(tester, auth,
        apiClient: _oracle(exists: false, asked: asked));

    auth.nextError = FirebaseAuthException(code: 'wrong-password');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(find.text('That password is wrong — try again.'), findsOneWidget);
    expect(asked, isEmpty);
  });

  testWidgets(
      'oracle failure on a failed sign-in stays on sign-in with the generic '
      'error — never flips on a guess', (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth, apiClient: _oracle(status: 503));

    auth.nextError = FirebaseAuthException(code: 'invalid-credential');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(
      find.text('That email and password don’t match. New here? '
          'Tap “Sign up” below.'),
      findsOneWidget,
    );
  });

  testWidgets('correct password signs in and routes to splash (control leg)',
      (tester) async {
    final auth = _FakeAuth()..succeedSignIn = true;
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: SignInScreen.path,
      routes: [
        GoRoute(
          path: SignInScreen.path,
          builder: (_, __) => SignInScreen(
              auth: auth, voiceController: _FakeVoice()),
        ),
        GoRoute(
          path: SplashScreen.path,
          builder: (_, __) => const Text('SPLASH'),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await _acceptConsents(tester);
    await tester.tap(find.text('Email'));
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(auth.calls, contains('signIn:a@b.com'));
    expect(find.text('SPLASH'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsNothing);
  });

  testWidgets(
      'email-already-in-use on create returns to sign-in '
      'with a check-your-password nudge', (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth, apiClient: _oracle(exists: false));

    // Unknown email → arrives as invalid-credential, oracle says not-exists →
    // auto-switch to create.
    auth.nextError = FirebaseAuthException(code: 'invalid-credential');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Create account'), findsOneWidget);

    // They confirm; the account already exists, so we bounce back to sign-in.
    auth.nextError = FirebaseAuthException(code: 'email-already-in-use');
    await tester.enterText(
        find.widgetWithText(TextField, 'Confirm password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();

    expect(auth.calls, contains('create:a@b.com'));
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(
      find.text('You already have an account — check your password.'),
      findsOneWidget,
    );
    expect(find.textContaining('email-already-in-use'), findsNothing);
  });

  testWidgets(
      'Google sign-in error surfaces descriptive toast on configuration failure',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = const GoogleSignInException(
      code: GoogleSignInExceptionCode.clientConfigurationError,
      description: 'GoogleSignatureVerifier: package info is not set correctly',
    );
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(
      find.text(
          'Google sign-in failed: GoogleSignatureVerifier: package info is not set correctly.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Google sign-in canceled by user surfaces no error toast',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = const GoogleSignInException(
      code: GoogleSignInExceptionCode.canceled,
    );
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Google sign-in failed'), findsNothing);
  });

  testWidgets(
      'cancelling Google sign-in (canceled code) clears busy state and allows tapping Email',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = const GoogleSignInException(
      code: GoogleSignInExceptionCode.canceled,
    );
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Signing you in'), findsNothing);

    // Tapping Email button immediately works and reveals the email stage
    await tester.tap(find.text('Email'));
    await tester.pump();

    expect(find.text('Password'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets(
      'cancelling Google sign-in (interrupted code) clears busy state without toast and allows tapping Email',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = const GoogleSignInException(
      code: GoogleSignInExceptionCode.interrupted,
    );
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Signing you in'), findsNothing);

    await tester.tap(find.text('Email'));
    await tester.pump();

    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets(
      'cancelling Google sign-in (PlatformException sign_in_canceled) clears busy state without toast and allows tapping Email',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = PlatformException(
      code: 'sign_in_canceled',
      message: 'Sign in was canceled.',
    );
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('Signing you in'), findsNothing);

    await tester.tap(find.text('Email'));
    await tester.pump();

    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets(
      'in-flight Google sign-in can be cancelled via Cancel button, re-enabling Email',
      (tester) async {
    final auth = _FakeAuth();
    final completer = Completer<UserCredential>();
    auth.hangGoogle = completer.future;
    await _pump(tester, auth);

    await tester.tap(find.text('Google'));
    await tester.pump();

    // Loader is visible with Cancel button
    expect(find.textContaining('Signing you in'), findsOneWidget);
    expect(find.byKey(const Key('signin_cancel_busy_btn')), findsOneWidget);

    // Tap Cancel
    await tester.tap(find.byKey(const Key('signin_cancel_busy_btn')));
    await tester.pump();

    // Busy loader is gone
    expect(find.textContaining('Signing you in'), findsNothing);

    // Email button is now clickable and opens the email form
    await tester.tap(find.text('Email'));
    await tester.pump();

    expect(find.text('Password'), findsOneWidget);

    // Late completion of the hung call does not navigate or throw
    completer.complete(MockUserCredential(false));
    await tester.pump();
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets(
      'in-flight Google sign-in cancelled via back-press (PopScope) re-enables Email',
      (tester) async {
    final auth = _FakeAuth();
    final completer = Completer<UserCredential>();
    auth.hangGoogle = completer.future;
    await _pump(tester, auth);

    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(find.textContaining('Signing you in'), findsOneWidget);

    // Simulate system back button invocation via PopScope
    final dynamic popScope =
        tester.widget(find.byWidgetPredicate((w) => w is PopScope));
    popScope.onPopInvokedWithResult(false, null);
    await tester.pump();

    expect(find.textContaining('Signing you in'), findsNothing);

    await tester.tap(find.text('Email'));
    await tester.pump();

    expect(find.text('Password'), findsOneWidget);
    completer.complete(MockUserCredential(false));
    await tester.pump();
  });

  testWidgets(
      'in-flight Google sign-in auto-resets busy state on app resume timeout',
      (tester) async {
    final auth = _FakeAuth();
    final completer = Completer<UserCredential>();
    auth.hangGoogle = completer.future;
    await _pump(tester, auth);

    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(find.textContaining('Signing you in'), findsOneWidget);

    // Simulate app resume after picker dismissal
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    // Still busy during the 1500ms grace window
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.textContaining('Signing you in'), findsOneWidget);

    // Expires at 1500ms
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('Signing you in'), findsNothing);

    await tester.tap(find.text('Email'));
    await tester.pump();

    expect(find.text('Password'), findsOneWidget);
    completer.complete(MockUserCredential(false));
    await tester.pump();
  });

  testWidgets(
      'active voice session on sign-in screen does not block focusing or typing in email/password fields',
      (tester) async {
    final auth = _FakeAuth();
    final voice = _FakeVoice();
    voice.setVoiceActive(true);

    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SignInScreen(
        auth: auth,
        voiceController: voice,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await _acceptConsents(tester);

    // Open email stage
    await tester.tap(find.text('Email'));
    await tester.pump();

    // Enter email and password while voice session is active
    await tester.enterText(find.byType(TextField).first, 'test1@gmail.com');
    await tester.enterText(find.byType(TextField).last, 'Test123');
    await tester.pump();

    expect(find.text('test1@gmail.com'), findsOneWidget);
    expect(find.text('Test123'), findsOneWidget);
  });

  testWidgets(
      'Google sign-in platform error surfaces honest message rather than silent dead tap',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = PlatformException(
      code: 'DEVELOPER_ERROR',
      message: 'Google Play Services developer error (10)',
    );
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(
      find.text('Google Play Services developer error (10)'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Google sign-in FirebaseAuthException surfaces friendly error toast',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    auth.nextError = FirebaseAuthException(code: 'operation-not-allowed');
    await tester.tap(find.text('Google'));
    await tester.pump();

    expect(
      find.text('That sign-in method isn’t enabled yet.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'other sign-in error codes still fall through to the plain toast '
      '(no mode switch)', (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    auth.nextError = FirebaseAuthException(code: 'too-many-requests');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();

    // Stayed in sign-in mode; showed the friendly toast.
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Confirm password'), findsNothing);
    expect(
      find.text('Too many attempts. Wait a minute and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('the password field has a show/hide toggle that flips obscuring',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    final field = find.widgetWithText(TextField, 'Password');
    Finder toggle() =>
        find.descendant(of: field, matching: find.byType(IconButton));

    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(tester.widget<IconButton>(toggle()).tooltip, 'Show password');

    await tester.tap(toggle());
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isFalse);
    expect(tester.widget<IconButton>(toggle()).tooltip, 'Hide password');

    await tester.tap(toggle());
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isTrue);
  });

  testWidgets(
      'confirm-password has its own independent toggle (does not mirror '
      'the password field)', (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);
    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();

    final password = find.widgetWithText(TextField, 'Password');
    final confirm = find.widgetWithText(TextField, 'Confirm password');
    Finder passwordToggle() =>
        find.descendant(of: password, matching: find.byType(IconButton));
    Finder confirmToggle() =>
        find.descendant(of: confirm, matching: find.byType(IconButton));

    expect(tester.widget<TextField>(password).obscureText, isTrue);
    expect(tester.widget<TextField>(confirm).obscureText, isTrue);

    await tester.tap(passwordToggle());
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isFalse);
    expect(tester.widget<TextField>(confirm).obscureText, isTrue,
        reason: 'toggling password must not affect confirm');

    await tester.tap(confirmToggle());
    await tester.pump();
    expect(tester.widget<TextField>(confirm).obscureText, isFalse);
    expect(tester.widget<TextField>(password).obscureText, isFalse);

    await tester.tap(confirmToggle());
    await tester.pump();
    expect(tester.widget<TextField>(confirm).obscureText, isTrue);
    expect(tester.widget<TextField>(password).obscureText, isFalse);
  });

  group('consent legal links (NOTE 141 tap targets)', () {
    final opened = <Uri>[];

    setUp(() {
      opened.clear();
      LegalLinks.setLauncherForTesting((url) async {
        opened.add(url);
        return true;
      });
    });

    tearDown(() => LegalLinks.setLauncherForTesting(null));

    bool termsChecked(WidgetTester tester) =>
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('signin_terms_checkbox')))
            .value ==
        true;
    bool biometricChecked(WidgetTester tester) =>
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('signin_biometric_checkbox')))
            .value ==
        true;

    // The link's tap area is its visible word: the centre, then points just
    // inside each edge and corner of the word's box. (NOTE 147: the old
    // 48dp padded overlay was measured once and went stale a line high, so
    // the word itself is the target now — a recognizer on the span, never a
    // cached rect.)
    Rect wordBox(WidgetTester tester, Key tileKey, String word) {
      final rich = find.descendant(
        of: find.byKey(tileKey),
        matching: find.byType(RichText),
      );
      expect(rich, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(rich);
      final plain = paragraph.text.toPlainText();
      final start = plain.indexOf(word);
      expect(start, greaterThanOrEqualTo(0),
          reason: '$word must be in the $tileKey sentence');
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + word.length),
      );
      expect(boxes, isNotEmpty);
      return boxes.first.toRect().shift(tester.getTopLeft(rich));
    }

    List<Offset> spotsFor(Rect box) => [
          box.center,
          box.topLeft + const Offset(2, 2),
          box.topRight + const Offset(-2, 2),
          box.bottomLeft + const Offset(2, -2),
          box.bottomRight + const Offset(-2, -2),
          box.centerLeft + const Offset(2, 0),
          box.centerRight + const Offset(-2, 0),
        ];

    testWidgets('Terms link opens the Terms page from its centre and edges, '
        'and never toggles a checkbox', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      final box =
          wordBox(tester, const Key('signin_terms_checkbox'), 'Terms');
      for (final spot in spotsFor(box)) {
        await tester.tapAt(spot);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(termsChecked(tester), isFalse,
            reason: 'a Terms tap must never tick the Terms checkbox');
        expect(biometricChecked(tester), isFalse,
            reason: 'a Terms tap must never tick the biometric checkbox');
      }
      expect(opened, hasLength(7));
      expect(opened, everyElement(Uri.parse(LegalLinks.termsUrl)));
    });

    testWidgets('Privacy link opens the Privacy page from its centre and '
        'edges, and never toggles a checkbox', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      final box = wordBox(
          tester, const Key('signin_terms_checkbox'), 'Privacy Policy');
      for (final spot in spotsFor(box)) {
        await tester.tapAt(spot);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(termsChecked(tester), isFalse,
            reason: 'a Privacy tap must never tick the Terms checkbox');
        expect(biometricChecked(tester), isFalse,
            reason: 'a Privacy tap must never tick the biometric checkbox');
      }
      expect(opened, hasLength(7));
      expect(opened, everyElement(Uri.parse(LegalLinks.privacyUrl)));
    });

    testWidgets('tapping the checkbox itself still toggles consent, and '
        'opens nothing', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      final box = find.descendant(
        of: find.byKey(const Key('signin_terms_checkbox')),
        matching: find.byType(Checkbox),
      );
      expect(box, findsOneWidget);

      await tester.tap(box);
      await tester.pump();
      expect(termsChecked(tester), isTrue);
      expect(opened, isEmpty);

      await tester.tap(box);
      await tester.pump();
      expect(termsChecked(tester), isFalse);
      expect(opened, isEmpty);
    });
  });

  group('consent layout geometry (post-2345 regression)', () {
    // The NOTE 141 tap-target fix put ~48dp-tall padded chips inside the
    // consent sentences: every line a link sat on stretched to fit the
    // chip, the spacing went gappy, the closing full stop wrapped onto its
    // own line, and the checkbox sat beside the middle of the block. The
    // label is plain text now, and each link opens from a recognizer on its
    // own span (NOTE 147: the overlaid tap targets went stale a line high
    // after a reflow); these tests pin the geometry so it cannot drift back.

    RenderParagraph paragraphFor(WidgetTester tester, Key tileKey) {
      final rich = find.descendant(
        of: find.byKey(tileKey),
        matching: find.byType(RichText),
      );
      expect(rich, findsOneWidget);
      return tester.renderObject<RenderParagraph>(rich);
    }

    // Rebuilds [span] with every WidgetSpan dropped (a chip's word is kept
    // as styled text): the same sentence with no in-text chips at all.
    TextSpan stripWidgetSpans(InlineSpan span) {
      if (span is WidgetSpan) {
        final child = span.child;
        return TextSpan(
          text: child is Text ? child.data : '',
          style: child is Text ? child.style : null,
        );
      }
      if (span is TextSpan) {
        return TextSpan(
          text: span.text,
          style: span.style,
          children: span.children?.map(stripWidgetSpans).toList(),
        );
      }
      return const TextSpan(text: '');
    }

    testWidgets('consent paragraphs keep their natural plain-text height',
        (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      for (final tileKey in [
        const Key('signin_terms_checkbox'),
        const Key('signin_biometric_checkbox'),
      ]) {
        final paragraph = paragraphFor(tester, tileKey);
        final reference = TextPainter(
          text: stripWidgetSpans(paragraph.text),
          textDirection: TextDirection.ltr,
          textAlign: paragraph.textAlign,
          textScaler: paragraph.textScaler,
          strutStyle: paragraph.strutStyle,
        )..layout(maxWidth: paragraph.size.width);
        expect(
          (paragraph.size.height - reference.size.height).abs(),
          lessThanOrEqualTo(1.0),
          reason: 'the $tileKey label must be no taller than the same '
              'sentence rendered as plain text (no stretched lines)',
        );
      }
    });

    testWidgets('each checkbox top lines up with the first text line',
        (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      for (final tileKey in [
        const Key('signin_terms_checkbox'),
        const Key('signin_biometric_checkbox'),
      ]) {
        final tile = find.byKey(tileKey);
        final checkbox = find.descendant(
          of: tile,
          matching: find.byType(Checkbox),
        );
        expect(checkbox, findsOneWidget);
        final paragraph = paragraphFor(tester, tileKey);
        final firstLine = paragraph
            .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1))
            .first;
        final richFinder = find.descendant(
          of: tile,
          matching: find.byType(RichText),
        );
        final firstLineTop = tester.getTopLeft(richFinder).dy + firstLine.top;
        final checkboxTop = tester.getTopLeft(checkbox).dy;
        expect(
          (checkboxTop - firstLineTop).abs(),
          lessThanOrEqualTo(4.0),
          reason: 'the $tileKey checkbox must sit beside the first line, '
              'not beside the middle of the text block',
        );
      }
    });

    testWidgets('link words are glyph-tight, with no padded 48dp tap target',
        (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      for (final (tileKey, word) in [
        (const Key('signin_terms_checkbox'), 'Terms'),
        (const Key('signin_terms_checkbox'), 'Privacy Policy'),
        (
          const Key('signin_biometric_checkbox'),
          'Biometric Information'
        ),
      ]) {
        final paragraph = paragraphFor(tester, tileKey);
        final plain = paragraph.text.toPlainText();
        final start = plain.indexOf(word);
        expect(start, greaterThanOrEqualTo(0));
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(
              baseOffset: start, extentOffset: start + word.length),
        );
        expect(boxes, isNotEmpty);
        expect(
          boxes.first.toRect().height,
          lessThan(24.0),
          reason: '$word must be its visible word only — the NOTE 147 '
              'defect was a measured-once 48dp overlay sitting a line high',
        );
      }
    });
  });
  group('consent legal links stay on their words after a reflow (NOTE 147)',
      () {
    final opened = <Uri>[];

    setUp(() {
      opened.clear();
      LegalLinks.setLauncherForTesting((url) async {
        opened.add(url);
        return true;
      });
    });

    tearDown(() => LegalLinks.setLauncherForTesting(null));

    bool termsChecked(WidgetTester tester) =>
        tester
                .widget<CheckboxListTile>(
                    find.byKey(const Key('signin_terms_checkbox')))
                .value ==
            true;
    bool biometricChecked(WidgetTester tester) =>
        tester
                .widget<CheckboxListTile>(
                    find.byKey(const Key('signin_biometric_checkbox')))
                .value ==
            true;

    // The centre of [word] where it is actually rendered right now, in
    // global coordinates — read off the laid-out paragraph, never off a
    // cached tap target. This is where a finger lands.
    Offset wordCenter(WidgetTester tester, Key tileKey, String word) {
      final rich = find.descendant(
        of: find.byKey(tileKey),
        matching: find.byType(RichText),
      );
      expect(rich, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(rich);
      final plain = paragraph.text.toPlainText();
      final start = plain.indexOf(word);
      expect(start, greaterThanOrEqualTo(0),
          reason: '$word must be in the $tileKey sentence');
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + word.length),
      );
      expect(boxes, isNotEmpty);
      return tester.getTopLeft(rich) + boxes.first.toRect().center;
    }

    // Pumps [app] under text scale 1.0, then re-pumps it under scale 2.0:
    // the consent sentences reflow and their link words move down the page.
    // A tap target measured before the reflow is stale after it — exactly
    // the NOTE 147 defect on the sign-in screen (targets ~one line above
    // the visible words, visible-text taps doing nothing).
    Future<void> pumpAndReflow(WidgetTester tester, Widget app) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Future<void> pumpScale(double scale) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: app,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      await pumpScale(1.0);
      await pumpScale(2.0);
    }

    testWidgets(
        'Terms opens the Terms page from its visible word after a reflow, '
        'and never toggles a checkbox', (tester) async {
      final auth = _FakeAuth();
      await pumpAndReflow(
        tester,
        MaterialApp(
          home: SignInScreen(auth: auth, voiceController: _FakeVoice()),
        ),
      );

      await tester.tapAt(
          wordCenter(tester, const Key('signin_terms_checkbox'), 'Terms'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(opened, [Uri.parse(LegalLinks.termsUrl)]);
      expect(termsChecked(tester), isFalse,
          reason: 'a Terms tap must never tick the Terms checkbox');
      expect(biometricChecked(tester), isFalse);
    });

    testWidgets(
        'Privacy opens the Privacy page from its visible word after a '
        'reflow, and never toggles a checkbox', (tester) async {
      final auth = _FakeAuth();
      await pumpAndReflow(
        tester,
        MaterialApp(
          home: SignInScreen(auth: auth, voiceController: _FakeVoice()),
        ),
      );

      await tester.tapAt(wordCenter(
          tester, const Key('signin_terms_checkbox'), 'Privacy Policy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(opened, [Uri.parse(LegalLinks.privacyUrl)]);
      expect(termsChecked(tester), isFalse);
      expect(biometricChecked(tester), isFalse);
    });

    testWidgets(
        'Biometric Information opens its page from its visible word after '
        'a reflow, and never toggles a checkbox', (tester) async {
      final auth = _FakeAuth();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) =>
                SignInScreen(auth: auth, voiceController: _FakeVoice()),
          ),
          GoRoute(
            path: BiometricInfoScreen.path,
            builder: (_, __) => const BiometricInfoScreen(),
          ),
        ],
      );
      await pumpAndReflow(
        tester,
        MaterialApp.router(routerConfig: router),
      );

      await tester.tapAt(wordCenter(tester,
          const Key('signin_biometric_checkbox'), 'Biometric Information'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Biometric information'), findsOneWidget);
      expect(termsChecked(tester), isFalse);
      expect(biometricChecked(tester), isFalse);
    });

    testWidgets('a tap on plain row text still toggles consent after a '
        'reflow, and opens nothing', (tester) async {
      final auth = _FakeAuth();
      await pumpAndReflow(
        tester,
        MaterialApp(
          home: SignInScreen(auth: auth, voiceController: _FakeVoice()),
        ),
      );

      await tester.tapAt(wordCenter(
          tester, const Key('signin_biometric_checkbox'), 'recognition'));
      await tester.pump();
      expect(biometricChecked(tester), isTrue);
      expect(opened, isEmpty);
    });
  });

  // Jobs-pass cluster 19 (fleet/jobs-auth-reaudit): spacing / colour /
  // alignment only on the sign-in gate.
  group('jobs-pass geometry (cluster 19)', () {
    testWidgets('D1: the AYMA-to-tagline gap measures 8', (tester) async {
      await _pump(tester, _FakeAuth(), accept: false);
      final gap = tester.getTopLeft(find.text('Your AI matchmaker')).dy -
          tester.getBottomLeft(find.text('AYMA')).dy;
      expect(gap, closeTo(8, 0.5));
    });

    testWidgets('D4: the ScrollView pads bottom 24', (tester) async {
      await _pump(tester, _FakeAuth(), accept: false);
      final scroll =
          tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
      expect((scroll.padding as EdgeInsets).bottom, 24);
    });

    testWidgets('D5: the Tap-to-mute target measures 48 tall while greeting',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final voice = _FakeVoice();
      await tester.pumpWidget(MaterialApp(
        home: SignInScreen(auth: _FakeAuth(), voiceController: voice),
      ));
      await tester.pump();
      // The greeting is live only while the voice session is active.
      voice.setVoiceActive(true);
      await tester.pump();
      expect(find.text('Tap to mute'), findsOneWidget);
      final box = tester.getSize(find
          .ancestor(
              of: find.text('Tap to mute'), matching: find.byType(SizedBox))
          .first);
      expect(box.height, 48);
    });

    testWidgets('D3: the Forgot-password label ends at the field edge',
        (tester) async {
      await _openEmail(tester, _FakeAuth());
      final labelRight = tester.getTopRight(find.text('Forgot password?')).dx;
      final fieldRight = tester.getTopRight(find.byType(TextField).first).dx;
      expect(labelRight, closeTo(fieldRight, 0.5));
    });

    testWidgets('D2: the reset-sent helper reads at size 12', (tester) async {
      final auth = _FakeAuth();
      await _openEmail(tester, auth);
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'a@b.com');
      await tester.tap(find.text('Forgot password?'));
      await tester.pump();
      final reset = find.textContaining('Check your email');
      expect(reset, findsOneWidget);
      expect(tester.widget<Text>(reset).style?.fontSize, 12);
    });

    testWidgets('D14/D15: critical-consent dialog link Wrap + flush labels',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showSignInCriticalConsent(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // D14: the link Wrap carries runSpacing 8.
      final wrap = find.ancestor(
          of: find.widgetWithText(TextButton, 'Terms'),
          matching: find.byType(Wrap));
      expect(tester.widget<Wrap>(wrap).runSpacing, 8);

      // D15: all three link buttons carry zero leading inset, so their labels
      // start flush at the bullets' edge (the M3 TextButton padding is gone).
      for (final label in ['Terms', 'Privacy', 'Face matching']) {
        final btn = tester.widget<TextButton>(
            find.widgetWithText(TextButton, label));
        expect(btn.style?.padding?.resolve({}), EdgeInsets.zero);
      }
    });
  });
}
