// The center Ayma orb's TAP progression (founder ask): on another page a tap
// opens the half "Ask Ayma" sheet with that page's context; a second tap grows
// that sheet to the full-screen main chat and drops the context chip; a tap on
// the full-screen main chat activates voice. The 1-second HOLD is unchanged —
// it activates voice directly from every page. Each rung is exercised on the
// real `MainShellScreen` with a fake voice controller asserting `start()`.
import 'package:ayma_flutter/screens/explore_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/services/app_context.dart';
import 'package:ayma_flutter/services/tab_request.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ask_ayma_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _modalHandle = ValueKey('aymaChatModalHandle');
const _sheetBox = ValueKey('aymaChatModalSheetBox');
const _popupBar = ValueKey('aymaChatModalNavBar');
const _chip = "Zzqq Test Subject's profile";

/// Records whether voice was started/stopped without any real LiveKit round
/// trip — stays idle so `toggleVoiceCall` takes its plain `start()` path.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  int startCalls = 0;
  int stopCalls = 0;

  @override
  VoiceSessionPhase get phase => VoiceSessionPhase.idle;
  @override
  bool get isActive => false;
  @override
  bool get isListening => false;
  @override
  Future<void> start() async => startCalls++;
  @override
  Future<void> stop() async => stopCalls++;
}

void main() {
  setUp(() {
    // Same singleton hygiene as `main_shell_screen_test.dart` — a stray
    // pending request or a left-open popup flag must not leak between tests.
    TabRequest.instance.consume();
    isAymaSheetOpen = false;
    isAymaSheetScoped = false;
    AppContext.instance.set(screen: '');
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(VoiceSessionController voice) => MaterialApp(
    theme: AymaTheme.light,
    home: MainShellScreen(voiceController: voice),
  );

  /// Leaves the Ayma tab for Explore and pins a distinctive "page the user was
  /// on" so the half sheet's context chip is identifiable.
  Future<void> goToExplore(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Explore'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(ExploreScreen), findsOneWidget);
    AppContext.instance.set(screen: 'profile', subjectName: 'Zzqq Test Subject');
  }

  Future<void> tapShellOrb(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Ayma'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapPopupOrb(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: find.byKey(_popupBar), matching: find.byTooltip('Ayma')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    '(i) from another page, an orb tap opens the half sheet with that '
    "page's context (voice not started)",
    (tester) async {
      phone(tester);
      final voice = _FakeVoice();
      await tester.pumpWidget(host(voice));
      await tester.pump();

      await goToExplore(tester);
      await tapShellOrb(tester);

      // Docked half sheet over the still-showing Explore tab, carrying the
      // page-context chip.
      expect(find.byKey(_modalHandle), findsOneWidget);
      expect(aymaSheet.isExpanded, isFalse);
      expect(find.text(_chip), findsOneWidget);
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
        1,
      );
      expect(voice.startCalls, 0);
    },
  );

  testWidgets(
    '(ii) a second orb tap grows the half sheet to the full-screen main chat '
    'and drops the context chip (voice not started)',
    (tester) async {
      phone(tester);
      final voice = _FakeVoice();
      await tester.pumpWidget(host(voice));
      await tester.pump();

      await goToExplore(tester);
      await tapShellOrb(tester);
      expect(find.text(_chip), findsOneWidget);

      await tapPopupOrb(tester);

      expect(aymaSheet.isExpanded, isTrue);
      expect(tester.getRect(find.byKey(_sheetBox)).top, 0);
      expect(find.text(_chip), findsNothing);
      // Still the same popup over Explore, not a tab switch or a new surface.
      expect(
        tester.widget<IndexedStack>(find.byType(IndexedStack)).index,
        1,
      );
      expect(voice.startCalls, 0);
    },
  );

  testWidgets(
    '(iii) once the chat is full screen, the next orb tap activates voice',
    (tester) async {
      phone(tester);
      final voice = _FakeVoice();
      await tester.pumpWidget(host(voice));
      await tester.pump();

      await goToExplore(tester);
      await tapShellOrb(tester); // half
      await tapPopupOrb(tester); // full
      expect(aymaSheet.isExpanded, isTrue);
      expect(voice.startCalls, 0);

      await tapPopupOrb(tester); // voice

      expect(voice.startCalls, 1);
      // Still on the full chat — voice does not close or shrink it.
      expect(aymaSheet.isExpanded, isTrue);
      expect(find.byKey(_modalHandle), findsOneWidget);
    },
  );

  testWidgets(
    '(iii-shortcut) on the Ayma tab (already the full-screen main chat) an '
    'orb tap activates voice directly, opening no sheet',
    (tester) async {
      phone(tester);
      final voice = _FakeVoice();
      await tester.pumpWidget(host(voice));
      await tester.pump();

      // The shell opens on the Ayma tab = the full-screen main chat.
      await tester.tap(find.byTooltip('Ayma'));
      await tester.pump();

      expect(voice.startCalls, 1);
      expect(find.byKey(_modalHandle), findsNothing);
    },
  );

  testWidgets(
    '(v) REGRESSION (founder 2026-11-02): rapid multi-tap on the orb activates '
    'voice exactly ONCE — a burst never opens multiple sessions',
    (tester) async {
      phone(tester);
      final voice = _FakeVoice();
      await tester.pumpWidget(host(voice));
      await tester.pump();

      // The shell opens on the Ayma tab = the full-screen main chat, so every
      // orb tap here takes the voice-start rung. Fire THREE taps inside the
      // ~500ms debounce window — the founder's exact "tapped it rapidly several
      // times" path.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byTooltip('Ayma'));
        await tester.pump(const Duration(milliseconds: 60));
      }

      // Exactly one voice start, not three — the debounce swallows the burst
      // (and the controller's own single-flight latch is the hard backstop).
      expect(voice.startCalls, 1);
    },
  );

  testWidgets(
    '(iv) a 1s HOLD on the orb from another page activates voice, unchanged — '
    'no chat sheet opens',
    (tester) async {
      phone(tester);
      final voice = _FakeVoice();
      await tester.pumpWidget(host(voice));
      await tester.pump();

      await goToExplore(tester);

      final g = await tester.startGesture(
        tester.getCenter(find.byTooltip('Ayma')),
      );
      await tester.pump(); // start the hold ticker
      await tester.pump(const Duration(milliseconds: 1100)); // past the 1s hold
      await g.up();
      await tester.pump();

      expect(voice.startCalls, 1);
      // A completed hold swallows the tap, so the progression never runs.
      expect(find.byKey(_modalHandle), findsNothing);
      expect(isAymaSheetOpen, isFalse);
    },
  );
}
