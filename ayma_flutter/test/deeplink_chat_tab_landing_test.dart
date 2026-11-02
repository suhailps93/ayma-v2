import 'package:ayma_flutter/routing/app_router.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// J1 LEG2 follow-up (QA on-device, build 2243): the J1 fix routes the
/// root-shell deep link through `navigateToRoute` with `go('/')` so it reuses
/// the single live `MainShellScreen` instead of `push`ing a duplicate. Because
/// `go('/')` reuses whatever tab the shell happens to be on, tapping the self
/// web-search / skill-result notification FROM A NON-CHAT TAB (e.g. Explore)
/// left the user on that tab — the chat with the report card was never shown,
/// so the notification appeared to do nothing.
///
/// QA's exact repro: Explore tab → open Notifications → tap the web-search
/// entry → landed back on Explore, report not visible. The fix posts a
/// [TabRequest] for the Ayma/chat tab before the `go`, so a reused shell
/// switches to chat (and a freshly-built one starts there). These tests
/// reproduce that path and assert the chat tab ends active — still a single
/// live shell, no duplicate-GlobalKey / RenderFlex throw (don't regress J1).
void main() {
  setUp(() => TabRequest.instance.pending.value = null);
  tearDown(() => TabRequest.instance.pending.value = null);

  group('navigateToRoute dispatcher contract', () {
    testWidgets('resolving the root shell posts a chat-tab TabRequest',
        (tester) async {
      final router = GoRouter(
        initialLocation: MainShellScreen.path,
        routes: [
          GoRoute(
            path: MainShellScreen.path,
            builder: (context, state) => const Scaffold(body: Text('shell')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      navigateToRoute(MainShellScreen.path, router: router);
      await tester.pump();

      // Pre-fix this is null (the dispatcher never touched TabRequest); post-fix
      // it names the chat tab, which is what lands the user on the report card.
      expect(TabRequest.instance.pending.value, MainShellScreen.aymaTabIndex);
    });

    testWidgets('a detail-route deep link posts no tab request (untouched)',
        (tester) async {
      final router = GoRouter(
        initialLocation: MainShellScreen.path,
        routes: [
          GoRoute(
            path: MainShellScreen.path,
            builder: (context, state) => const Scaffold(body: Text('shell')),
          ),
          GoRoute(
            path: '/dm/:id',
            builder: (context, state) => const Scaffold(body: Text('dm')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      navigateToRoute('/dm/abc', router: router);
      await tester.pumpAndSettle();

      expect(TabRequest.instance.pending.value, isNull);
      expect(find.text('dm'), findsOneWidget);
    });
  });

  testWidgets(
      'QA path: live shell on a non-chat tab receives the web-search deep link '
      'and ends on the chat tab — single shell, no duplicate-GlobalKey throw',
      (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    final router = GoRouter(
      initialLocation: MainShellScreen.path,
      routes: [
        GoRoute(
          path: MainShellScreen.path,
          builder: (context, state) => const _TabShell(),
        ),
        // The notification center is pushed on top of the live shell; the
        // shell stays mounted (offstage) beneath it, still consuming requests.
        GoRoute(
          path: '/notifications',
          builder: (context, state) =>
              const Scaffold(body: Text('notifications')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // Shell starts on the chat tab (index 0), like the real shell. The user
    // moves to the Explore tab (index 1) — QA's starting point.
    final shellState = tester.state<_TabShellState>(find.byType(_TabShell));
    shellState.selectTab(1);
    await tester.pumpAndSettle();
    expect(find.text('tab: explore'), findsOneWidget);

    // Open the notification center on top of the Explore-tab shell.
    router.push('/notifications');
    await tester.pumpAndSettle();
    expect(find.text('notifications'), findsOneWidget);

    // Tap the web-search / skill-result entry → it resolves to '/'. The fixed
    // dispatcher reuses the single shell AND asks for the chat tab.
    navigateToRoute(MainShellScreen.path, router: router);
    await tester.pumpAndSettle();

    // Lands on chat — pre-fix this stayed on Explore (the QA bug).
    expect(find.text('tab: chat'), findsOneWidget);
    expect(find.text('tab: explore'), findsNothing);
    // Still exactly one live shell (no duplicate composer anchor): J1 intact.
    expect(find.byType(_TabShell), findsOneWidget);
    expect(
      errors.where((e) =>
          e.exceptionAsString().contains('Duplicate GlobalKey') ||
          e.exceptionAsString().contains('was mutated')),
      isEmpty,
      reason: 'Reusing the shell must not stack a second one (J1).',
    );
    expect(errors, isEmpty, reason: 'No framework exception may be thrown.');
  });

  testWidgets('already on the chat tab: the deep link keeps it on chat',
      (tester) async {
    final router = GoRouter(
      initialLocation: MainShellScreen.path,
      routes: [
        GoRoute(
          path: MainShellScreen.path,
          builder: (context, state) => const _TabShell(),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('tab: chat'), findsOneWidget);

    navigateToRoute(MainShellScreen.path, router: router);
    await tester.pumpAndSettle();

    expect(find.text('tab: chat'), findsOneWidget);
    expect(find.byType(_TabShell), findsOneWidget);
  });
}

/// A minimal stand-in for [MainShellScreen] that mirrors exactly how the real
/// shell receives a tab hand-off: it listens to [TabRequest] (both live and on
/// first build) and swaps the active tab via `setState`, and it mounts the same
/// process-wide composer anchor GlobalKey on the chat tab, so a second live
/// mount would surface the J1 duplicate-key error. The real shell is driven by
/// Firebase/voice/session singletons that a unit test can't stand up, so this
/// faithful stub isolates the routing + tab-selection contract under test.
class _TabShell extends StatefulWidget {
  const _TabShell();

  @override
  State<_TabShell> createState() => _TabShellState();
}

class _TabShellState extends State<_TabShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    TabRequest.instance.pending.addListener(_consumeTabRequest);
    _consumeTabRequest();
  }

  @override
  void dispose() {
    TabRequest.instance.pending.removeListener(_consumeTabRequest);
    super.dispose();
  }

  void _consumeTabRequest() {
    final target = TabRequest.instance.consume();
    if (target != null && target != _index && mounted) selectTab(target);
  }

  void selectTab(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          SizedBox(
            key: TourAnchors.keyFor(TourAnchors.homeComposer),
            child: const Text('tab: chat'),
          ),
          const Text('tab: explore'),
        ],
      ),
    );
  }
}
