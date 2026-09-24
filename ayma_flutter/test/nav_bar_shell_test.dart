// NavBarShell (§ persistent bottom nav bar on every screen, no exceptions):
// wraps a pushed screen with the app's one AymaTabBar, and tapping any of its
// four icons hands off which tab to land on (TabRequest) then routes back to
// the shell (`MainShellScreen.path`). Uses a tiny local GoRouter with a plain
// marker at '/' — the real MainShellScreen needs Firebase, not available in a
// bare widget test (see main_shell_screen_test.dart's own note on this).
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/nav_bar_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _ShellMarker extends StatelessWidget {
  const _ShellMarker();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('screen:shell')));
}

class _OtherScreen extends StatelessWidget {
  const _OtherScreen();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('screen:other')));
}

GoRouter _router() => GoRouter(
      initialLocation: '/other',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const _ShellMarker()),
        GoRoute(
          path: '/other',
          builder: (_, __) => const NavBarShell(child: _OtherScreen()),
        ),
      ],
    );

Widget _host(GoRouter router) =>
    MaterialApp.router(theme: AymaTheme.light, routerConfig: router);

void main() {
  // TabRequest is a process-lifetime singleton (by design — see its own
  // doc) — clear any value a previous test left pending so tests can't leak
  // into each other.
  setUp(() => TabRequest.instance.consume());

  testWidgets('wraps the screen with a bottom nav bar, no tab highlighted', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_router()));
    await tester.pump();

    expect(find.text('screen:other'), findsOneWidget);
    expect(find.byType(AymaTabBar), findsOneWidget);
    final bar = tester.widget<AymaTabBar>(find.byType(AymaTabBar));
    expect(bar.index, -1);
  });

  testWidgets(
    'tapping a tab pushes a TabRequest and routes back into the shell',
    (tester) async {
      await tester.pumpWidget(_host(_router()));
      await tester.pump();
      expect(find.text('screen:other'), findsOneWidget);

      await tester.tap(find.byTooltip('Messages'));
      await tester.pumpAndSettle();

      expect(find.text('screen:shell'), findsOneWidget);
      expect(find.text('screen:other'), findsNothing);
    },
  );

  testWidgets(
    'tapping Ayma opens the page-context popup instead of navigating back '
    'to the shell (founder ask: "like the story edit", not a full-screen '
    'jump)',
    (tester) async {
      await tester.pumpWidget(_host(_router()));
      await tester.pump();

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // No TabRequest queued and no navigation back to the shell — the
      // wrapped screen is still showing, with the popup sheet docked over
      // it.
      expect(TabRequest.instance.pending.value, isNull);
      expect(find.text('screen:other'), findsOneWidget);
      expect(find.text('screen:shell'), findsNothing);
      expect(
        find.byKey(const ValueKey('aymaChatModalHandle')),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping Profile pushes index 3', (tester) async {
    await tester.pumpWidget(_host(_router()));
    await tester.pump();

    await tester.tap(find.byTooltip('Profile'));
    await tester.pump();

    expect(TabRequest.instance.consume(), 3);
  });
}
