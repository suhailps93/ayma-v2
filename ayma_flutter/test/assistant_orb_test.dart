import 'package:ayma_flutter/assistant_orb_main.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A controllable stand-in for the voice-backed orb model, so the floating-orb
/// surface is tested without a live LiveKit session.
class _FakeOrbModel extends AssistantOrbModel {
  _FakeOrbModel({
    this.orbStateValue = AymaOrbState.idle,
    this.error,
  });

  AymaOrbState orbStateValue;
  String labelValue = 'Tap to talk to Ayma';
  String? error;
  bool _expanded = false;
  bool mutedValue = false;

  int dismissed = 0;
  int muteToggles = 0;

  @override
  AymaOrbState get orbState => orbStateValue;

  @override
  ValueListenable<double> get amplitude => ValueNotifier<double>(0);

  @override
  bool get voiceLive => orbStateValue == AymaOrbState.listening;

  @override
  String get statusLabel => error ?? labelValue;

  @override
  String? get errorText => error;

  @override
  bool get expanded => _expanded;

  @override
  bool get muted => mutedValue;

  @override
  void toggleExpanded() {
    _expanded = !_expanded;
    notifyListeners();
  }

  @override
  void toggleMute() {
    muteToggles++;
    mutedValue = !mutedValue;
    notifyListeners();
  }

  @override
  void dismiss() => dismissed++;
}

void main() {
  Widget host(AssistantOrbModel model) => AssistantOrbApp(model: model);

  group('orb reflects voice state', () {
    testWidgets('idle when the session is idle', (tester) async {
      await tester.pumpWidget(host(_FakeOrbModel()));
      await tester.pump();
      final orb = tester.widget<AymaOrb>(find.byKey(const Key('assistantOrb')));
      expect(orb.state, AymaOrbState.idle);
    });

    testWidgets('listening maps to the listening orb', (tester) async {
      await tester
          .pumpWidget(host(_FakeOrbModel(orbStateValue: AymaOrbState.listening)));
      await tester.pump();
      final orb = tester.widget<AymaOrb>(find.byKey(const Key('assistantOrb')));
      expect(orb.state, AymaOrbState.listening);
      expect(orb.voiceLive, isTrue);
    });

    testWidgets('speaking maps to the speaking orb', (tester) async {
      await tester
          .pumpWidget(host(_FakeOrbModel(orbStateValue: AymaOrbState.speaking)));
      await tester.pump();
      final orb = tester.widget<AymaOrb>(find.byKey(const Key('assistantOrb')));
      expect(orb.state, AymaOrbState.speaking);
    });
  });

  testWidgets('pure state mapping covers idle/listening/speaking', (tester) async {
    expect(
      assistantOrbStateFrom(phase: VoiceSessionPhase.idle, agentSpeaking: false),
      AymaOrbState.idle,
    );
    expect(
      assistantOrbStateFrom(phase: VoiceSessionPhase.live, agentSpeaking: false),
      AymaOrbState.listening,
    );
    expect(
      assistantOrbStateFrom(phase: VoiceSessionPhase.live, agentSpeaking: true),
      AymaOrbState.speaking,
    );
    expect(
      assistantOrbStateFrom(
          phase: VoiceSessionPhase.live, agentSpeaking: false, reconnecting: true),
      AymaOrbState.thinking,
    );
    expect(
      assistantOrbStateFrom(phase: VoiceSessionPhase.connecting, agentSpeaking: false),
      AymaOrbState.thinking,
    );
  });

  testWidgets('tapping the orb expands to the voice panel', (tester) async {
    final model = _FakeOrbModel(orbStateValue: AymaOrbState.listening);
    await tester.pumpWidget(host(model));
    await tester.pump();

    expect(find.byKey(const Key('assistantOrbExpanded')), findsNothing);
    await tester.tap(find.byKey(const Key('assistantOrbTap')));
    await tester.pump();
    expect(find.byKey(const Key('assistantOrbExpanded')), findsOneWidget);
    // The large orb still reflects the live state while expanded.
    final orbs = tester.widgetList<AymaOrb>(find.byType(AymaOrb)).toList();
    expect(orbs.any((o) => o.state == AymaOrbState.listening), isTrue);
  });

  testWidgets('dismissing returns to the app (tap outside the orb)',
      (tester) async {
    final model = _FakeOrbModel();
    await tester.pumpWidget(host(model));
    await tester.pump();
    await tester.tapAt(const Offset(10, 10)); // the transparent dismiss-catcher
    await tester.pump();
    expect(model.dismissed, 1);
  });

  testWidgets('an honest error shows instead of a fake Listening',
      (tester) async {
    final model = _FakeOrbModel(error: "Ayma can't connect right now");
    await tester.pumpWidget(host(model));
    await tester.pump();
    expect(find.byKey(const Key('assistantOrbError')), findsOneWidget);
    expect(find.text("Ayma can't connect right now"), findsOneWidget);
    // The orb never shows the listening state while erroring.
    final orb = tester.widget<AymaOrb>(find.byKey(const Key('assistantOrb')));
    expect(orb.state, AymaOrbState.idle);
  });

  testWidgets('mute toggles from the expanded panel', (tester) async {
    final model = _FakeOrbModel(orbStateValue: AymaOrbState.listening);
    await tester.pumpWidget(host(model));
    await tester.pump();
    await tester.tap(find.byKey(const Key('assistantOrbTap')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('assistantOrbMute')));
    await tester.pump();
    expect(model.muteToggles, 1);
  });
}
