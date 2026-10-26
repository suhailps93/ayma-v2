import 'dart:convert';

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

  @override
  Stream<bool> watchPaused() => Stream.value(paused);

  @override
  Future<void> setPaused(bool value) async {
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

    expect(find.text('User settings'), findsOneWidget);
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
          '/whats-new',
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

  testWidgets("tapping What's new pushes /whats-new", (tester) async {
    await pumpRouted(tester);
    await tester.scrollUntilVisible(find.text("What's new"), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text("What's new"));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /whats-new'), findsOneWidget);
  });

  testWidgets('seven taps on the build stamp open the Developer panel; '
      'fewer do nothing', (tester) async {
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
    await pumpRouted(tester);
    final stamp = find.byKey(const ValueKey('build-stamp'));
    await tester.scrollUntilVisible(stamp, 200);
    await tester.pumpAndSettle();
    await tester.longPress(stamp);
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /settings/developer'), findsOneWidget);
  });

  testWidgets('the Plan row opens the Plan page', (tester) async {
    await pumpRouted(tester);
    await tester.tap(find.text('Plan and credits'));
    await tester.pumpAndSettle();
    expect(find.text('ROUTE /profile/plan'), findsOneWidget);
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
