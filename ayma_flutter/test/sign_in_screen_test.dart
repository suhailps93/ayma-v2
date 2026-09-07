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

  @override
  Future<UserCredential> signInWithGoogle() async {
    calls.add('google');
    throw StateError('stubbed');
  }

  @override
  Future<UserCredential> signInWithEmailPassword(
      String email, String password) async {
    calls.add('email:$email');
    throw StateError('stubbed');
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

void main() {
  testWidgets('shows the provider choices and a Terms line', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Continue with phone'), findsOneWidget);
    expect(find.textContaining('Terms'), findsOneWidget);
  });

  testWidgets('the email choice reveals email + password fields',
      (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    await tester.tap(find.text('Continue with email'));
    await tester.pump();

    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Email'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'secret1');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(auth.calls, contains('email:a@b.com'));
  });
}
