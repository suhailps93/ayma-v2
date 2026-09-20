import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/instagram_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Sign in with Instagram" widget tests — mirrors `sign_in_screen_test.dart`
/// (fake `AuthService`, stub the terminal Firebase call so it throws before
/// the `context.go` navigation, which needs a real `GoRouter` this test tree
/// doesn't have) plus a fake `InstagramService` for the OAuth round trip.
class _FakeAuth extends AuthService {
  _FakeAuth() : super(auth: MockFirebaseAuth());
  final List<String> calls = [];

  @override
  Future<UserCredential> signInWithInstagramCustomToken(
      String customToken) async {
    calls.add('instagram-token:$customToken');
    throw StateError('stubbed');
  }
}

class _FakeInstagram extends InstagramService {
  final List<String> calls = [];
  String authUrlToReturn = 'https://api.instagram.com/oauth/authorize?x=1';
  String customToken = 'CUSTOM-TOKEN';

  @override
  Future<String> signinAuthUrl() async {
    calls.add('authUrl');
    return authUrlToReturn;
  }

  @override
  Future<InstagramSigninResult> signin(String code) async {
    calls.add('signin:$code');
    return InstagramSigninResult(customToken: customToken, isNewUser: true);
  }
}

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

/// Capture url_launcher calls; returns the launched URL strings in order.
/// [succeeds] controls what the platform channel reports back — `false`
/// exercises the "Could not open Instagram sign-in" branch.
List<String> _mockLaunches(WidgetTester tester, {bool succeeds = true}) {
  final launched = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/url_launcher'),
    (call) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
        return succeeds;
      }
      if (call.method == 'canLaunch') return succeeds;
      return null;
    },
  );
  return launched;
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeAuth auth,
  required _FakeInstagram instagram,
}) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: SignInScreen(
      auth: auth,
      voiceController: _FakeVoice(),
      instagramService: instagram,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('shows an Instagram option alongside Google / Email / Phone',
      (tester) async {
    await _pump(tester, auth: _FakeAuth(), instagram: _FakeInstagram());

    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
  });

  testWidgets(
      'tapping Instagram opens the OAuth URL, then the paste-code dialog',
      (tester) async {
    final launched = _mockLaunches(tester);
    final auth = _FakeAuth();
    final instagram = _FakeInstagram();
    await _pump(tester, auth: auth, instagram: instagram);

    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(instagram.calls, contains('authUrl'));
    expect(launched, [instagram.authUrlToReturn]);
    expect(find.text('Finish connecting'), findsOneWidget);
  });

  testWidgets(
      'pasting the code back signs in with the returned custom token',
      (tester) async {
    _mockLaunches(tester);
    final auth = _FakeAuth();
    final instagram = _FakeInstagram();
    await _pump(tester, auth: auth, instagram: instagram);

    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField).last, 'the-auth-code');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(instagram.calls, contains('signin:the-auth-code'));
    // The backend's custom token is redeemed for a real Firebase session,
    // same terminal step as every other sign-in method.
    expect(auth.calls, contains('instagram-token:${instagram.customToken}'));
  });

  testWidgets('a redirect URL query code is extracted before signing in',
      (tester) async {
    _mockLaunches(tester);
    final auth = _FakeAuth();
    final instagram = _FakeInstagram();
    await _pump(tester, auth: auth, instagram: instagram);

    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(
      find.byType(TextField).last,
      'https://ayma.example/ig/callback?code=abc123&state=xyz',
    );
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(instagram.calls, contains('signin:abc123'));
  });

  testWidgets('a failed launch shows an error and never prompts for a code',
      (tester) async {
    _mockLaunches(tester, succeeds: false);
    final auth = _FakeAuth();
    final instagram = _FakeInstagram();
    await _pump(tester, auth: auth, instagram: instagram);

    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Could not open Instagram sign-in'),
        findsOneWidget);
    expect(find.text('Finish connecting'), findsNothing);
  });
}
