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

// Cluster 17 helpers: theme-resolved tokens + per-element geometry/colour.
AymaTokens _ac(WidgetTester tester, Finder anchor) =>
    (tester.element(anchor) as BuildContext).ac;

Color? _iconColor(WidgetTester tester, IconData data) =>
    tester.widget<Icon>(find.byIcon(data)).color;

double _titleLeft(WidgetTester tester, String title) =>
    tester.getTopLeft(find.text(title)).dx;

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

  // ---- Jobs pass cluster 17: spacing / colour / alignment ----

  testWidgets(
      'cluster 17 — Privacy switches carry fgDim secondary icons, the four '
      'plain leadings read fgDim, and every title shares the x=60 left edge '
      '(defects 1, 6) with the ListView breathing at the bottom (defect 10)',
      (tester) async {
    await pumpRouted(tester);
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    final ac = _ac(tester, find.text('Pause matching'));

    // Defect 1 — both switch rows now have a leading (secondary) icon, fgDim.
    expect(_iconColor(tester, Icons.pause_circle_outlined), ac.fgDim);
    expect(_iconColor(tester, Icons.smart_toy_outlined), ac.fgDim);

    // Defect 6 — the four plain leadings read fgDim, not fgMute.
    expect(_iconColor(tester, Icons.gpp_maybe_outlined), ac.fgDim);
    expect(_iconColor(tester, Icons.face_retouching_natural_outlined), ac.fgDim);
    expect(_iconColor(tester, Icons.description_outlined), ac.fgDim);
    expect(_iconColor(tester, Icons.privacy_tip_outlined), ac.fgDim);

    // Defects 1, 2 + the audited icon rows: one shared title left edge at 60.
    for (final title in const [
      'Pause matching',
      'AI Avatar',
      'Verify your face',
      'Face matching consent',
      'Terms of Service',
      'Privacy Policy',
      'Wipe what Ayma has learned',
      'Delete account',
    ]) {
      expect(_titleLeft(tester, title), moreOrLessEquals(60, epsilon: 0.5),
          reason: title);
    }

    // Defect 10 — the Privacy ListView pads its bottom 20.
    expect(tester.widget<ListView>(find.byType(ListView)).padding,
        const EdgeInsets.only(bottom: 20));
  });

  testWidgets(
      'cluster 17 — Wipe row: delete_sweep leading in raw error, title in '
      'errorText; Delete leading stays raw error; verify chevron is fgMute '
      '(defects 2, 4, 5)', (tester) async {
    await pumpRouted(tester);
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    final ac = _ac(tester, find.text('Wipe what Ayma has learned'));

    // Defect 2 — wipe leading icon = delete_sweep in raw error.
    expect(_iconColor(tester, Icons.delete_sweep_outlined), ac.error);
    // Defect 4 — wipe TITLE reads errorText (not raw error).
    expect(
        tester.widget<Text>(find.text('Wipe what Ayma has learned')).style?.color,
        ac.errorText);
    // Defect 4 guard — the Delete leading ICON stays raw error.
    expect(_iconColor(tester, Icons.delete_outline), ac.error);

    // Defect 5 — the Verify-your-face chevron is explicit fgMute.
    final verifyChevron = find.descendant(
      of: find.widgetWithText(ListTile, 'Verify your face'),
      matching: find.byIcon(Icons.chevron_right),
    );
    expect(tester.widget<Icon>(verifyChevron).color, ac.fgMute);
  });

  testWidgets('cluster 17 — the verified icon reads successText (defect 3)',
      (tester) async {
    await pumpRouted(tester, api: _api((_) {}, verified: true));
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    final ac = _ac(tester, find.text('Face verified'));
    expect(_iconColor(tester, Icons.verified_outlined), ac.successText);
  });

  testWidgets(
      'cluster 17 — Appearance: accent icon fgDim, radios shrinkWrap with '
      'titles at x=60, ListView bottom padding 20 (defects 7, 8, 9)',
      (tester) async {
    await pumpRouted(tester);
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    final ac = _ac(tester, find.text('Accent Color'));

    // Defect 7 — the Accent Color leading icon is fgDim, not accent.
    expect(_iconColor(tester, Icons.palette_outlined), ac.fgDim);

    // Defect 8 — the three radio rows shrink the tap target and zero the
    // title gap, so their titles land on the shared x=60 edge.
    final radios = tester
        .widgetList<RadioListTile<ThemeMode>>(
            find.byType(RadioListTile<ThemeMode>))
        .toList();
    expect(radios.length, 3);
    for (final r in radios) {
      expect(r.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
      expect(r.horizontalTitleGap, 0);
    }
    for (final title in const [
      'Match system',
      'Light',
      'Dark',
      'Accent Color',
      'How to use Ayma',
    ]) {
      expect(_titleLeft(tester, title), moreOrLessEquals(60, epsilon: 0.5),
          reason: title);
    }

    // Defect 9 — the Appearance ListView pads its bottom 20.
    expect(tester.widget<ListView>(find.byType(ListView)).padding,
        const EdgeInsets.only(bottom: 20));
  });
}
