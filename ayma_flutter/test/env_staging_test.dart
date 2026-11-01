import 'package:ayma_flutter/env.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/nav_bar_shell.dart';
import 'package:ayma_flutter/widgets/staging_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    TabRequest.instance.consume();
    isPageContextAymaPopupOpen = false;
  });

  Finder findStagingBanner() => find.byWidgetPredicate(
        (w) => w is Banner && w.message == 'STAGING',
      );

  group('Env staging configuration', () {
    test('production remains the default when ENV is unset', () {
      expect(
        Env.prodApiBaseUrl,
        'https://ayma-api-235381544962.us-central1.run.app',
      );
      expect(
        Env.stagingApiBaseUrl,
        'https://ayma-api-staging.invalid',
      );
      expect(Env.env, 'production');
      expect(Env.isStaging, isFalse);
      expect(Env.apiBaseUrl, Env.prodApiBaseUrl);
    });
  });

  group('StagingBanner widget', () {
    testWidgets('renders child directly when not enabled', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: StagingBanner(
            enabled: false,
            child: Text('app_content'),
          ),
        ),
      );

      expect(find.text('app_content'), findsOneWidget);
      expect(findStagingBanner(), findsNothing);
      expect(find.text('STAGING'), findsNothing);
    });

    testWidgets('renders visible STAGING banner when enabled', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: StagingBanner(
            enabled: true,
            child: Text('app_content'),
          ),
        ),
      );

      expect(find.text('app_content'), findsOneWidget);
      final bannerFinder = findStagingBanner();
      expect(bannerFinder, findsOneWidget);

      final banner = tester.widget<Banner>(bannerFinder);
      expect(banner.message, 'STAGING');
      expect(banner.location, BannerLocation.topEnd);
    });

    testWidgets('does not duplicate banner when ancestor banner is already active', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: StagingBanner(
            enabled: true,
            child: StagingBanner(
              child: Text('app_content'),
            ),
          ),
        ),
      );

      expect(find.text('app_content'), findsOneWidget);
      expect(findStagingBanner(), findsOneWidget);
    });
  });

  group('App shell staging banner integration', () {
    testWidgets('MainShellScreen renders staging banner when showStagingBanner is true', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AymaTheme.light,
          home: const MainShellScreen(showStagingBanner: true),
        ),
      );
      await tester.pump();

      expect(find.byType(MainShellScreen), findsOneWidget);
      final bannerFinder = findStagingBanner();
      expect(bannerFinder, findsOneWidget);
      final banner = tester.widget<Banner>(bannerFinder);
      expect(banner.message, 'STAGING');
    });

    testWidgets('MainShellScreen does not render staging banner when showStagingBanner is false', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AymaTheme.light,
          home: const MainShellScreen(showStagingBanner: false),
        ),
      );
      await tester.pump();

      expect(find.byType(MainShellScreen), findsOneWidget);
      expect(findStagingBanner(), findsNothing);
    });

    testWidgets('NavBarShell renders staging banner when showStagingBanner is true', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AymaTheme.light,
          home: const Scaffold(
            body: NavBarShell(
              showStagingBanner: true,
              child: Text('screen_under_shell'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('screen_under_shell'), findsOneWidget);
      final bannerFinder = findStagingBanner();
      expect(bannerFinder, findsOneWidget);
      final banner = tester.widget<Banner>(bannerFinder);
      expect(banner.message, 'STAGING');
    });

    testWidgets('NavBarShell does not render staging banner when showStagingBanner is false', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AymaTheme.light,
          home: const Scaffold(
            body: NavBarShell(
              showStagingBanner: false,
              child: Text('screen_under_shell'),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('screen_under_shell'), findsOneWidget);
      expect(findStagingBanner(), findsNothing);
    });
  });
}
