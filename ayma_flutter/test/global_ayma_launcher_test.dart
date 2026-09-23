// The app-wide floating "Ask Ayma" button (§F4 — Gemini-in-Gmail reference):
// renders/opens from any route, opens the real ChatScreen wired to the one
// app-wide AymaSession (same instances MainShellScreen's own Ayma tab uses),
// carries page context in, and suppresses itself appropriately.
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/global_ayma_launcher.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// So opening the sheet's embedded `ChatScreen` resolves its history load
/// instantly instead of hitting the network in a test (same trick every
/// other embedded-`ChatScreen`-sheet test in this app already uses).
class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  @override
  Future<({List<ChatMessage> messages, String? nextBefore})> chatHistory({
    String? before,
    int limit = 40,
  }) async => (messages: const <ChatMessage>[], nextBefore: null);
}

/// A stand-in for a real pushed screen: sets [AppContext] in `initState` the
/// same way every real screen does (via `ScreenContextReasserter` or a plain
/// `AppContext.instance.set` call) so navigating to it genuinely exercises
/// the launcher's route-independence, not a manually-poked context.
class _RouteScreen extends StatefulWidget {
  const _RouteScreen(this.screen);
  final String screen;

  @override
  State<_RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<_RouteScreen> {
  @override
  void initState() {
    super.initState();
    AppContext.instance.set(screen: widget.screen);
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('Route ${widget.screen}')));
}

/// A tiny two-route host mounted the same way `main.dart` really wires the
/// launcher: `MaterialApp.router`'s own `builder` wraps the router's `child`
/// and [GlobalAymaLauncher] as siblings in a `Stack` — not nested inside any
/// one screen — so it's reachable regardless of which route is showing.
GoRouter _testRouter() => GoRouter(
  initialLocation: '/a',
  routes: [
    GoRoute(path: '/a', builder: (_, __) => const _RouteScreen('explore')),
    GoRoute(path: '/b', builder: (_, __) => const _RouteScreen('match_report')),
  ],
);

Widget _host(GoRouter router, {bool signedIn = true, ApiClient? apiClient}) {
  return MaterialApp.router(
    theme: AymaTheme.light,
    routerConfig: router,
    builder: (context, child) => Stack(
      children: [
        child!,
        GlobalAymaLauncher(
          navigatorKey: router.routerDelegate.navigatorKey,
          signedIn: signedIn,
          apiClient: apiClient ?? _FakeApi(),
        ),
      ],
    ),
  );
}

Finder _button() => find.descendant(
  of: find.byType(GlobalAymaLauncher),
  matching: find.byType(InkWell),
);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(_button());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 50));
}

/// The sheet's drag-handle dock — no explicit close button any more (founder
/// feedback: redundant with dragging down past the minimum size, which
/// already dismisses it).
Finder _sheetHandle() => find.byKey(const ValueKey('aymaSheetHandle'));

