import 'dart:convert';

import 'package:ayma_flutter/screens/ayma_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
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

  Widget host(ApiClient a) => MaterialApp(
        theme: AymaTheme.light,
        home: AymaSettingsScreen(api: a),
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

    await tester.tap(find.text('Ayma’s models'));
    await tester.pumpAndSettle();
    expect(find.text('VOICE SCREEN'), findsOneWidget);
  });

  testWidgets('the Connect an agent (MCP) row opens the connect-agent screen',
      (tester) async {
    final router = GoRouter(
      initialLocation: AymaSettingsScreen.path,
      routes: [
        GoRoute(
          path: AymaSettingsScreen.path,
          builder: (_, __) => AymaSettingsScreen(api: _api((_) {})),
        ),
        GoRoute(
          path: '/settings/connect-agent',
          builder: (_, __) => const Scaffold(body: Text('CONNECT SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.text('Let your own AI agent use Ayma'), findsOneWidget);
    await tester.tap(find.text('Connect an agent (MCP)'));
    await tester.pumpAndSettle();
    expect(find.text('CONNECT SCREEN'), findsOneWidget);
  });

  testWidgets('no Animation section and no wing-flutter toggles remain',
      (tester) async {
    await tester.pumpWidget(host(_api((_) {})));
    await tester.pumpAndSettle();

    // Founder call (2026-11-07): the wing-flutter options are gone —
    // the flutter is simply always on. No section, no switches.
    expect(find.text('Animation'), findsNothing);
    expect(find.text('Wing flutter animation'), findsNothing);
    expect(find.text('Wing flutter in nav bar'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    // The rest of the screen is intact.
    expect(find.text('Connect an agent (MCP)'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Wipe what Ayma has learned'), 200);
    await tester.pumpAndSettle();
    expect(find.text('Wipe what Ayma has learned'), findsOneWidget);
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
