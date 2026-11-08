import 'dart:convert';

import 'package:ayma_flutter/legal/biometric_consent_text.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
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
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuth extends AuthService {
  _FakeAuth() : super(auth: MockFirebaseAuth());
  final List<String> calls = [];

  /// When set, the next email sign-in / create / reset call throws this.
  FirebaseAuthException? nextError;

  /// When true, the next email sign-in succeeds with a mock credential.
  bool succeedSignIn = false;

  Never _throwNext() {
    final e = nextError!;
    nextError = null;
    throw e;
  }

  @override
  Future<UserCredential> signInWithGoogle() async {
    calls.add('google');
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
  @override
  Future<void> start({bool forceRelayFirst = false}) async {}
  @override
  Future<void> stop() async {}
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

    // The centre of the link chip, then points just inside each edge and
    // corner. The edge points sit inside the chip's padded hit region but
    // outside the word's glyphs, where a bare text span used to drop the
    // tap onto the row and toggle consent (or fire the neighbouring link).
    List<Offset> spotsFor(WidgetTester tester, Finder link) => [
          tester.getCenter(link),
          tester.getTopLeft(link) + const Offset(2, 2),
          tester.getTopRight(link) + const Offset(-2, 2),
          tester.getBottomLeft(link) + const Offset(2, -2),
          tester.getBottomRight(link) + const Offset(-2, -2),
          tester.getRect(link).centerLeft + const Offset(2, 0),
          tester.getRect(link).centerRight + const Offset(-2, 0),
        ];

    testWidgets('Terms link opens the Terms page from its centre and edges, '
        'and never toggles a checkbox', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      final link = find.byKey(const Key('signin_terms_link'));
      expect(link, findsOneWidget);
      // The hit region is a padded chip about 48dp tall, not glyph-tight.
      expect(tester.getSize(link).height, greaterThanOrEqualTo(40));

      for (final spot in spotsFor(tester, link)) {
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

      final link = find.byKey(const Key('signin_privacy_link'));
      expect(link, findsOneWidget);
      expect(tester.getSize(link).height, greaterThanOrEqualTo(40));

      for (final spot in spotsFor(tester, link)) {
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
    // label is plain text now, with the tap targets overlaid on the words;
    // these tests pin the geometry so it cannot drift back.

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

    testWidgets('link tap targets stay at least 48dp tall', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth, accept: false);

      for (final linkKey in [
        const Key('signin_terms_link'),
        const Key('signin_privacy_link'),
        const Key('signin_biometric_info_link'),
      ]) {
        final link = find.byKey(linkKey);
        expect(link, findsOneWidget);
        expect(
          tester.getSize(link).height,
          greaterThanOrEqualTo(48.0 - 0.1),
          reason: '$linkKey must keep a full-size tap target even though '
              'the label text is back to its natural line height',
        );
      }
    });
  });
}
