import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/voice_return_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [VoiceSessionController] whose phase/speaking state a test can drive
/// directly, without a real bootstrap/LiveKit round trip — [MainShellScreen]'s
/// `voiceController` injection point exists for exactly this.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;

  @override
  VoiceSessionPhase get phase => _phase;

  @override
  bool get isActive =>
      _phase == VoiceSessionPhase.connecting ||
      _phase == VoiceSessionPhase.waking ||
      _phase == VoiceSessionPhase.live;

  void setPhase(VoiceSessionPhase p) {
    _phase = p;
    notifyListeners();
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  Widget host() =>
      MaterialApp(theme: AymaTheme.light, home: const MainShellScreen());

  Widget hostWithVoice(VoiceSessionController voice) => MaterialApp(
        theme: AymaTheme.light,
        home: MainShellScreen(voiceController: voice),
      );

  testWidgets(
    'renders the 4-tab bottom nav (icon-only, no text labels) with the '
    'orb on the Ayma tab',
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

  group('voice return pill', () {
    Future<void> pump(WidgetTester tester, VoiceSessionController voice) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(hostWithVoice(voice));
      await tester.pump();
    }

    testWidgets('absent with no active call, even off the Ayma tab',
        (tester) async {
      final voice = _FakeVoice();
      await pump(tester, voice);

      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(voice.isActive, isFalse);
      expect(
        tester.widget<VoiceReturnPill>(find.byType(VoiceReturnPill)).visible,
        isFalse,
      );
    });

    testWidgets('appears once a call is active and a non-Ayma tab is shown',
        (tester) async {
      final voice = _FakeVoice();
      await pump(tester, voice);

      voice.setPhase(VoiceSessionPhase.live);
      await tester.pump();
      // Still on the Ayma tab — the chat screen already shows the call.
      expect(
        tester.widget<VoiceReturnPill>(find.byType(VoiceReturnPill)).visible,
        isFalse,
      );

      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        tester.widget<VoiceReturnPill>(find.byType(VoiceReturnPill)).visible,
        isTrue,
      );
      expect(find.text('Ayma is listening…'), findsOneWidget);
    });

    testWidgets('tapping the pill switches back to the Ayma tab',
        (tester) async {
      final voice = _FakeVoice();
      await pump(tester, voice);
      voice.setPhase(VoiceSessionPhase.live);
      await tester.pump();

      await tester.tap(find.byTooltip('Explore'));
      // First pump commits the rebuild that starts the pill's implicit
      // fade/slide-in (that's when `didUpdateWidget` sees the new target);
      // only a *second* pump with a real duration actually advances it. Can't
      // use pumpAndSettle: the orb's own idle animation loops forever.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ExploreScreen), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(VoiceReturnPill),
        matching: find.byType(InkWell),
      ));
      await tester.pump(const Duration(milliseconds: 250));

      // Explore stays alive under an IndexedStack, but the Ayma tab pill is
      // hidden again, confirming the shell switched back to it.
      expect(
        tester.widget<VoiceReturnPill>(find.byType(VoiceReturnPill)).visible,
        isFalse,
      );
    });

    testWidgets('label reflects connecting vs. speaking', (tester) async {
      final voice = _FakeVoice();
      await pump(tester, voice);

      voice.setPhase(VoiceSessionPhase.connecting);
      await tester.tap(find.byTooltip('Explore'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Connecting…'), findsOneWidget);
    });
  });
}
