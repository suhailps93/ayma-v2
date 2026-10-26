// The nav-bar orb while Ayma has been told to "shut up": a dimmed, still,
// badged orb that reads "Ayma is quiet, double tap to unmute" and unmutes on
// tap — with any accent, in both themes, in the compact bar too.
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:ayma_flutter/services/voice_session_controller.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeVoice extends VoiceSessionController {
  _FakeVoice() : super(transcriptStore: TranscriptStore());

  bool _quiet = false;
  int unmuteCalls = 0;

  @override
  VoiceSessionPhase get phase => VoiceSessionPhase.live;

  @override
  bool get isActive => true;

  // Ayma "speaking" must never animate the orb while she is quiet.
  @override
  bool get agentSpeaking => true;

  @override
  bool get aymaQuiet => _quiet;

  void setQuiet(bool quiet) {
    _quiet = quiet;
    notifyListeners();
  }

  @override
  Future<void> unmuteAyma() async {
    unmuteCalls += 1;
  }
}

final _quietOrb = find.byKey(const Key('aymaTabQuietOrb'));

Widget _host(
  _FakeVoice voice, {
  ThemeData? theme,
  ValueChanged<int>? onSelected,
}) =>
    MaterialApp(
      theme: theme ?? AymaTheme.light,
      home: Scaffold(
        bottomNavigationBar: ListenableBuilder(
          listenable: voice,
          builder: (context, _) => AymaTabBar(
            index: 1,
            voice: voice,
            onSelected: onSelected ?? (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('quiet shows the still, badged orb; unmute restores the live '
      'orb', (tester) async {
    final voice = _FakeVoice();
    await tester.pumpWidget(_host(voice));
    await tester.pump();
    expect(_quietOrb, findsNothing);
    expect(tester.widget<AymaOrb>(find.byType(AymaOrb)).state,
        AymaOrbState.speaking);

    voice.setQuiet(true);
    await tester.pump();
    expect(_quietOrb, findsOneWidget);
    final orb = tester.widget<AymaOrb>(find.byType(AymaOrb));
    expect(orb.state, AymaOrbState.idle);
    expect(orb.voiceLive, isFalse);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    expect(
      find.bySemanticsLabel(AymaTabBar.quietSemanticsLabel),
      findsOneWidget,
    );

    voice.setQuiet(false);
    await tester.pump();
    expect(_quietOrb, findsNothing);
    expect(tester.widget<AymaOrb>(find.byType(AymaOrb)).state,
        AymaOrbState.speaking);
  });

  testWidgets('tapping the quiet orb unmutes instead of switching tabs; '
      'otherwise it switches as before', (tester) async {
    final voice = _FakeVoice()..setQuiet(true);
    final selected = <int>[];
    await tester.pumpWidget(_host(voice, onSelected: selected.add));
    await tester.pump();

    await tester.tap(_quietOrb);
    await tester.pump();
    expect(voice.unmuteCalls, 1);
    expect(selected, isEmpty);

    voice.setQuiet(false);
    await tester.pump();
    await tester.tap(find.byType(AymaOrb));
    await tester.pump();
    expect(voice.unmuteCalls, 1);
    expect(selected, [0]);
  });

  // Themes are built inside each test (they load fonts, which needs a test
  // zone).
  for (final (name, theme) in <(String, ThemeData Function())>[
    ('light, default accent', () => AymaTheme.light),
    ('dark, default accent', () => AymaTheme.dark),
    ('light, custom accent', () => AymaTheme.lightWithAccent(Colors.teal)),
    ('dark, custom accent', () => AymaTheme.darkWithAccent(Colors.amber)),
  ]) {
    for (final size in [const Size(400, 800), const Size(700, 320)]) {
      testWidgets('quiet orb lays out cleanly: $name at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final voice = _FakeVoice()..setQuiet(true);
        await tester.pumpWidget(_host(voice, theme: theme()));
        await tester.pump();
        expect(_quietOrb, findsOneWidget);
        expect(
          tester.getSize(_quietOrb).height,
          size.height < AymaTabBar.compactBelowHeight ? 40 : 64,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
