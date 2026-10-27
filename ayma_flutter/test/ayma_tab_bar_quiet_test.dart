// The nav-bar orb while Ayma has been told to "shut up": the normal-colour
// orb (no speaking animation) with a muted-speaker badge overlaid, reading
// "Ayma is quiet" — with any accent, in both themes, in the compact bar too.
// A tap does NOT unmute (founder, build 2211); unmute is only via the quiet
// bar button, the notification, or saying "Ayma".
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

  @override
  bool get isListening => true;

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

final _quietBadge = find.byKey(const Key('aymaTabQuietBadge'));

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
  testWidgets('quiet overlays a muted badge on the normal-colour orb, with '
      'no speaking animation; badge clears on unmute', (tester) async {
    final voice = _FakeVoice();
    await tester.pumpWidget(_host(voice));
    await tester.pump();
    expect(_quietBadge, findsNothing);
    expect(find.byIcon(Icons.volume_off_rounded), findsNothing);
    expect(tester.widget<AymaOrb>(find.byType(AymaOrb)).state,
        AymaOrbState.speaking);

    voice.setQuiet(true);
    await tester.pump();
    expect(_quietBadge, findsOneWidget);
    final orb = tester.widget<AymaOrb>(find.byType(AymaOrb));
    // Normal orb: still rendered, no greyscale/dim filter, connected glow on
    // (it is a live call); only the speaking animation is dropped.
    expect(orb.state, AymaOrbState.idle);
    expect(orb.voiceLive, isTrue);
    expect(find.byType(ColorFiltered), findsNothing);
    expect(find.byType(Opacity), findsNothing);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    expect(
      find.bySemanticsLabel(AymaTabBar.quietSemanticsLabel),
      findsOneWidget,
    );

    voice.setQuiet(false);
    await tester.pump();
    expect(_quietBadge, findsNothing);
    expect(find.byIcon(Icons.volume_off_rounded), findsNothing);
    expect(tester.widget<AymaOrb>(find.byType(AymaOrb)).state,
        AymaOrbState.speaking);
  });

  testWidgets('tapping the orb never unmutes — it switches tabs as usual, '
      'quiet or not', (tester) async {
    final voice = _FakeVoice()..setQuiet(true);
    final selected = <int>[];
    await tester.pumpWidget(_host(voice, onSelected: selected.add));
    await tester.pump();

    // Quiet: a tap must NOT unmute (founder, build 2211) and still behaves
    // like the normal orb tab (fires onSelected(0)).
    await tester.tap(find.byType(AymaOrb));
    await tester.pump();
    expect(voice.unmuteCalls, 0);
    expect(selected, [0]);

    voice.setQuiet(false);
    await tester.pump();
    await tester.tap(find.byType(AymaOrb));
    await tester.pump();
    expect(voice.unmuteCalls, 0);
    expect(selected, [0, 0]);
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
        expect(_quietBadge, findsOneWidget);
        expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
        // The orb keeps its normal box; the badge overflows it (no clip).
        expect(
          tester.getSize(find.byType(AymaOrb)).height,
          size.height < AymaTabBar.compactBelowHeight ? 40 : 64,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
