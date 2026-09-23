import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/notification_center_screen.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/notification_bell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  // A stray pending request from another test file (TabRequest is a
  // process-lifetime singleton) must never leak into a fresh shell here.
  setUp(() => TabRequest.instance.consume());

  Widget host() =>
      MaterialApp(theme: AymaTheme.light, home: const MainShellScreen());

  testWidgets(
    'renders the 4-tab bottom nav (icon-only, no text labels) with the '
    'orb on the Ayma tab, plus a 5th notification-bell entry',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await tester.pump();

      // No painted text labels any more — each tab keeps its name only as an
      // accessible Tooltip.
      for (final label in ['AYMA', 'EXPLORE', 'MESSAGES', 'PROFILE']) {
        expect(find.text(label), findsNothing);
      }
      for (final label in ['Ayma', 'Explore', 'Messages', 'Profile']) {
        expect(find.byTooltip(label), findsOneWidget);
      }
      // The Ayma destination uses the brand orb, not an Icon.
      expect(find.byType(AymaOrb), findsWidgets);

      // The notification bell (§ founder feedback: moved out of every tab's
      // own header) now lives here as a 5th, push-only entry.
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(find.byType(NotificationBellButton), findsOneWidget);
    },
  );

  testWidgets(
    'tapping the nav-bar bell pushes the notifications route instead of '
    'switching the IndexedStack tab',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation: MainShellScreen.path,
        routes: [
          GoRoute(
            path: MainShellScreen.path,
            builder: (_, __) => const MainShellScreen(),
          ),
          // A stand-in for the real `NotificationCenterScreen` route (which
          // needs Firebase) — this only proves the bell pushes the exact
          // same path the real route is registered at
          // (`app_router.dart`'s own `NotificationCenterScreen.path` route).
          GoRoute(
            path: NotificationCenterScreen.path,
            builder: (_, __) => const Scaffold(body: Text('Notifications page')),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Notifications'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Notifications page'), findsOneWidget);
      // Pushed on top, not swapped in the shell's own IndexedStack — the
      // shell (and whichever tab it was on) is still mounted underneath.
      expect(find.byType(MainShellScreen), findsOneWidget);
    },
  );

  testWidgets('tapping Explore builds and shows the Explore tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byType(ExploreScreen), findsNothing);

    await tester.tap(find.byTooltip('Explore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(ExploreScreen), findsOneWidget);
  });

  testWidgets('back walks tab history instead of leaving the app', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();

    // Ayma -> Explore -> Ayma -> Explore. (Stick to these two tabs — the others
    // need Firebase, which isn't initialised in a widget test.)
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Ayma'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));

    // Android back presses walk that history back one step at a time, then the
    // shell stops handling the press so the app can close.
    final dynamic shell = tester.state<State>(find.byType(MainShellScreen));
    expect(shell.popTabForTest(), isTrue);
    expect(shell.popTabForTest(), isTrue);
    expect(shell.popTabForTest(), isTrue);
    expect(shell.popTabForTest(), isFalse); // back at the root entry
  });

  testWidgets(
    'a pending TabRequest (set by NavBarShell/PublicProfileScreen, elsewhere '
    'in the app) lands the fresh shell on that tab instead of the default '
    'Ayma one',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      TabRequest.instance.request(1); // Explore
      await tester.pumpWidget(host());
      await tester.pump();

      expect(find.byType(ExploreScreen), findsOneWidget);
      // Consumed, not left to leak into a later navigation.
      expect(TabRequest.instance.pending.value, isNull);
    },
  );

  testWidgets('no pending TabRequest still defaults to the Ayma tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.byType(ExploreScreen), findsNothing);
    expect(find.byTooltip('Ayma'), findsOneWidget);
  });
}
