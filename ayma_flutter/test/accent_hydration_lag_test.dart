import 'package:ayma_flutter/screens/sign_in_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/services/accent_color_controller.dart';
import 'package:ayma_flutter/services/auth_service.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_auth_mocks/src/mock_user_credential.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthService extends AuthService {
  _FakeAuthService({FirebaseAuth? auth, super.profileService})
      : super(auth: auth ?? MockFirebaseAuth());

  void Function()? onSignIn;
  void Function(void Function(UserCredential) autoSignedIn)? phoneHandler;

  @override
  Future<UserCredential> signInWithEmailPassword(
      String email, String password) async {
    onSignIn?.call();
    return MockUserCredential(false);
  }

  @override
  Future<void> startPhoneSignIn(
    String phoneNumber, {
    required void Function(String verificationId) codeSent,
    required void Function(FirebaseAuthException error) verificationFailed,
    void Function(UserCredential credential)? autoSignedIn,
  }) async {
    if (phoneHandler != null && autoSignedIn != null) {
      phoneHandler!(autoSignedIn);
    } else {
      codeSent('v1');
    }
  }
}

class _FakeProfiles extends ProfileService {
  _FakeProfiles({this.savedAccent})
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1')));

  Color? savedAccent;

  @override
  Future<Color?> getAccentColor() async => savedAccent;
}

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  @override
  Future<void> stop() async {}
}

/// A screen representing the post-sign-in destination that displays the active accent token.
class _FirstRenderScreen extends StatelessWidget {
  const _FirstRenderScreen();

  @override
  Widget build(BuildContext context) {
    final accent = context.ac.accent;
    return Scaffold(
      body: Center(
        child: Text(
          'ACCENT:${accent.toARGB32().toRadixString(16)}',
          key: const ValueKey('accent_token_label'),
        ),
      ),
    );
  }
}

Future<void> _acceptConsents(WidgetTester tester) async {
  final checks = find.byType(Checkbox);
  expect(checks, findsNWidgets(2));
  await tester.tap(checks.first);
  await tester.tap(checks.last);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Scout NOTE 236 regression: accent hydration lag on fresh install', () {
    testWidgets(
        'saved green accent (#2d6a4f) applies on first render after sign-in with no relaunch',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Fresh install: local SharedPreferences is completely empty.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accent_color_hex'), isNull);

      // User's Firestore profile doc has saved green accent #2d6a4f.
      const savedGreen = Color(0xFF2D6A4F);
      final fakeProfiles = _FakeProfiles(savedAccent: savedGreen);
      final accentController = AccentColorController(
        initial: AymaColors.accent,
        profileService: fakeProfiles,
      );

      // Before sign-in, controller starts with default pink.
      expect(accentController.color, AymaColors.accent);

      final authService = _FakeAuthService(profileService: fakeProfiles);

      final router = GoRouter(
        initialLocation: SignInScreen.path,
        routes: [
          GoRoute(
            path: SignInScreen.path,
            builder: (_, __) => SignInScreen(
              auth: authService,
              voiceController: _FakeVoice(),
              accentController: accentController,
              profileService: fakeProfiles,
            ),
          ),
          GoRoute(
            path: SplashScreen.path,
            builder: (_, __) => const _FirstRenderScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        AnimatedBuilder(
          animation: accentController,
          builder: (context, _) => MaterialApp.router(
            theme: AymaTheme.lightWithAccent(accentController.color),
            darkTheme: AymaTheme.darkWithAccent(accentController.color),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Accept clickwrap consents and choose Email.
      await _acceptConsents(tester);
      await tester.tap(find.text('Email'));
      await tester.pump();

      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'user@ayma.ai');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'password123');

      // Tap Sign in
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Landing screen has rendered for the first time.
      expect(find.byType(_FirstRenderScreen), findsOneWidget);

      // The saved green accent must apply on this very FIRST render after sign-in.
      expect(accentController.color, savedGreen);
      expect(find.text('ACCENT:${savedGreen.toARGB32().toRadixString(16)}'), findsOneWidget);

      // Local storage must be persisted so subsequent cold restarts also paint green.
      expect(prefs.getString('accent_color_hex'), '#2d6a4f');
    });

    testWidgets(
        'sign-in with no saved accent in profile leaves default Cherry Fuchsia on first render',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accent_color_hex'), isNull);

      final fakeProfiles = _FakeProfiles(savedAccent: null);
      final accentController = AccentColorController(
        initial: AymaColors.accent,
        profileService: fakeProfiles,
      );

      final authService = _FakeAuthService(profileService: fakeProfiles);

      final router = GoRouter(
        initialLocation: SignInScreen.path,
        routes: [
          GoRoute(
            path: SignInScreen.path,
            builder: (_, __) => SignInScreen(
              auth: authService,
              voiceController: _FakeVoice(),
              accentController: accentController,
              profileService: fakeProfiles,
            ),
          ),
          GoRoute(
            path: SplashScreen.path,
            builder: (_, __) => const _FirstRenderScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        AnimatedBuilder(
          animation: accentController,
          builder: (context, _) => MaterialApp.router(
            theme: AymaTheme.lightWithAccent(accentController.color),
            darkTheme: AymaTheme.darkWithAccent(accentController.color),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await _acceptConsents(tester);
      await tester.tap(find.text('Email'));
      await tester.pump();

      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'newuser@ayma.ai');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'password123');

      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(_FirstRenderScreen), findsOneWidget);
      expect(accentController.color, AymaColors.accent);
      expect(
        find.text('ACCENT:${AymaColors.accent.toARGB32().toRadixString(16)}'),
        findsOneWidget,
      );
      expect(prefs.getString('accent_color_hex'), isNull);
    });

    testWidgets(
        'phone auto-sign-in path applies saved green accent on first render',
        (tester) async {
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const savedGreen = Color(0xFF2D6A4F);
      final fakeProfiles = _FakeProfiles(savedAccent: savedGreen);
      final accentController = AccentColorController(
        initial: AymaColors.accent,
        profileService: fakeProfiles,
      );

      final authService = _FakeAuthService(profileService: fakeProfiles)
        ..phoneHandler = (autoSignedIn) {
          autoSignedIn(MockUserCredential(false));
        };

      final router = GoRouter(
        initialLocation: SignInScreen.path,
        routes: [
          GoRoute(
            path: SignInScreen.path,
            builder: (_, __) => SignInScreen(
              auth: authService,
              voiceController: _FakeVoice(),
              accentController: accentController,
              profileService: fakeProfiles,
            ),
          ),
          GoRoute(
            path: SplashScreen.path,
            builder: (_, __) => const _FirstRenderScreen(),
          ),
        ],
      );

      await tester.pumpWidget(
        AnimatedBuilder(
          animation: accentController,
          builder: (context, _) => MaterialApp.router(
            theme: AymaTheme.lightWithAccent(accentController.color),
            darkTheme: AymaTheme.darkWithAccent(accentController.color),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await _acceptConsents(tester);
      await tester.tap(find.text('Phone'));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '4155552671');
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(_FirstRenderScreen), findsOneWidget);
      expect(accentController.color, savedGreen);
      expect(find.text('ACCENT:${savedGreen.toARGB32().toRadixString(16)}'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accent_color_hex'), '#2d6a4f');
    });
  });
}
