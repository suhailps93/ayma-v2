// The Ask-Ayma popup's expand-to-full-screen button (founder ask): while
// `ChatScreen` is hosted in the page-context popup
// (`showPageContextAymaPopup`), its header's top-right slot grows an
// `Icons.open_in_full_rounded` button — the same slot/treatment as the
// voice full-screen entry (`chatVoiceFullscreenButton`) — wired via
// `ChatScreen.onExpandRequested` back to each call site's own
// `_onTabTap(0)`. Tapping it therefore IS a second orb tap: the existing
// "popup already open" branch dismisses the popup and lands on the real
// Ayma tab with the pinned page-context chip dropped (founder rule from
// that feature: full screen drops the context; the popup keeps it). Never
// shown on the main tab's own chat (no host passes the callback there).
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
import 'package:ayma_flutter/widgets/nav_bar_shell.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _expandButton = Key('chatExpandFullscreenButton');
const _voiceButton = Key('chatVoiceFullscreenButton');
const _modalHandle = ValueKey('aymaChatModalHandle');

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

void main() {
  setUp(() {
    // Same singleton hygiene as `main_shell_screen_test.dart` /
    // `nav_bar_shell_test.dart`: a test that opens the popup and never
    // dismisses it can leave these leaking into a later test.
    TabRequest.instance.consume();
    isPageContextAymaPopupOpen = false;
    AppContext.instance.set(screen: '');
  });

  Widget shellHost() =>
      MaterialApp(theme: AymaTheme.light, home: const MainShellScreen());

  testWidgets(
    'the expand button shows only on the popup-hosted chat, never on the '
    "main tab's own chat",
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(shellHost());
      await tester.pump();

      // The shell opens on the Ayma tab — its own full-screen chat is
      // showing, and it must NOT carry the expand button (there is nothing
      // further to expand to).
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byKey(_expandButton), findsNothing);

      // Open the popup from another tab: its hosted ChatScreen (a second
      // one — the IndexedStack keeps the tab's own mounted underneath) is
      // the only one that grows the button, top right in the header band.
      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ExploreScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(find.byKey(_expandButton), findsOneWidget);

      final screen =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      final center = tester.getCenter(find.byKey(_expandButton));
      expect(center.dx, greaterThan(screen.width / 2));
    },
  );

  testWidgets(
    'tapping expand dismisses the popup and lands on the real Ayma tab '
    'with no pinned page-context chip carried over (same semantics as a '
    'second orb tap — founder rule: full screen drops the context)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(shellHost());
      await tester.pump();

      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));

      // Same distinctive marker `main_shell_screen_test.dart`'s round-3
      // test uses, standing in for "the page the user was actually on".
      AppContext.instance.set(
        screen: 'profile',
        subjectName: 'Zzqq Test Subject',
      );

      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The popup itself keeps the pinned context chip…
      expect(find.text("Zzqq Test Subject's profile"), findsOneWidget);

      await tester.tap(find.byKey(_expandButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // …and expanding lands on the real Ayma tab without it.
      expect(find.byKey(_modalHandle), findsNothing);
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
        0,
      );
      expect(find.text("Zzqq Test Subject's profile"), findsNothing);
    },
  );

  testWidgets(
    'expand from a NavBarShell-wrapped screen dismisses the popup and '
    "routes back into the shell (that call site's awaited pop before "
    'context.go stays intact)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

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
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(find.byKey(_expandButton), findsOneWidget);

      await tester.tap(find.byKey(_expandButton));
      // The popped modal's dismiss transition, then (once
      // `pendingPageContextAymaPopup` resolves) `context.go`'s own
      // transition into the shell — `pumpAndSettle` lets both chain.
      await tester.pumpAndSettle();

      expect(find.byKey(_modalHandle), findsNothing);
      expect(find.text('screen:shell'), findsOneWidget);
      expect(find.text('screen:other'), findsNothing);
    },
  );

  testWidgets(
    'the expand button coexists with the voice full-screen button during a '
    'live call — both in the header slot, side by side without overlap',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = await _historyOnlyApi();
      final voice = _FakeVoice();

      // The popup's hosting contract, distilled: a ChatScreen handed
      // `onExpandRequested` (what `showPageContextAymaPopup` passes
      // through), with a controllable voice session.
      var expandTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AymaTheme.light,
          home: ChatScreen(
            apiClient: api,
            voiceController: voice,
            onExpandRequested: () => expandTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No call yet: expand shows alone.
      expect(find.byKey(_expandButton), findsOneWidget);
      expect(find.byKey(_voiceButton), findsNothing);

      voice.setPhase(VoiceSessionPhase.live);
      await tester.pump();

      expect(find.byKey(_expandButton), findsOneWidget);
      expect(find.byKey(_voiceButton), findsOneWidget);
      final voiceRect = tester.getRect(find.byKey(_voiceButton));
      final expandRect = tester.getRect(find.byKey(_expandButton));
      expect(voiceRect.overlaps(expandRect), isFalse);
      // Voice first, expand outermost (the popup's own top-right corner).
      expect(voiceRect.right, lessThanOrEqualTo(expandRect.left));

      // And the expand button stays live (tappable) alongside the call.
      await tester.tap(find.byKey(_expandButton));
      expect(expandTaps, 1);
    },
  );
}
