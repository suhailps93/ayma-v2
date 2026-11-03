import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/notification_center_screen.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/notification_bell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Idle voice stub that just records `start()` — the orb tap on the Ayma tab
/// now activates voice (see `MainShellScreen._onOrbTap`), with no real LiveKit
/// round trip in a widget test.
class _ShellFakeVoice extends VoiceSessionController {
  _ShellFakeVoice() : super(transcriptStore: TranscriptStore());

  int startCalls = 0;

  @override
  VoiceSessionPhase get phase => VoiceSessionPhase.idle;
  @override
  bool get isActive => false;
  @override
  bool get isListening => false;
  @override
  Future<void> start() async => startCalls++;
}

void main() {
  // A stray pending request from another test file (TabRequest is a
  // process-lifetime singleton) must never leak into a fresh shell here.
  setUp(() {
    TabRequest.instance.consume();
    // A test that opens the popup and never dismisses it leaves
    // `showAymaChatModal`'s awaited Future pending forever once `tester`'s
    // own teardown discards the widget tree out from under it, so this
    // top-level flag never gets the chance to flip back — reset it
    // explicitly so it can't leak a false "already open" into a later test.
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
  });

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

  testWidgets(
    'tapping the orb from another tab opens the page-context popup instead '
    'of switching the shell to the Ayma tab (founder ask: "like the story '
    'edit", not a navigation)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await tester.pump();

      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ExploreScreen), findsOneWidget);

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Still showing Explore underneath — the shell's own IndexedStack tab
      // never switched.
      expect(find.byType(ExploreScreen), findsOneWidget);
      // The scoped popup sheet is up instead (its drag handle is a stable
      // marker regardless of what its embedded `ChatScreen` manages to load
      // with no real backend in this test).
      expect(
        find.byKey(const ValueKey('aymaChatModalHandle')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping the orb again while the popup is already open expands that same '
    'sheet to full screen in place (no second popup), and another tab closes '
    'it and switches',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await tester.pump();

      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ExploreScreen), findsOneWidget);

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
      // real one underneath (the shell's own `bottomNavigationBar`) is still
      // mounted too.
      final popupBar = find.byKey(const ValueKey('aymaChatModalNavBar'));
      await tester.tap(
        find.descendant(of: popupBar, matching: find.byTooltip('Ayma')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('aymaChatModalHandle')), findsOneWidget);
      expect(aymaSheet.isExpanded, isTrue);
      // Still over Explore — expanding is not a tab switch.
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
        1,
      );

      await tester.tap(
        find.descendant(of: popupBar, matching: find.byTooltip('Explore')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('aymaChatModalHandle')), findsNothing);
      expect(isAymaSheetOpen, isFalse);
    },
  );

  testWidgets(
    'tapping the orb while already on the Ayma tab activates voice (the '
    'full-screen main chat is the progression shortcut)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _ShellFakeVoice();
      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: MainShellScreen(voiceController: voice),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();

      // Voice started, no chat sheet — the orb on the main chat goes straight
      // to voice (tap progression's last rung / shortcut).
      expect(voice.startCalls, 1);
      expect(find.byKey(const ValueKey('aymaChatModalHandle')), findsNothing);
    },
  );

  testWidgets('back walks tab history instead of leaving the app', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pump();

    // Ayma -> Explore -> Ayma -> Explore. (Stick to these two tabs — the others
    // need Firebase, which isn't initialised in a widget test.) The
    // middle hop back to Ayma goes through `selectTabForTest` rather than a
    // tap on the orb's own tooltip: tapping it from Explore now opens the
    // scoped page-context popup instead of switching tabs (see
    // `MainShellScreen._onTabTap`) — this test is only exercising the
    // history mechanism itself, which is unchanged.
    final dynamic shell = tester.state<State>(find.byType(MainShellScreen));
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));
    shell.selectTabForTest(0);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));

    // Android back presses walk that history back one step at a time, then the
    // shell stops handling the press so the app can close.
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
