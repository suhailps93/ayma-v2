import 'dart:convert';

import 'package:ayma_flutter/screens/ayma_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/orb_animation_settings.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Widget host(ApiClient a, {OrbAnimationSettings? orbAnim}) => MaterialApp(
        theme: AymaTheme.light,
        home: AymaSettingsScreen(api: a, orbAnimationSettings: orbAnim),
      );

  testWidgets('the Ayma\'s voice row opens the voice preference screen',
      (tester) async {
    final router = GoRouter(
      initialLocation: AymaSettingsScreen.path,
      routes: [
        GoRoute(
          path: AymaSettingsScreen.path,
          builder: (_, __) => AymaSettingsScreen(api: _api((_) {})),
        ),
        GoRoute(
          path: '/settings/voice',
          builder: (_, __) => const Scaffold(body: Text('VOICE SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ayma’s voice'));
    await tester.pumpAndSettle();
    expect(find.text('VOICE SCREEN'), findsOneWidget);
  });

  testWidgets('animation section renders both wing-flutter toggles, ON by '
      'default', (tester) async {
    final orbAnim = OrbAnimationSettings();
    await tester.pumpWidget(host(_api((_) {}), orbAnim: orbAnim));
    await tester.pumpAndSettle();

    expect(find.text('Animation'), findsOneWidget);
    final master = tester.widget<SwitchListTile>(find.ancestor(
        of: find.text('Wing flutter animation'),
        matching: find.byType(SwitchListTile)));
    final nav = tester.widget<SwitchListTile>(find.ancestor(
        of: find.text('Wing flutter in nav bar'),
        matching: find.byType(SwitchListTile)));
    expect(master.value, isTrue);
    expect(nav.value, isTrue);
    expect(nav.onChanged, isNotNull);
  });

  testWidgets('wing-flutter toggles write the settings and the nav sub-toggle '
      'disables when everywhere is off', (tester) async {
    final orbAnim = OrbAnimationSettings();
    await tester.pumpWidget(host(_api((_) {}), orbAnim: orbAnim));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wing flutter in nav bar'));
    await tester.pumpAndSettle();
    expect(orbAnim.navBarFlutterEnabled, isFalse);
    expect(orbAnim.flutterEnabled, isTrue);

    await tester.tap(find.text('Wing flutter animation'));
    await tester.pumpAndSettle();
    expect(orbAnim.flutterEnabled, isFalse);

    // Everywhere-off wins: the scoped toggle is now disabled (inert).
    final nav = tester.widget<SwitchListTile>(find.ancestor(
        of: find.text('Wing flutter in nav bar'),
        matching: find.byType(SwitchListTile)));
    expect(nav.onChanged, isNull);
    expect(find.text('Turn on “Wing flutter animation” first.'),
        findsOneWidget);
    final navOff = orbAnim.navBarFlutterEnabled;
    await tester.tap(find.text('Wing flutter in nav bar'));
    await tester.pumpAndSettle();
    expect(orbAnim.navBarFlutterEnabled, navOff,
        reason: 'a disabled sub-toggle must not change the setting');
  });

  testWidgets('wiki reset confirms then calls the endpoint', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(_api(calls.add)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
        find.text('Wipe what Ayma has learned'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wipe what Ayma has learned'));
    await tester.pumpAndSettle();
    expect(find.text('Wipe what Ayma has learned?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Wipe'));
    await tester.pumpAndSettle();
    expect(calls, contains('/wiki/reset'));
  });

}
