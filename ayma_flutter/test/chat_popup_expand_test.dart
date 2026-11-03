// The page-context popup's expand/collapse (founder ask: expanding must look
// like the sheet itself growing to fill the screen, not a new page). Full
// screen is the SAME `showAymaChatModal` sheet at its largest snap size:
// the header's `open_in_full` button (or a second orb tap) animates it up
// to the whole screen above the nav bar, `close_fullscreen` (or system back)
// shrinks it back. Nothing is re-mounted, so the hosted `ChatScreen` State,
// its transcript and its composer text carry straight across. The pinned
// page-context chip is set aside while expanded (founder rule: full screen
// drops the context; the popup keeps it) and comes back on collapse.
import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/ayma_chat_modal.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/nav_bar_shell.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _expandButton = Key('chatExpandFullscreenButton');
const _collapseButton = Key('chatCollapseFullscreenButton');
const _voiceButton = Key('chatVoiceFullscreenButton');
const _modalHandle = ValueKey('aymaChatModalHandle');
const _sheetBox = ValueKey('aymaChatModalSheetBox');
const _chip = "Zzqq Test Subject's profile";

const _screenHeight = 2400.0;
const _barHeight = AymaTabBar.contentHeight;
const _dockedTop = (_screenHeight - _barHeight) * (1 - 0.62);

/// Same test-driven controller as `voice_call_screen_test.dart`'s
/// `_FakeVoice` — its lifecycle is driven by `setPhase` instead of a real
/// `/bootstrap`/LiveKit round trip, just enough to make the header's voice
/// full-screen button show alongside the expand button.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _fakePhase = VoiceSessionPhase.idle;

  @override
  VoiceSessionPhase get phase => _fakePhase;

  @override
  bool get isActive =>
      _fakePhase == VoiceSessionPhase.connecting ||
      _fakePhase == VoiceSessionPhase.waking ||
      _fakePhase == VoiceSessionPhase.live;

  @override
  bool get isListening => _fakePhase == VoiceSessionPhase.live;

  void setPhase(VoiceSessionPhase phase) {
    _fakePhase = phase;
    notifyListeners();
  }
}

Future<ApiClient> _historyOnlyApi() async {
  final mockHttp = MockClient((request) async {
    const headers = {'content-type': 'application/json; charset=utf-8'};
    if (request.url.path == '/chat/history') {
      return http.Response(
        jsonEncode({'messages': <dynamic>[], 'next_before': null}),
        200,
        headers: headers,
      );
    }
    return http.Response('{}', 200, headers: headers);
  });
  return ApiClient(
    httpClient: mockHttp,
    auth: MockFirebaseAuth(signedIn: true),
  );
}

Rect _sheetRect(WidgetTester tester) => tester.getRect(find.byKey(_sheetBox));

Finder _inSheet(Finder matching) =>
    find.descendant(of: find.byKey(_sheetBox), matching: matching);