/// Closes the sheet by dragging its handle down past the minimum size and
/// lets its dismiss animation fully settle — every test that opens one must
/// call this before finishing, or its still-running
/// `AnimationController`/route bleeds into the *next* test's fresh
/// `pumpWidget` (observed: an unrelated later test's layout blew up from a
/// previous test's never-closed sheet).
Future<void> _closeSheet(WidgetTester tester) async {
  await tester.drag(_sheetHandle(), const Offset(0, 700));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => AppContext.instance.clear());
  // AymaSession.instance is a real, process-lifetime singleton (by design —
  // it's what makes the tab and the floating sheet share one session) — so
  // a turn one test adds to it would otherwise leak into whichever test
  // runs next in this file and render there too (and, without a fake
  // ApiClient override, crash MainShellScreen's own bare-default test).
  tearDown(() => AymaSession.instance.store.seed(const []));

  testWidgets('renders and is tappable on a pushed route, opening a real '
      'ChatScreen', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = _testRouter();
    await tester.pumpWidget(_host(router));
    await tester.pump();
    expect(find.text('Route explore'), findsOneWidget);

    expect(_button(), findsOneWidget);
    await _openSheet(tester);

    expect(find.byType(ChatScreen), findsOneWidget);
    // The embedded ChatScreen's own initState sets `screen: 'ayma'` (so a
    // live voice call can answer "what am I on?") — closing must restore
    // the route's own context, not leave the mirror (and this button)
    // wrongly stuck there.
    await _closeSheet(tester);
    expect(AppContext.instance.current.value.screen, 'explore');
    expect(_button(), findsOneWidget);
    final ignore = tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byType(GlobalAymaLauncher),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(ignore.ignoring, isFalse);
  });

  testWidgets('renders and is tappable from a second, different pushed '
      'route too', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = _testRouter();
    await tester.pumpWidget(_host(router));
    await tester.pump();
    router.go('/b'); // a distinct real route — its own screen sets the context
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Route match_report'), findsOneWidget);

    expect(_button(), findsOneWidget);
    await _openSheet(tester);

    expect(find.byType(ChatScreen), findsOneWidget);
    await _closeSheet(tester);
  });

  testWidgets('hidden while on the Ayma screen itself', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_testRouter()));
    await tester.pump();
    AppContext.instance.set(screen: 'ayma');
    await tester.pump();

    final ignore = tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byType(GlobalAymaLauncher),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('hidden while on the splash/loading screen', (tester) async {
    // § founder report: the floating button showed over the splash screen's
    // loading orb — signed in already (so the signed-out gate doesn't catch
    // it) but `/bootstrap` still in flight.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_testRouter()));
    await tester.pump();
    AppContext.instance.set(screen: 'splash');
    await tester.pump();

    final ignore = tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byType(GlobalAymaLauncher),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(ignore.ignoring, isTrue);
  });

  testWidgets('hidden once its own sheet is open', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_testRouter()));
    await tester.pump();
    AppContext.instance.set(screen: 'explore');
    await tester.pump();

    await _openSheet(tester);

    final ignore = tester.widget<IgnorePointer>(
      find.descendant(
        of: find.byType(GlobalAymaLauncher),
        matching: find.byType(IgnorePointer),
      ),
    );
    expect(ignore.ignoring, isTrue);
    await _closeSheet(tester);
  });

  testWidgets('signed out: nothing rendered, no button at all', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_testRouter(), signedIn: false));
    await tester.pump();
    AppContext.instance.set(screen: 'explore');
    await tester.pump();

    expect(_button(), findsNothing);
  });

  testWidgets('profile page context reaches the sheet\'s ChatScreen as '
      'viewingProfileUid + pageContext', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_testRouter()));
    await tester.pump();
    AppContext.instance.set(
      screen: 'profile',
      subjectUid: 'u_riley',
      subjectName: 'Riley',
    );
    await tester.pump();

    await _openSheet(tester);

    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.viewingProfileUid, 'u_riley');
    expect(chat.pageContext?.screen, 'profile');
    expect(chat.pageContext?.subjectUid, 'u_riley');
    expect(chat.pageContext?.subjectName, 'Riley');
    await _closeSheet(tester);
  });

  testWidgets(
    'a non-profile screen reaches the sheet\'s ChatScreen as pageContext '
    'without setting viewingProfileUid',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_testRouter()));
      await tester.pump();
      AppContext.instance.set(screen: 'explore', note: 'tall guys in Austin');
      await tester.pump();

      await _openSheet(tester);

      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.viewingProfileUid, '');
      expect(chat.pageContext?.screen, 'explore');
      expect(chat.pageContext?.note, 'tall guys in Austin');
      await _closeSheet(tester);
    },
  );

  testWidgets(
    'the sheet\'s ChatScreen is wired to the single app-wide session — a '
    'turn added to the shared store live shows up in the open sheet',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_testRouter()));
      await tester.pump();
      AppContext.instance.set(screen: 'explore');
      await tester.pump();

      await _openSheet(tester);

      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.transcriptStore, same(AymaSession.instance.store));
      expect(chat.voiceController, same(AymaSession.instance.voice));

      // Added after the sheet's own (empty, faked) history load resolved —
      // proves the open sheet is reactively watching the *same* store
      // instance, not a snapshot or a second one of its own.
      AymaSession.instance.store.addTurn(
        TurnRole.ayma,
        'a shared-session marker only the real store would have',
        TurnSource.text,
      );
      await tester.pump();

      expect(
        find.text('a shared-session marker only the real store would have'),
        findsOneWidget,
      );
      await _closeSheet(tester);
    },
  );

  testWidgets('MainShellScreen\'s own Ayma-tab ChatScreen uses that exact same '
      'app-wide session, not a second instance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AymaTheme.light, home: const MainShellScreen()),
    );
    await tester.pump();

    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.transcriptStore, same(AymaSession.instance.store));
    expect(chat.voiceController, same(AymaSession.instance.voice));
  });

  testWidgets(
    'the sheet has no close ("X") button but keeps the drag-handle dock',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_testRouter()));
      await tester.pump();
      AppContext.instance.set(screen: 'explore');
      await tester.pump();

      await _openSheet(tester);

      // The page-context chip's own "remove" affordance reuses this glyph
      // (it's on screen here since the sheet opened with a non-empty
      // `AppContext`) — so the real assertion is that this is the *only*
      // match, i.e. still no redundant "close the whole sheet" button.
      final closeIcons = find.byIcon(Icons.close);
      expect(closeIcons, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: closeIcons,
                matching: find.byType(IconButton),
              ),
            )
            .tooltip,
        'Remove page context',
      );
      expect(_sheetHandle(), findsOneWidget);
      await _closeSheet(tester);
    },
  );

  testWidgets(
    'shows a dismissible chip naming the page the user was just on',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(_testRouter()));
      await tester.pump();
      AppContext.instance.set(screen: 'explore', note: 'tall guys in Austin');
      await tester.pump();

      await _openSheet(tester);

      expect(find.text('Explore — "tall guys in Austin"'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove page context'));
      await tester.pump();
      expect(find.text('Explore — "tall guys in Austin"'), findsNothing);

      await _closeSheet(tester);
    },
  );

  testWidgets(
    'the full-screen button closes the sheet and lands on the Ayma tab with '
    'the exact same conversation already showing',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          GoRoute(path: '/a', builder: (_, __) => const _RouteScreen('explore')),
          GoRoute(
            path: MainShellScreen.path,
            builder: (_, __) => const MainShellScreen(),
          ),
        ],
      );
      await tester.pumpWidget(_host(router));
      await tester.pump();
      AppContext.instance.set(screen: 'explore');
      await tester.pump();

      await _openSheet(tester);

      // Proves the sheet's embedded `ChatScreen` really is reading the
      // shared store live (same trick the "wired to the single app-wide
      // session" test above uses) — a stand-in for "a message exchanged in
      // the popup".
      AymaSession.instance.store.addTurn(
        TurnRole.user,
        'a message from the popup, before expanding',
        TurnSource.text,
      );
      await tester.pump();
      expect(
        find.text('a message from the popup, before expanding'),
        findsOneWidget,
      );

      // Clear it back out before expanding: `MainShellScreen`'s own tab
      // `ChatScreen` has no test-apiClient injection point (see
      // `main_shell_screen_test.dart` — no test there ever populates the
      // store for exactly this reason), so rendering a real transcript row
      // under it would reach a real `ApiClient()` / `FirebaseAuth.instance`,
      // unavailable in a plain widget test. What's already proven above (a
      // shared-store change shows up live in the sheet) plus the
      // object-identity check below together are the real "nothing gets
      // lost" guarantee — there's no copy step in between for anything to
      // drop out of.
      AymaSession.instance.store.seed(const []);
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Open full screen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      // The sheet is gone, replaced by the real Ayma tab, reading the exact
      // same `TranscriptStore` instance the sheet was just wired to — an
      // object-identity guarantee that a message exchanged in the popup
      // could never be dropped or duplicated on expand, because there's no
      // hand-off at all: both surfaces were always the same store.
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.byType(MainShellScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsOneWidget);
      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.transcriptStore, same(AymaSession.instance.store));
    },
  );

  testWidgets('dragging up over the embedded chat expands the sheet toward '
      'maxChildSize instead of just scrolling the message list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_testRouter()));
    await tester.pump();
    AppContext.instance.set(screen: 'explore');
    await tester.pump();

    await _openSheet(tester);

    // A long, populated transcript, like the founder's own mid-conversation
    // repro — a *short* one fits entirely within the viewport (nothing to
    // scroll), and Flutter's own `ScrollPhysics.shouldAcceptUserOffset`
    // refuses to attach a drag recognizer to a `Scrollable` with nothing to
    // scroll at all, which would make this drag a no-op for reasons
    // unrelated to what's under test here.
    for (var i = 0; i < 40; i++) {
      AymaSession.instance.store.addTurn(
        i.isEven ? TurnRole.user : TurnRole.ayma,
        'message number $i in a long conversation',
        TurnSource.text,
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final before = tester.getSize(find.byType(DraggableScrollableSheet)).height;

    // A single continuous drag starting directly over the chat's own message
    // list — not the drag handle. It first scrolls through the (deliberately
    // long) transcript exactly like an ordinary drag would; once it runs out
    // of list to scroll (reaching the newest message, same as where a live
    // conversation always rests), the *same* gesture should carry on into
    // expanding the sheet toward maxChildSize (§ Fix 3) rather than stopping
    // dead. Driven as discrete steps (rather than a single `tester.drag`) so
    // each one produces its own `ScrollUpdateNotification`, the same way a
    // real, continuous finger drag does.
    final gesture = await tester.startGesture(const Offset(540, 1668));
    for (var i = 0; i < 80; i++) {
      await gesture.moveBy(const Offset(0, -50));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    final after = tester.getSize(find.byType(DraggableScrollableSheet)).height;
    expect(after, greaterThan(before + 50));

    await _closeSheet(tester);
  });
}
