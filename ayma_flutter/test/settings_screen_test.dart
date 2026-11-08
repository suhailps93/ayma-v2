import 'package:ayma_flutter/dev_mode.dart';
import 'package:ayma_flutter/screens/appearance_settings_screen.dart';
import 'package:ayma_flutter/screens/settings_screen.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:ayma_flutter/services/theme_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    debugDevModeOverride = null;
  });

  Future<void> pumpRouted(
    WidgetTester tester, {
    PackageInfo? packageInfo,
    String? environment,
  }) async {
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => SettingsScreen(
            packageInfoOverride: packageInfo,
            environmentOverride: environment,
          ),
        ),
        GoRoute(
          path: '/profile/plan',
          builder: (_, __) => const Scaffold(body: Text('PLAN SCREEN')),
        ),
        GoRoute(
          path: '/notifications/prefs',
          builder: (_, __) => const Scaffold(body: Text('PREFS SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router));
    await tester.pumpAndSettle();
  }

  Future<void> scrollToStamp(WidgetTester tester) async {
    // The version stamp is the last ListView child; with the guided-tour
    // tile kept on the merged page it sits below the test viewport fold.
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('build-stamp')), 200);
    await tester.pumpAndSettle();
  }

  PackageInfo pkg() => PackageInfo(
        appName: 'Ayma',
        packageName: 'com.ayma.ayma_flutter',
        version: '1.30.0',
        buildNumber: '2264',
      );

  testWidgets('shows a clean version string, not a raw build SHA',
      (tester) async {
    await pumpRouted(tester, packageInfo: pkg(), environment: 'production');

    await scrollToStamp(tester);

    expect(find.byKey(const ValueKey('build-stamp')), findsOneWidget);
    expect(find.text('Version 1.30.0+2264'), findsOneWidget);
  });

  testWidgets('shows the staging environment suffix when staged',
      (tester) async {
    await pumpRouted(tester, packageInfo: pkg(), environment: 'staging');

    await scrollToStamp(tester);

    expect(find.text('Version 1.30.0+2264 · staging'), findsOneWidget);
  });

  Future<void> pumpDevRouted(WidgetTester tester,
      {required String environment}) async {
    final router = GoRouter(
      initialLocation: SettingsScreen.path,
      routes: [
        GoRoute(
          path: SettingsScreen.path,
          builder: (_, __) => SettingsScreen(
            packageInfoOverride: pkg(),
            environmentOverride: environment,
          ),
        ),
        GoRoute(
          path: '/settings/developer',
          builder: (_, __) => const Scaffold(body: Text('DEVELOPER SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router));
    await tester.pumpAndSettle();
  }

  testWidgets('seven version taps open the Developer panel when dev mode is on',
      (tester) async {
    debugDevModeOverride = true;
    await pumpDevRouted(tester, environment: 'staging');

    await scrollToStamp(tester);

    final stamp = find.byKey(const ValueKey('build-stamp'));
    for (var i = 0; i < 7; i++) {
      await tester.tap(stamp);
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(find.text('DEVELOPER SCREEN'), findsOneWidget);
  });

  testWidgets(
      'a version long-press opens the Developer panel when dev mode is on',
      (tester) async {
    debugDevModeOverride = true;
    await pumpDevRouted(tester, environment: 'staging');

    await scrollToStamp(tester);

    await tester.longPress(find.byKey(const ValueKey('build-stamp')));
    await tester.pumpAndSettle();
    expect(find.text('DEVELOPER SCREEN'), findsOneWidget);
  });

  testWidgets('seven version taps do nothing when dev mode is off',
      (tester) async {
    await pumpDevRouted(tester, environment: 'production');

    await scrollToStamp(tester);

    final stamp = find.byKey(const ValueKey('build-stamp'));
    for (var i = 0; i < 7; i++) {
      await tester.tap(stamp);
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    expect(find.text('DEVELOPER SCREEN'), findsNothing);
  });

  testWidgets('tapping Plan and credits opens the Plan screen',
      (tester) async {
    await pumpRouted(tester);
    await tester.tap(find.byKey(const ValueKey('settings-plan')));
    await tester.pumpAndSettle();
    expect(find.text('PLAN SCREEN'), findsOneWidget);
  });

  testWidgets('tapping Notification preferences opens the prefs screen',
      (tester) async {
    await pumpRouted(tester);

    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-notifications')), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-notifications')));
    await tester.pumpAndSettle();
    expect(find.text('PREFS SCREEN'), findsOneWidget);
  });

  test('ThemeController persists and reloads the mode', () async {
    final c = ThemeController();
    await c.set(ThemeMode.dark);
    expect(c.mode, ThemeMode.dark);
    final reloaded = ThemeController();
    await reloaded.load();
    expect(reloaded.mode, ThemeMode.dark);
  });

  testWidgets('Ayma switches the theme on Appearance through ui_action',
      (tester) async {
    // The hardware behind the earlier failure: the control IS in the tree
    // and dispatching SemanticsAction.tap on its semantics node really does
    // flip the theme (the real defect was the agent being told only to
    // *check* the route — ScreenCapture now enacts the labelled control).
    final handle = tester.ensureSemantics();
    final c = ThemeController(initial: ThemeMode.dark);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      darkTheme: AymaTheme.dark,
      home: AppearanceSettingsScreen(controller: c),
    ));
    await tester.pumpAndSettle();

    final cap = ScreenCapture(
      routeOf: () => '/settings/appearance',
      popupOpen: () => false,
      settle: () => tester.pumpAndSettle(),
    );
    final shot = cap.capture();
    final light = shot.controls.singleWhere((x) => x.label == 'Light');
    expect(light.noAct, isFalse);

    final result =
        await cap.perform(control: light.id, label: light.label, op: 'tap');
    expect(result.ok, isTrue, reason: result.reason);
    // The radio's onChanged runs through the semantics tap handler.
    expect(c.mode, ThemeMode.light);
    handle.dispose();
  });
}
