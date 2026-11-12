import 'package:ayma_flutter/screens/assistant_screen.dart';
import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/assistant_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The consolidated Settings screen is a long ListView; a tall surface
  // builds every row (including the assistant rows near the bottom) so the
  // finders resolve without scrolling the lazy list.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('the Assistant rows render and deep-link to system settings',
      (tester) async {
    useTallSurface(tester);
    final service = FakeAssistantService(isDefault: false);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: SettingsScreen(assistantService: service),
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
    useTallSurface(tester);
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => SettingsScreen(
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
