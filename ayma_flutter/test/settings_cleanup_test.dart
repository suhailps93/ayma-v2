import 'dart:convert';

import 'package:ayma_flutter/screens/appearance_settings_screen.dart';
import 'package:ayma_flutter/screens/privacy_settings_screen.dart';
import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/legal_links.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
      : super(
            auth:
                MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  bool paused = false;
  final List<bool> pausedWrites = [];
  bool aiAvatar = true;
  final List<bool> aiAvatarWrites = [];

  @override
  Stream<bool> watchAiAvatar() => Stream.value(aiAvatar);

  @override
  Future<void> setAiAvatar(bool value) async {
    aiAvatar = value;
    aiAvatarWrites.add(value);
  }

  @override
  Stream<bool> watchPaused() => Stream.value(paused);

  @override
  Future<void> setPaused(bool value) async {
    paused = value;
    pausedWrites.add(value);
  }
}

ApiClient _api(void Function(String path) onCall, {bool verified = false}) {
  final mock = MockClient((req) async {
    onCall(req.url.path);
    if (req.url.path == '/verification/status') {
      return http.Response(jsonEncode({'verified': verified}), 200);
    }
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

List<String?> _tileTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((t) => t.title is Text ? (t.title as Text).data : null)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<GoRouter> pumpRouted(
    WidgetTester tester, {
    ThemeController? controller,
    _FakeProfiles? profiles,
    ApiClient? api,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = controller ?? ThemeController(initial: ThemeMode.dark);
    final p = profiles ?? _FakeProfiles();
    final a = api ?? _api((_) {});
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => const SettingsScreen(),
        ),
        GoRoute(
          path: AppearanceSettingsScreen.path,
          builder: (_, __) => AppearanceSettingsScreen(controller: c),
        ),
        GoRoute(
          path: PrivacySettingsScreen.path,
          builder: (_, __) =>
              PrivacySettingsScreen(profileService: p, api: a),
        ),
        for (final stub in const {
          '/profile/plan': 'PLAN SCREEN',
          '/notifications/prefs': 'NOTIF PREFS SCREEN',
          '/settings/accent-color': 'ACCENT SCREEN',
          '/settings/voice': 'MODELS SCREEN',
          '/settings/connect-agent': 'CONNECT SCREEN',
          '/settings/delete-account': 'DELETE SCREEN',
          '/settings/biometric-consent': 'CONSENT SCREEN',
          '/': 'SHELL SCREEN',
        }.entries)
          GoRoute(
            path: stub.key,
            builder: (_, __) => Scaffold(body: Text(stub.value)),
          ),
      ],
    );
    await tester.pumpWidget(AnimatedBuilder(
      animation: c,
      builder: (context, _) => MaterialApp.router(
        theme: AymaTheme.light,
        darkTheme: AymaTheme.dark,
        themeMode: c.mode,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets(
      'top level shows exactly the four section rows plus the two Ayma line '
      'items and the guided-tour tile, and nothing else', (tester) async {
    await pumpRouted(tester);

    expect(
      _tileTitles(tester),
      [
        'Plan and credits',
        'Appearance',
        'Notification preferences',
        'Privacy',
        'Ayma’s models',
        'Connect an agent (MCP)',
        'How to use Ayma',
      ],
    );
    // Everything else moved under a section — none of it sits on top.
    for (final gone in const [
      'Pause matching',
      'Accent Color',
      'Match system',
      'Light',
      'Dark',
      'AI Avatar',
      'Verify your face',
      'Face verified',
      'Face matching consent',
      'Terms of Service',
      'Privacy Policy',
      'Wipe what Ayma has learned',
      'Delete account',
      'Ayma’s settings',
      'Matching',
      'Verification',
      'Help',
      'Account',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  });

  testWidgets('the Appearance row opens theme mode and accent colour',
      (tester) async {
    final c = ThemeController(initial: ThemeMode.dark);
    await pumpRouted(tester, controller: c);

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    expect(find.text('Match system'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Accent Color'), findsOneWidget);
    expect(find.text('How to use Ayma'), findsOneWidget);

    // The theme choice still saves from inside Appearance.
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(c.mode, ThemeMode.light);

    await tester.tap(find.text('Accent Color'));
    await tester.pumpAndSettle();
    expect(find.text('ACCENT SCREEN'), findsOneWidget);
  });

  testWidgets(
      'the Privacy row opens pause matching, AI avatar, verification, '
      'consent, wipe and delete — wipe directly above delete',
      (tester) async {
    await pumpRouted(tester);

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    expect(
      _tileTitles(tester),
      [
        'Pause matching',
        'AI Avatar',
        'Verify your face',
        'Face matching consent',
        'Terms of Service',
        'Privacy Policy',
        'Wipe what Ayma has learned',
        'Delete account',
      ],
    );
    final wipeY = tester.getTopLeft(find.text('Wipe what Ayma has learned')).dy;
    final deleteY = tester.getTopLeft(find.text('Delete account')).dy;
    expect(wipeY, lessThan(deleteY));
  });

  testWidgets('pause matching lives inside Privacy and nowhere else',
      (tester) async {
    final profiles = _FakeProfiles();
    await pumpRouted(tester, profiles: profiles);

    expect(find.text('Pause matching'), findsNothing);
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.text('Pause matching'), findsOneWidget);

    await tester.tap(find.text('Pause matching'));
    await tester.pumpAndSettle();
    expect(profiles.pausedWrites, [true]);
  });

  testWidgets('a verified user sees Face verified inside Privacy',
      (tester) async {
    await pumpRouted(tester, api: _api((_) {}, verified: true));

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    expect(find.text('Face verified'), findsOneWidget);
    expect(find.text('Verify your face'), findsNothing);
  });

  testWidgets('the wipe inside Privacy confirms then calls the endpoint',
      (tester) async {
    final calls = <String>[];
    await pumpRouted(tester, api: _api(calls.add));

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wipe what Ayma has learned'));
    await tester.pumpAndSettle();
    expect(find.text('Wipe what Ayma has learned?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Wipe'));
    await tester.pumpAndSettle();
    expect(calls, contains('/wiki/reset'));
  });

  testWidgets('Plan, Notifications, Models and Connect rows open their pages',
      (tester) async {
    final router = await pumpRouted(tester);

    await tester.tap(find.text('Plan and credits'));
    await tester.pumpAndSettle();
    expect(find.text('PLAN SCREEN'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Notification preferences'));
    await tester.pumpAndSettle();
    expect(find.text('NOTIF PREFS SCREEN'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ayma’s models'));
    await tester.pumpAndSettle();
    expect(find.text('MODELS SCREEN'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect an agent (MCP)'));
    await tester.pumpAndSettle();
    expect(find.text('CONNECT SCREEN'), findsOneWidget);
  });

  testWidgets('no “Ayma settings” label exists on any of the three pages',
      (tester) async {
    final router = await pumpRouted(tester);

    expect(find.textContaining('Ayma’s settings'), findsNothing);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ayma’s settings'), findsNothing);
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ayma’s settings'), findsNothing);
  });

  testWidgets(
      'Terms of Service and Privacy Policy rows live inside Privacy and '
      'open the hosted pages directly in the browser with no middle screen',
      (tester) async {
    final launched = <Uri>[];
    LegalLinks.setLauncherForTesting((url) async {
      launched.add(url);
      return true;
    });
    addTearDown(() => LegalLinks.setLauncherForTesting(null));

    await pumpRouted(tester);
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    expect(find.text('Terms of Service'), findsOneWidget);
    expect(
        find.text('How Ayma uses your photos and public information'),
        findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('What we collect, why, and your choices'), findsOneWidget);

    await tester.tap(find.text('Terms of Service'));
    await tester.pumpAndSettle();
    expect(launched, [Uri.parse(LegalLinks.termsUrl)]);
    expect(find.byType(PrivacySettingsScreen), findsOneWidget);

    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(launched, [
      Uri.parse(LegalLinks.termsUrl),
      Uri.parse(LegalLinks.privacyUrl),
    ]);
    expect(find.byType(PrivacySettingsScreen), findsOneWidget);
    expect(find.textContaining('Opening the'), findsNothing);
  });
}
