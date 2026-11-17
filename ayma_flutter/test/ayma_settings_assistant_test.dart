import 'package:ayma_flutter/screens/assistant_screen.dart';
import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/assist_context.dart';
import 'package:ayma_flutter/services/assistant_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAssistantService extends AssistantService {
  FakeAssistantService({this.isDefault = false, this.openResult = true});

  bool isDefault;

  /// What [openDefaultAssistantSettings] reports back: true = a system
  /// settings surface opened, false = none could be opened (row 2r — the
  /// native side now returns the real outcome instead of unconditional
  /// success).
  bool openResult;
  int openSettingsCalls = 0;

  @override
  Future<bool> isDefaultAssistant() async => isDefault;

  @override
  Future<bool> openDefaultAssistantSettings() async {
    openSettingsCalls++;
    return openResult;
  }

  @override
  Future<AssistCapture?> takePendingAssist() async => null;

  @override
  Future<bool> hasPendingAssist() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // The consolidated Settings screen is a long ListView; a tall surface
  // builds every row (including the assistant row near the bottom) so the
  // finders resolve without scrolling the lazy list.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
      'Settings has a SINGLE assistant entry — the old "Default assistant '
      'app" shortcut row is gone (row 2r)', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: SettingsScreen(
        assistantService: FakeAssistantService(isDefault: false),
      ),
    ));
    await tester.pumpAndSettle();

    // The one kept entry.
    expect(find.byKey(const Key('ayma_settings_assistant')), findsOneWidget);
    // The deleted duplicate shortcut row.
    expect(find.byKey(const Key('ayma_settings_default_assistant')),
        findsNothing);
    expect(find.text('Default assistant app'), findsNothing);
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

  // Founder's exact path (row 2r): tap "Open assistant settings" on the
  // Ayma Assistant screen. When no system surface opens, the user must see
  // a message instead of nothing.
  testWidgets(
      'assistant screen button shows a visible message when no settings '
      'surface opens', (tester) async {
    useTallSurface(tester);
    final service = FakeAssistantService(isDefault: false, openResult: false);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: AssistantScreen(service: service),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('assistant_open_settings')));
    await tester.pump(); // fire the async handler
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.openSettingsCalls, 1);
    expect(find.textContaining('assistant settings on this device'),
        findsOneWidget);

    // Let the toast's auto-dismiss timer fire so none is pending at teardown.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'assistant screen button stays silent when a settings surface opens',
      (tester) async {
    useTallSurface(tester);
    final service = FakeAssistantService(isDefault: false, openResult: true);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: AssistantScreen(service: service),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('assistant_open_settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(service.openSettingsCalls, 1);
    expect(find.textContaining('assistant settings on this device'),
        findsNothing);
  });
}
