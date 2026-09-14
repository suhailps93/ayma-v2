import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/voice_return_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A controller whose phase/speaking/muted state a test can drive directly —
/// [VoiceReturnPill] is purely presentational over whatever [voice] reports,
/// so exercising every phase deterministically doesn't need a real
/// bootstrap/LiveKit round trip.
class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  bool _speaking = false;
  final bool _mutedFlag = false;

  @override
  VoiceSessionPhase get phase => _phase;
  @override
  bool get agentSpeaking => _speaking;
  @override
  bool get muted => _mutedFlag;

  void setPhase(VoiceSessionPhase p) {
    _phase = p;
    notifyListeners();
  }

  void setSpeaking(bool v) {
    _speaking = v;
    notifyListeners();
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

Widget _host(
  VoiceSessionController voice, {
  required bool visible,
  VoidCallback? onTap,
}) {
  return MaterialApp(
    theme: AymaTheme.light,
    home: Scaffold(
      body: ListenableBuilder(
        listenable: voice,
        builder: (context, _) => VoiceReturnPill(
          voice: voice,
          visible: visible,
          onTap: onTap ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('idle/invisible pill is faded out and not tappable',
      (tester) async {
    final voice = _FakeVoice();
    var tapped = 0;
    await tester.pumpWidget(_host(voice, visible: false, onTap: () => tapped++));
    await tester.pump();

    expect(find.byType(AymaOrb), findsOneWidget); // built, just faded out
    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 0);

    // Ignored — tapping where the pill would be does nothing.
    await tester.tap(find.byType(VoiceReturnPill), warnIfMissed: false);
    expect(tapped, 0);
  });

  testWidgets('visible pill fades/slides in and is tappable', (tester) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
    var tapped = 0;
    await tester.pumpWidget(_host(voice, visible: true, onTap: () => tapped++));
    await tester.pump();

    final opacity =
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1);

    await tester.tap(find.byType(VoiceReturnPill));
    expect(tapped, 1);
  });

  testWidgets('shows "Connecting…" + a thinking orb while connecting',
      (tester) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.connecting);
    await tester.pumpWidget(_host(voice, visible: true));
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('shows "Connecting…" while waking too', (tester) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.waking);
    await tester.pumpWidget(_host(voice, visible: true));
    await tester.pump();

    expect(find.text('Connecting…'), findsOneWidget);
  });

  testWidgets('shows "Ayma is listening…" once live and not speaking',
      (tester) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
    await tester.pumpWidget(_host(voice, visible: true));
    await tester.pump();

    expect(find.text('Ayma is listening…'), findsOneWidget);
  });

  testWidgets('shows "Ayma is speaking…" while the agent is talking',
      (tester) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
    await tester.pumpWidget(_host(voice, visible: true));
    await tester.pump();
    expect(find.text('Ayma is listening…'), findsOneWidget);

    voice.setSpeaking(true);
    await tester.pump();

    expect(find.text('Ayma is speaking…'), findsOneWidget);
    expect(find.text('Ayma is listening…'), findsNothing);
  });

  testWidgets('tapping the pill fires onTap', (tester) async {
    final voice = _FakeVoice()..setPhase(VoiceSessionPhase.live);
    var tapped = 0;
    await tester.pumpWidget(_host(voice, visible: true, onTap: () => tapped++));
    await tester.pump();

    await tester.tap(find.byType(VoiceReturnPill));
    expect(tapped, 1);
  });
}
