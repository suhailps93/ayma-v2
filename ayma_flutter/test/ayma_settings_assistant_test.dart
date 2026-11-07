import 'dart:convert';

import 'package:ayma_flutter/screens/assistant_screen.dart';
import 'package:ayma_flutter/screens/ayma_settings_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/assistant_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAssistantService extends AssistantService {
  FakeAssistantService({this.isDefault = false});

  bool isDefault;
  int openSettingsCalls = 0;

  @override
  Future<bool> isDefaultAssistant() async => isDefault;

  @override
  Future<bool> openDefaultAssistantSettings() async {
    openSettingsCalls++;
    return true;
  }
}

ApiClient _api() {
  final mock = MockClient((req) async {
    return http.Response(jsonEncode({'ok': true}), 200);
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the Assistant rows render and deep-link to system settings',
      (tester) async {
    final service = FakeAssistantService(isDefault: false);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: AymaSettingsScreen(api: _api(), assistantService: service),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
        find.byKey(const Key('ayma_settings_default_assistant')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ayma_settings_assistant')), findsOneWidget);
    expect(find.text('Choose Ayma in Android default app settings'),
        findsOneWidget);
    expect(find.textContaining('never stored'), findsOneWidget);

    await tester.tap(find.byKey(const Key('ayma_settings_default_assistant')));
    await tester.pumpAndSettle();
    expect(service.openSettingsCalls, 1);
  });

  testWidgets('the Ayma Assistant row opens the assistant surface',
      (tester) async {
    final router = GoRouter(
      initialLocation: AymaSettingsScreen.path,
      routes: [
        GoRoute(
          path: AymaSettingsScreen.path,
          builder: (_, __) => AymaSettingsScreen(
            api: _api(),
            assistantService: FakeAssistantService(isDefault: true),
          ),
        ),
        GoRoute(
          path: AssistantScreen.path,
          builder: (_, __) => const Scaffold(body: Text('ASSISTANT SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router));
    await tester.pumpAndSettle();

    await tester
        .ensureVisible(find.byKey(const Key('ayma_settings_assistant')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ayma is your default assistant'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('ayma_settings_assistant')));
    await tester.pumpAndSettle();
    expect(find.text('ASSISTANT SCREEN'), findsOneWidget);
  });
}
