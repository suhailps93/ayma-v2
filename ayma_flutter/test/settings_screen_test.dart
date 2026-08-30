import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('appearance toggle switches theme mode and rebuilds', (tester) async {
    final controller = ThemeController(initial: ThemeMode.dark);

    await tester.pumpWidget(AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        theme: AymaTheme.light,
        darkTheme: AymaTheme.dark,
        themeMode: controller.mode,
        home: SettingsScreen(controller: controller),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Match system'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.light);

    await tester.tap(find.text('Match system'));
    await tester.pumpAndSettle();
    expect(controller.mode, ThemeMode.system);
  });

  test('ThemeController persists and reloads the choice', () async {
    final a = ThemeController(initial: ThemeMode.dark);
    await a.set(ThemeMode.light);

    final b = ThemeController(initial: ThemeMode.dark);
    await b.load();
    expect(b.mode, ThemeMode.light);
  });
}
