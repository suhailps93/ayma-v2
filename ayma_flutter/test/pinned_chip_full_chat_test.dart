import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:ayma_flutter/widgets/nav_bar_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());
  @override
  VoiceSessionPhase get phase => VoiceSessionPhase.idle;
  @override
  bool get isActive => false;
  @override
  bool get isListening => false;
  @override
  Future<void> start({bool forceRelayFirst = false}) async {}
  @override
  Future<void> stop() async {}
}

class _MatchReportMock extends StatefulWidget {
  const _MatchReportMock();
  @override
  State<_MatchReportMock> createState() => _MatchReportMockState();
}

class _MatchReportMockState extends State<_MatchReportMock> {
  @override
  void initState() {
    super.initState();
    AppContext.instance.set(
      screen: 'match_report',
      subjectUid: 'test2',
      subjectName: 'Sofia Marino',
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Match Report: Sofia Marino')),
    );
  }
}

void main() {
  setUp(() {
    TabRequest.instance.consume();
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
    AppContext.instance.set(screen: '');
  });

  testWidgets(
    'Scout repro: open match report from Explore -> open docked sheet (chip shows) -> tap Open full chat -> chip is gone in full chat',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final voice = _FakeVoice();

      late final GoRouter router;
      router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => MainShellScreen(
              voiceController: voice,
            ),
          ),
          GoRoute(
            path: '/match/test2',
            builder: (_, __) => const NavBarShell(child: _MatchReportMock()),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp.router(
          theme: AymaTheme.light,
          routerConfig: router,
        ),
      );
      await tester.pumpAndSettle();

      // Go to Explore tab so MainShellScreen is at _index = 1
      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(ExploreScreen), findsOneWidget);

      // User opens match report for Sofia Marino via push
      router.push('/match/test2');
      await tester.pumpAndSettle();
      expect(find.text('Match Report: Sofia Marino'), findsOneWidget);

      // Tap orb on NavBarShell to open docked page-context sheet
      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      // Half screen (docked sheet): chip shows with pin icon
      expect(find.text('Match report — Sofia Marino'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
      expect(find.byKey(const Key('chatExpandFullscreenButton')), findsOneWidget);

      // Tap 'Open full chat' in the sheet header
      await tester.tap(find.byKey(const Key('chatExpandFullscreenButton')));
      await tester.pumpAndSettle();

      // Docked sheet is dismissed and we are on full-screen main chat
      expect(isAymaSheetOpen, isFalse);
      expect(find.text('Match Report: Sofia Marino'), findsNothing);

      // Settled spec (founder, Nov 8):
      // Full screen: context dropped AND the chip is gone.
      // The full chat starts clean, with no pinned page attached.
      expect(find.text('Match report — Sofia Marino'), findsNothing);
      expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    },
  );
}
