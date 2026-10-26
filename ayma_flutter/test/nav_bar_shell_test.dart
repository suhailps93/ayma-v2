// NavBarShell (§ persistent bottom nav bar on every screen, no exceptions):
// wraps a pushed screen with the app's one AymaTabBar, and tapping any of its
// four icons hands off which tab to land on (TabRequest) then routes back to
// the shell (`MainShellScreen.path`). Uses a tiny local GoRouter with a plain
// marker at '/' — the real MainShellScreen needs Firebase, not available in a
// bare widget test (see main_shell_screen_test.dart's own note on this).
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
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
  setUp(() {
    TabRequest.instance.consume();
    // A test that opens the popup and never dismisses it leaves
    // `showAymaChatModal`'s awaited Future pending forever once `tester`'s
    // own teardown discards the widget tree out from under it, so this
    // top-level flag never gets the chance to flip back — reset it
    // explicitly so it can't leak a false "already open" into a later test.
    isPageContextAymaPopupOpen = false;
  });

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

  testWidgets(
    'tapping Ayma again while the popup is already open expands that same '
    'sheet to full screen in place (no second popup, no navigation)',
    (tester) async {
      // A real phone-sized viewport, not flutter_test's tiny ~800x600
      // default — the popup here embeds a real `ChatScreen`, and reserving
      // this bar's own height (`persistentBottomBarHeight`) out of an
      // already-small default window leaves too little room for its fixed
      // chrome (header/composer), overflowing in a way no actual phone
      // screen would.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_router()));
      await tester.pump();

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('aymaChatModalHandle')),
        findsOneWidget,
      );

      // The popup carries its own on-top copy of this bar (so it stays
      // visible/tappable while open — see `ayma_chat_modal.dart`'s
      // `persistentBottomBar`); address that copy specifically since the
      // real one underneath is still mounted too.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('aymaChatModalNavBar')),
          matching: find.byTooltip('Ayma'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('aymaChatModalHandle')),
        findsOneWidget,
      );
      expect(pageContextAymaPopupSheet.isExpanded, isTrue);
      expect(find.text('screen:shell'), findsNothing);
    },
  );

  testWidgets('tapping Profile pushes index 3', (tester) async {
    await tester.pumpWidget(_host(_router()));
    await tester.pump();

    await tester.tap(find.byTooltip('Profile'));
    await tester.pump();

    expect(TabRequest.instance.consume(), 3);
  });

  // Founder report, still reproducing on the newest build even after an
  // earlier investigation concluded the layout math looked correct: with the
  // on-screen keyboard open, the popup renders short and a copy of the nav
  // bar floats mid-screen instead of at the true available (post-keyboard)
  // bottom. That earlier investigation's tests (`ayma_chat_modal_test.dart`)
  // only ever drove `showAymaChatModal` directly against placeholder
  // content — never the *real* `showPageContextAymaPopup` → real `ChatScreen`
  // → real composer `TextField` this founder complaint is actually about.
  // This exercises that exact real path: a real device-sized viewport, a
  // real safe-area inset, tapping the real composer to focus it, then
  // opening a live keyboard inset on top of that safe-area inset — matching
  // what `MediaQueryData`'s own docs say a real device reports once the
  // keyboard exceeds the safe-area inset (`padding.bottom` drops to 0).
  testWidgets(
    'the real popup keeps its nav-bar copy at the true available bottom '
    'once a live keyboard opens over the real composer',
    (tester) async {
      const ratio = 2.0;
      const safeAreaBottom = 34.0;
      const keyboardHeight = 336.0;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = ratio;
      tester.view.padding =
          const FakeViewPadding(bottom: safeAreaBottom * ratio);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_router()));
      await tester.pump();

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('aymaChatModalHandle')),
        findsOneWidget,
      );

      // Focus the real composer, like a user about to type — this is what
      // actually opens the keyboard on a real device.
      await tester.tap(find.byType(TextField));
      await tester.pump();

      // The keyboard slides open. Per `MediaQueryData`'s documented
      // `padding = max(0, viewPadding - viewInsets)` relationship, the real,
      // on-device safe-area `padding.bottom` drops to 0 the instant the
      // keyboard (336) exceeds it (34) — `tester.view.padding` doesn't
      // auto-derive that the way the real engine does, so both are set
      // explicitly to reproduce exactly what a real device reports.
      tester.view.viewInsets =
          const FakeViewPadding(bottom: keyboardHeight * ratio);
      tester.view.padding = const FakeViewPadding(bottom: 0);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final availableBottom = screenHeight - keyboardHeight;

      final navBarCopy = find.descendant(
        of: find.byKey(const ValueKey('aymaChatModalNavBar')),
        matching: find.byType(AymaTabBar),
      );
      expect(navBarCopy, findsOneWidget);
      final barRect = tester.getRect(navBarCopy);

      // The nav bar must sit flush against the true available bottom — just
      // above the keyboard — not floating mid-screen with real app content
      // (`screen:other`, dimmed behind the barrier) exposed below it.
      expect(barRect.bottom, closeTo(availableBottom, 1));

      final handleBottom = tester.getBottomLeft(
        find.byKey(const ValueKey('aymaChatModalHandle')),
      ).dy;
      expect(handleBottom, lessThanOrEqualTo(barRect.top + 1));
    },
  );
}
