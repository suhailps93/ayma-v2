import 'dart:convert';

import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
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

  Widget host(ThemeController c, ProfileService p, ApiClient a) => AnimatedBuilder(
        animation: c,
        builder: (context, _) => MaterialApp(
          theme: AymaTheme.light,
          darkTheme: AymaTheme.dark,
          themeMode: c.mode,
          home: SettingsScreen(controller: c, profileService: p, api: a),
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

  testWidgets('pause matching toggle writes the flag', (tester) async {
    final profiles = _FakeProfiles();
    await tester.pumpWidget(host(
        ThemeController(initial: ThemeMode.dark), profiles, _api((_) {})));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pause matching'));
    await tester.pumpAndSettle();
    expect(profiles.pausedWrites, [true]);
  });

  testWidgets('wiki reset confirms then calls the endpoint', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(ThemeController(initial: ThemeMode.dark),
        _FakeProfiles(), _api(calls.add)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wipe what Ayma has learned'));
    await tester.pumpAndSettle();
    expect(find.text('Wipe what Ayma has learned?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Wipe'));
    await tester.pumpAndSettle();
    expect(calls, contains('/wiki/reset'));
  });

  testWidgets('tapping the build tag pushes /whats-new', (tester) async {
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
          path: '/whats-new',
          builder: (_, __) =>
              const Scaffold(body: Text('WHATS NEW SCREEN')),
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

    await tester.scrollUntilVisible(find.textContaining('Build'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Build'));
    await tester.pumpAndSettle();
    expect(find.text('WHATS NEW SCREEN'), findsOneWidget);
  });

  test('ThemeController persists and reloads the choice', () async {
    final a = ThemeController(initial: ThemeMode.dark);
    await a.set(ThemeMode.light);
    final b = ThemeController(initial: ThemeMode.dark);
    await b.load();
    expect(b.mode, ThemeMode.light);
  });
}