void _phoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, _screenHeight);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Opens the popup over the shell's Explore tab, scoped to a distinctive
/// "page the user was on" so the pinned chip is visible.
Future<void> _openPopupOverExplore(WidgetTester tester, {Widget? host}) async {
  await tester.pumpWidget(
    host ?? MaterialApp(theme: AymaTheme.light, home: const MainShellScreen()),
  );
  await tester.pump();
  await tester.tap(find.byTooltip('Explore'));
  await tester.pump(const Duration(milliseconds: 50));
  expect(find.byType(ExploreScreen), findsOneWidget);
  AppContext.instance.set(screen: 'profile', subjectName: 'Zzqq Test Subject');
  await tester.tap(find.byTooltip('Ayma'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(_modalHandle), findsOneWidget);
}

void main() {
  setUp(() {
    // Same singleton hygiene as `main_shell_screen_test.dart` /
    // `nav_bar_shell_test.dart`: a test that opens the popup and never
    // dismisses it can leave these leaking into a later test.
    TabRequest.instance.consume();
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
    AppContext.instance.set(screen: '');
  });

  testWidgets(
    'the expand button shows only on the popup-hosted chat, never on the '
    "main tab's own chat",
    (tester) async {
      _phoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(theme: AymaTheme.light, home: const MainShellScreen()),
      );
      await tester.pump();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(_expandButton), findsNothing);

      await _openPopupOverExplore(tester);
      expect(find.byKey(_expandButton), findsOneWidget);
      final center = tester.getCenter(find.byKey(_expandButton));
      expect(center.dx, greaterThan(1080 / 2));
    },
  );

  testWidgets(
    'partial -> full -> partial is one continuous surface: same ChatScreen '
    'State, transcript and composer text throughout; history listed only '
    'while full, chip dropped only while full',
    (tester) async {
      _phoneViewport(tester);
      final api = await _historyOnlyApi();
      // A voice turn: kept by `TranscriptStore.seed` across the (empty)
      // history load, standing in for a conversation already on screen.
      final store = TranscriptStore()
        ..applyVoiceSegment(TurnRole.ayma, 'Zzqq hello from the call',
            isFinal: true);
      final voice = _FakeVoice();
      final sheet = AymaChatSheetController();
      addTearDown(sheet.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAymaChatModal(
                  context,
                  controller: sheet,
                  builder: (_) => ChatScreen(
                    apiClient: api,
                    transcriptStore: store,
                    voiceController: voice,
                    pageContext: const ScreenContext(
                      screen: 'profile',
                      subjectName: 'Zzqq Test Subject',
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      const dockedTop = _screenHeight * (1 - 0.62);
      expect(_sheetRect(tester).top, closeTo(dockedTop, 1));
      expect(_sheetRect(tester).bottom, closeTo(_screenHeight, 1));
      expect(find.text(_chip), findsOneWidget);
      final chatState = tester.state(_inSheet(find.byType(ChatScreen)));
      final message = _inSheet(
        find.textContaining('Zzqq hello from the call', findRichText: true),
      );
      // Docked: the turn is in the store (same state throughout) but not
      // listed — founder rule, Nov 2026.
      expect(message, findsNothing);
      await tester.enterText(_inSheet(find.byType(TextField)), 'draft msg');
      String composerText() => tester
          .widget<TextField>(_inSheet(find.byType(TextField)))
          .controller!
          .text;

      await tester.tap(find.byKey(_expandButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // Mid-flight: the same box is partway between the two rects — it
      // grows, it is not replaced.
      final mid = _sheetRect(tester).top;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(dockedTop - 1));
      await tester.pumpAndSettle();

      // Full end state: the whole screen, still the same modal surface.
      expect(_sheetRect(tester).top, 0);
      expect(_sheetRect(tester).bottom, closeTo(_screenHeight, 1));
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(sheet.isExpanded, isTrue);
      expect(tester.state(_inSheet(find.byType(ChatScreen))), same(chatState));
      // Full: the whole conversation lists, same state, nothing re-mounted.
      expect(message, findsOneWidget);
      expect(composerText(), 'draft msg');
      expect(find.text(_chip), findsNothing);
      expect(find.byKey(_expandButton), findsNothing);
      expect(find.byKey(_collapseButton), findsOneWidget);

      await tester.tap(find.byKey(_collapseButton));
      await tester.pumpAndSettle();

      expect(_sheetRect(tester).top, closeTo(dockedTop, 1));
      expect(sheet.isExpanded, isFalse);
      expect(tester.state(_inSheet(find.byType(ChatScreen))), same(chatState));
      // Collapsed again: history stands down once more.
      expect(message, findsNothing);
      expect(composerText(), 'draft msg');
      expect(find.text(_chip), findsOneWidget);
      expect(find.byKey(_expandButton), findsOneWidget);
    },
  );

  testWidgets(
    'a second orb tap expands the popup over the current tab (no tab '
    'switch, no second popup)',
    (tester) async {
      _phoneViewport(tester);
      await _openPopupOverExplore(tester);
      expect(_sheetRect(tester).top, closeTo(_dockedTop, 1));
      expect(
        _sheetRect(tester).bottom,
        closeTo(_screenHeight - _barHeight, 1),
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('aymaChatModalNavBar')),
          matching: find.byTooltip('Ayma'),
        ),
      );
      await tester.pumpAndSettle();

      expect(_sheetRect(tester).top, 0);
      expect(
        _sheetRect(tester).bottom,
        closeTo(_screenHeight - _barHeight, 1),
      );
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(find.text(_chip), findsNothing);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
    },
  );

  testWidgets(
    'system back while full collapses to the docked sheet; back again '
    'closes it',
    (tester) async {
      _phoneViewport(tester);
      await _openPopupOverExplore(tester);

      await tester.tap(find.byKey(_expandButton));
      await tester.pumpAndSettle();
      expect(_sheetRect(tester).top, 0);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(_sheetRect(tester).top, closeTo(_dockedTop, 1));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(_modalHandle), findsNothing);
      expect(isAymaSheetOpen, isFalse);
      expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
    },
  );

  testWidgets(
    'dragging the handle up from docked snaps to full screen, and down from '
    'full snaps back',
    (tester) async {
      _phoneViewport(tester);
      await _openPopupOverExplore(tester);

      await tester.drag(find.byKey(_modalHandle), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(_sheetRect(tester).top, 0);
      expect(aymaSheet.isExpanded, isTrue);

      await tester.drag(find.byKey(_modalHandle), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(_sheetRect(tester).top, closeTo(_dockedTop, 1));
      expect(aymaSheet.isExpanded, isFalse);
    },
  );

  testWidgets('with reduced motion the expand is instant and fades in', (
    tester,
  ) async {
    _phoneViewport(tester);
    await _openPopupOverExplore(
      tester,
      host: MaterialApp(
        theme: AymaTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const MainShellScreen(),
      ),
    );

    await tester.tap(find.byKey(_expandButton));
    await tester.pump();
    expect(_sheetRect(tester).top, 0);
    final fade = tester.widget<FadeTransition>(
      find
          .descendant(
            of: find.byKey(_sheetBox),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(fade.opacity.value, 1);
  });

  testWidgets(
    'from a NavBarShell-wrapped screen, expand grows in place (no route '
    'change) and back collapses it',
    (tester) async {
      _phoneViewport(tester);
      // Same tiny local router as `nav_bar_shell_test.dart`: a plain marker
      // at '/' stands in for the real MainShellScreen (needs Firebase).
      final router = GoRouter(
        initialLocation: '/other',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('screen:shell'))),
          ),
          GoRoute(
            path: '/other',
            builder: (_, __) => const NavBarShell(
              child: Scaffold(body: Center(child: Text('screen:other'))),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(theme: AymaTheme.light, routerConfig: router),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(_expandButton));
      await tester.pumpAndSettle();

      expect(_sheetRect(tester).top, 0);
      expect(find.text('screen:shell'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(_sheetRect(tester).top, closeTo(_dockedTop, 1));
      expect(find.text('screen:other'), findsOneWidget);
    },
  );

  testWidgets(
    'the expand button coexists with the voice full-screen button during a '
    'live call — both in the header slot, side by side without overlap',
    (tester) async {
      _phoneViewport(tester);
      final api = await _historyOnlyApi();
      final voice = _FakeVoice();
      final sheet = AymaChatSheetController();
      addTearDown(sheet.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showAymaChatModal(
                  context,
                  controller: sheet,
                  builder: (_) =>
                      ChatScreen(apiClient: api, voiceController: voice),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(_expandButton), findsOneWidget);
      expect(find.byKey(_voiceButton), findsNothing);

      voice.setPhase(VoiceSessionPhase.live);
      await tester.pump();

      expect(find.byKey(_expandButton), findsOneWidget);
      expect(find.byKey(_voiceButton), findsOneWidget);
      final voiceRect = tester.getRect(find.byKey(_voiceButton));
      final expandRect = tester.getRect(find.byKey(_expandButton));
      expect(voiceRect.overlaps(expandRect), isFalse);
      // Voice first, expand outermost (the sheet's own top-right corner).
      expect(voiceRect.right, lessThanOrEqualTo(expandRect.left));

      // And it stays live alongside the call (the live call carries over).
      await tester.tap(find.byKey(_expandButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sheet.isExpanded, isTrue);
      expect(find.byKey(_voiceButton), findsOneWidget);
    },
  );
}
