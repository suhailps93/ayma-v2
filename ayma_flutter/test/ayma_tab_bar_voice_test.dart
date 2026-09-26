// AymaTabBar's voice wiring (founder follow-up: "the same animation should
// happen in the nav bar logo too" — the nav-bar tab's orb was rendering flat
// and static during a live call because the bar only ever received a plain
// `active: bool`, never the real `VoiceSessionController` phase/speaking/
// amplitude signals). This covers the fix: [AymaTabBar] now takes the
// controller itself and maps it to [AymaOrbState]/`amplitudeListenable`/
// `voiceLive` exactly the way `VoiceCallScreen`/`SignInScreen` already do.
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same test-only subclass `voice_call_screen_test.dart`'s `_FakeVoice` uses
/// to drive a [VoiceSessionController] through `connecting`/`waking`/`live`/
/// speaking without a real `/bootstrap`/LiveKit round trip.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _fakePhase = VoiceSessionPhase.idle;
  bool _fakeSpeaking = false;

  @override
  VoiceSessionPhase get phase => _fakePhase;

  @override
  bool get agentSpeaking => _fakeSpeaking;

  @override
  bool get isActive =>
      _fakePhase == VoiceSessionPhase.connecting ||
      _fakePhase == VoiceSessionPhase.waking ||
      _fakePhase == VoiceSessionPhase.live;

  void setPhase(VoiceSessionPhase phase) {
    _fakePhase = phase;
    notifyListeners();
  }

  void setSpeaking(bool speaking) {
    _fakeSpeaking = speaking;
    notifyListeners();
  }
}

AymaOrb _orb(WidgetTester tester) =>
    tester.widget<AymaOrb>(find.byType(AymaOrb));

Widget _host(VoiceSessionController? voice) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        bottomNavigationBar: voice == null
            ? AymaTabBar(index: -1, voice: null, onSelected: (_) {})
            : ListenableBuilder(
                listenable: voice,
                builder: (context, _) => AymaTabBar(
                  index: -1,
                  voice: voice,
                  onSelected: (_) {},
                ),
              ),
      ),
    );

void main() {
  testWidgets('no controller renders an idle, non-live, non-reactive orb', (
    tester,
  ) async {
    await tester.pumpWidget(_host(null));
    await tester.pump();
    final orb = _orb(tester);
    expect(orb.state, AymaOrbState.idle);
    expect(orb.voiceLive, isFalse);
    expect(orb.amplitudeListenable, isNull);
  });

  testWidgets('connecting/waking maps to thinking, with voiceLive already on', (
    tester,
  ) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.connecting);
    await tester.pumpWidget(_host(voice));
    await tester.pump();
    expect(_orb(tester).state, AymaOrbState.thinking);
    expect(_orb(tester).voiceLive, isTrue);

    voice.setPhase(VoiceSessionPhase.waking);
    await tester.pump();
    expect(_orb(tester).state, AymaOrbState.thinking);
    expect(_orb(tester).voiceLive, isTrue);
  });

  testWidgets(
    'live + not speaking maps to listening, reacting to the mic level',
    (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(_host(voice));
      await tester.pump();
      final orb = _orb(tester);
      expect(orb.state, AymaOrbState.listening);
      expect(orb.voiceLive, isTrue);
      expect(orb.amplitudeListenable, same(voice.micLevel));
    },
  );

  testWidgets(
    'live + speaking maps to speaking, reacting to Ayma\'s own audio level',
    (tester) async {
      final voice = _FakeVoice()
        ..setPhase(VoiceSessionPhase.live)
        ..setSpeaking(true);
      await tester.pumpWidget(_host(voice));
      await tester.pump();
      final orb = _orb(tester);
      expect(orb.state, AymaOrbState.speaking);
      expect(orb.amplitudeListenable, same(voice.aymaLevel));
    },
  );

  testWidgets(
    'a live mic-level change actually reaches the painted nav-bar orb '
    '(not a static single frame)',
    (tester) async {
      final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
      await tester.pumpWidget(_host(voice));
      await tester.pump();

      AymaOrbPainter painter() => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(AymaOrb),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((w) => w.painter)
          .whereType<AymaOrbPainter>()
          .first;

      voice.micLevel.value = 0.02;
      // Let the orb's own internal smoothing (0.82/0.18 per frame — see
      // `AymaOrb._AymaOrbState.build`) settle toward the new level.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final ampLow = painter().amplitude;

      voice.micLevel.value = 0.95;
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final ampHigh = painter().amplitude;

      expect(ampHigh, greaterThan(ampLow + 0.3));
    },
  );
}
