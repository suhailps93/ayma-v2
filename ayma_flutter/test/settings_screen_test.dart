import 'dart:convert';

import 'package:ayma_flutter/dev_mode.dart';
import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/profile_service.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProfiles extends ProfileService {
  _FakeProfiles()
      : super(auth: MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'me')));

  bool paused = false;
  final List<bool> pausedWrites = [];
  int failNextPauses = 0;

  @override
  Stream<bool> watchAiAvatar() => Stream.value(true);

  @override
  Stream<bool> watchPaused() => Stream.value(paused);

  @override
  Future<void> setPaused(bool value) async {
    if (failNextPauses > 0) {
      failNextPauses--;
      throw StateError('refused');
    }
    paused = value;
    pausedWrites.add(value);
  }
}

ApiClient _api(void Function(String path) onCall) {
  final mock = MockClient((req) async {
    onCall(req.url.path);
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  // Every test leaves the compile-time dev-mode flag at its default (off);
  // the two unlock tests opt in explicitly.
  tearDown(() => debugDevModeOverride = null);

  Widget host(ThemeController c, ProfileService p, ApiClient a) =>
      AnimatedBuilder(
        animation: c,
        builder: (context, _) => MaterialApp(
          theme: AymaTheme.light,
          darkTheme: AymaTheme.dark,
          themeMode: c.mode,
          home: SettingsScreen(
            controller: c,
            profileService: p,
            api: a,
          ),
        ),
      );

  testWidgets('appearance toggle switches theme mode', (tester) async {
    final c = ThemeController(initial: ThemeMode.dark);
    await tester.pumpWidget(host(c, _FakeProfiles(), _api((_) {})));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(c.mode, ThemeMode.light);
  });

  testWidgets('hosts pause matching and face verification, not Ayma settings',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(ThemeController(initial: ThemeMode.dark),
        _FakeProfiles(), _api((_) {})));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Pause matching'), findsOneWidget);
    expect(find.text('Verification'), findsOneWidget);
    expect(find.text('Animation'), findsNothing);
    expect(find.text('Wipe what Ayma has learned'), findsNothing);
  });

  testWidgets('pause matching toggle writes the flag', (tester) async {
    final profiles = _FakeProfiles();
    await tester.pumpWidget(host(
        ThemeController(initial: ThemeMode.dark), profiles, _api((_) {})));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pause matching'));
    await tester.pumpAndSettle();
    expect(profiles.pausedWrites, [true]);
  });

  testWidgets('a refused pause-matching write offers Retry', (tester) async {
    final profiles = _FakeProfiles()..failNextPauses = 1;
    await tester.pumpWidget(host(
        ThemeController(initial: ThemeMode.dark), profiles, _api((_) {})));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pause matching'));
    await tester.pumpAndSettle();

    expect(profiles.pausedWrites, isEmpty);
    expect(find.textContaining('Could not save'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(profiles.pausedWrites, [true]);
  });

  Future<void> pumpRouted(WidgetTester tester) async {
    final c = ThemeController(initial: ThemeMode.dark);
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => SettingsScreen(
              controller: c, profileService: _FakeProfiles(), api: _api((_) {})),
        ),
        for (final path in const [
          '/settings/developer',
          '/profile/plan',
        ])
          GoRoute(
            path: path,
            builder: (_, __) => Scaffold(body: Text('ROUTE $path')),
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
  }

  testWidgets('a clean release version is shown, not the build mode', (
    tester,
  ) async {
    await pumpRouted(tester);
    final stamp = find.byKey(const ValueKey('build-stamp'));
    await tester.scrollUntilVisible(stamp, 200);
    await tester.pumpAndSettle();
    // No PackageInfo platform channel under test, so the row falls back to the
    // bare label — never "dev build", "debug" or a raw build string.
    expect(find.text('Version'), findsOneWidget);
    expect(find.textContaining('dev build'), findsNothing);
    expect(find.textContaining('debug'), findsNothing);
    expect(find.text("What's new"), findsNothing);
  });

  testWidgets('seven taps on the version row open the Developer panel; '
      'fewer do nothing', (tester) async {
    debugDevModeOverride = true;
    await pumpRouted(tester);
    final stamp = find.byKey(const ValueKey('build-stamp'));
    await tester.scrollUntilVisible(stamp, 200);
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.tap(stamp);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /settings/developer'), findsNothing);
    await tester.tap(stamp);
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /settings/developer'), findsOneWidget);
  });

  testWidgets('long-pressing the build stamp opens the Developer panel',
      (tester) async {
    debugDevModeOverride = true;
    await pumpRouted(tester);
    final stamp = find.byKey(const ValueKey('build-stamp'));
    await tester.scrollUntilVisible(stamp, 200);
    await tester.pumpAndSettle();
    await tester.longPress(stamp);
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /settings/developer'), findsOneWidget);
  });

  testWidgets(
      'with dev mode off (customer build), the unlock gesture is a no-op',
      (tester) async {
    // Default: debugDevModeOverride == null → compiled kDevModeEnabled (false).
    await pumpRouted(tester);
    final stamp = find.byKey(const ValueKey('build-stamp'));
    await tester.scrollUntilVisible(stamp, 200);
    await tester.pumpAndSettle();
    // Seven taps — more than the unlock threshold — do nothing.
    for (var i = 0; i < 8; i++) {
      await tester.tap(stamp);
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /settings/developer'), findsNothing);
    // A long-press is inert too.
    await tester.longPress(stamp);
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /settings/developer'), findsNothing);
  });

  testWidgets('the Plan row opens the Plan page', (tester) async {
    await pumpRouted(tester);
    await tester.tap(find.text('Plan and credits'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /profile/plan'), findsOneWidget);
  });

  // Regression (N4): the notification-preferences screen was unreachable from
  // Settings (only via the notification-centre bell). There must now be a
  // Settings row that navigates to it — exactly the user's reported path.
  testWidgets('the Notifications row opens the notification-preferences screen',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ThemeController(initial: ThemeMode.dark);
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => SettingsScreen(
              controller: c, profileService: _FakeProfiles(), api: _api((_) {})),
        ),
        GoRoute(
          path: '/notifications/prefs',
          builder: (_, __) => const Scaffold(body: Text('NOTIF PREFS SCREEN')),
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

    final row = find.byKey(const ValueKey('settings-notifications'));
    await tester.scrollUntilVisible(row, 200);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.text('NOTIF PREFS SCREEN'), findsOneWidget);
  });

  testWidgets('tapping Accent Color pushes the accent color screen',
      (tester) async {
    final c = ThemeController(initial: ThemeMode.dark);
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => SettingsScreen(
              controller: c, profileService: _FakeProfiles(), api: _api((_) {})),
        ),
        GoRoute(
          path: '/settings/accent-color',
          builder: (_, __) =>
              const Scaffold(body: Text('ACCENT COLOR SCREEN')),
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

    await tester.tap(find.text('Accent Color'));
    await tester.pumpAndSettle();
    expect(find.text('ACCENT COLOR SCREEN'), findsOneWidget);
  });

  test('ThemeController persists and reloads the choice', () async {
    final a = ThemeController(initial: ThemeMode.dark);
    await a.set(ThemeMode.light);
    final b = ThemeController(initial: ThemeMode.dark);
    await b.load();
    expect(b.mode, ThemeMode.light);
  });

  testWidgets('Ayma switches the theme on Settings through ui_action',
      (tester) async {
    final handle = tester.ensureSemantics();
    final c = ThemeController(initial: ThemeMode.dark);
    await tester.pumpWidget(host(c, _FakeProfiles(), _api((_) {})));
    await tester.pumpAndSettle();
    final cap = ScreenCapture(
      routeOf: () => '/settings',
      popupOpen: () => false,
      settle: () => tester.pumpAndSettle(),
    );
    final s = cap.capture();
    final light = s.controls.firstWhere((c) => c.label == 'Light');
    final r = await cap.perform(control: light.id, label: 'Light', op: 'tap');
    expect(r.ok, isTrue, reason: r.reason);
    expect(c.mode, ThemeMode.light);
    handle.dispose();
  });
}
