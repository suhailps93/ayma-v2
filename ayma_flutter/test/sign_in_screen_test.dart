import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuth extends AuthService {
  _FakeAuth() : super(auth: MockFirebaseAuth());
  final List<String> calls = [];

  /// When set, the next email sign-in / create / reset call throws this.
  FirebaseAuthException? nextError;

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
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

Future<void> _pump(WidgetTester tester, _FakeAuth auth) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: SignInScreen(auth: auth, voiceController: _FakeVoice()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Opens the email stage (sign-in mode).
Future<void> _openEmail(WidgetTester tester, _FakeAuth auth) async {
  await _pump(tester, auth);
  await tester.tap(find.text('Email'));
  await tester.pump();
}

void main() {
  testWidgets('shows the provider choices and a Terms line', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.textContaining('Terms'), findsOneWidget);
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

  testWidgets('error codes map to human messages steering to the right mode',
      (tester) async {
    final auth = _FakeAuth();
    await _openEmail(tester, auth);

    Future<void> submit(String code, {bool create = false}) async {
      auth.nextError = FirebaseAuthException(code: code);
      await tester.enterText(
          find.widgetWithText(TextField, 'Email'), 'a@b.com');
      await tester.enterText(
          find.widgetWithText(TextField, 'Password'), 'secret1');
      if (create) {
        await tester.enterText(
            find.widgetWithText(TextField, 'Confirm password'), 'secret1');
      }
      await tester.tap(find.widgetWithText(
          FilledButton, create ? 'Create account' : 'Sign in'));
      await tester.pump();
    }

    // Wrong password (also how Firebase reports it post-enumeration-protection).
    await submit('invalid-credential');
    expect(
      find.text('That email and password don’t match. New here? '
          'Tap “Sign up” below.'),
      findsOneWidget,
    );

    // No such account.
    await submit('user-not-found');
    expect(
      find.text('No account with that email yet — tap “Sign up” to create one.'),
      findsOneWidget,
    );

    // Email already in use, from the sign-up mode.
    await tester.tap(find.text('Don’t have an account? Sign up'));
    await tester.pump();
    await submit('email-already-in-use', create: true);
    expect(
      find.text('That email already has an account — tap “Sign in” instead.'),
      findsOneWidget,
    );

    // Raw codes never leak.
    expect(find.textContaining('invalid-credential'), findsNothing);
    expect(find.textContaining('email-already-in-use'), findsNothing);
  });
}
