import 'package:ayma_flutter/screens/biometric_info_screen.dart';
import 'package:ayma_flutter/screens/privacy_screen.dart';
import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/screens/terms_screen.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A controller whose session never really starts, but whose shared
/// [transcript] a test can push finalized voice turns into — the same seam the
/// live welcome room feeds (§3.3).
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  /// Simulate the user finishing a spoken turn in the greeting.
  void userSaid(String text) =>
      transcript.applyVoiceSegment(TurnRole.user, text, isFinal: true);
}

Future<_FakeVoice> _pumpSignIn(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1100, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final voice = _FakeVoice();
  final router = GoRouter(
    initialLocation: SignInScreen.path,
    routes: [
      GoRoute(
        path: SignInScreen.path,
        builder: (_, __) => SignInScreen(
          auth: AuthService(auth: MockFirebaseAuth()),
          voiceController: voice,
        ),
      ),
      GoRoute(
          path: TermsScreen.path, builder: (_, __) => const TermsScreen()),
      GoRoute(
          path: PrivacyScreen.path,
          builder: (_, __) => const PrivacyScreen()),
      GoRoute(
          path: BiometricInfoScreen.path,
          builder: (_, __) => const BiometricInfoScreen()),
    ],
  );
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return voice;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('"open the terms" navigates to the Terms screen',
      (tester) async {
    final voice = await _pumpSignIn(tester);
    voice.userSaid('open the terms and conditions');
    await tester.pumpAndSettle();
    expect(find.byType(TermsScreen), findsOneWidget);
  });

  testWidgets('"open the privacy policy" navigates to the Privacy screen',
      (tester) async {
    final voice = await _pumpSignIn(tester);
    voice.userSaid('can you open the privacy policy');
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyScreen), findsOneWidget);
  });

  testWidgets('"open biometric information" navigates to the Biometric screen',
      (tester) async {
    final voice = await _pumpSignIn(tester);
    voice.userSaid('open biometric information');
    await tester.pumpAndSettle();
    expect(find.byType(BiometricInfoScreen), findsOneWidget);
  });

  testWidgets(
      '"anything critical?" shows the consent summary with every key item',
      (tester) async {
    final voice = await _pumpSignIn(tester);
    voice.userSaid('is there anything critical I should be aware of?');
    await tester.pumpAndSettle();

    expect(find.text('Before you sign in'), findsOneWidget);
    // Scope to the dialog — the sign-in page's own checkboxes behind it share
    // some of this wording.
    Finder inDialog(String text) => find.descendant(
        of: find.byType(AlertDialog), matching: find.textContaining(text));
    expect(inDialog('18 or older'), findsOneWidget);
    expect(inDialog('advertising'), findsOneWidget);
    expect(inDialog('face recognition'), findsOneWidget);
    expect(inDialog('public web'), findsOneWidget);
    expect(inDialog('Privacy Policy'), findsOneWidget);
  });

  testWidgets('idle chatter neither navigates nor opens the dialog',
      (tester) async {
    final voice = await _pumpSignIn(tester);
    voice.userSaid('hey, sounds great, thanks');
    await tester.pumpAndSettle();

    expect(find.byType(TermsScreen), findsNothing);
    expect(find.byType(PrivacyScreen), findsNothing);
    expect(find.byType(BiometricInfoScreen), findsNothing);
    expect(find.text('Before you sign in'), findsNothing);
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('a non-final interim segment is not acted on', (tester) async {
    final voice = await _pumpSignIn(tester);
    voice.transcript
        .applyVoiceSegment(TurnRole.user, 'open the terms', isFinal: false);
    await tester.pumpAndSettle();
    expect(find.byType(TermsScreen), findsNothing);
    expect(find.byType(SignInScreen), findsOneWidget);
  });
}
