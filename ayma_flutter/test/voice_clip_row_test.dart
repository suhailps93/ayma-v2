import 'package:ayma_flutter/services/async_voice_player.dart';
import 'package:ayma_flutter/widgets/voice_clip_row.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlayer implements AsyncVoicePlayer {
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  final List<String> playedUrls = [];
  int stopCalls = 0;

  @override
  ValueListenable<bool> get playing => _playing;

  @override
  Future<void> playUrl(String url) async {
    playedUrls.add(url);
    _playing.value = true;
  }

  @override
  Future<void> playFile(String path) async {
    playedUrls.add(path);
    _playing.value = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing.value = false;
  }

  /// Simulates the clip ending on its own: a real player reports
  /// `playing == false` once playback completes naturally (the
  /// just_audio completed state), with no stop() call involved.
  void simulateNaturalCompletion() {
    _playing.value = false;
  }

  @override
  void dispose() {}
}

Widget _wrap(VoiceClipRow row) {
  return MaterialApp(
    home: Scaffold(body: Center(child: row)),
  );
}

VoiceClipRow _row(_FakePlayer player, ValueNotifier<String?> nowPlaying) {
  return VoiceClipRow(
    audioUrl: 'https://example.com/clip.wav',
    player: player,
    nowPlaying: nowPlaying,
    clipKey: 'clip-1',
    iconColor: const Color(0xFFDA4B65),
    captionColor: const Color(0xFF888888),
  );
}

void main() {
  testWidgets('play button is a large 44dp filled circle', (tester) async {
    final player = _FakePlayer();
    final nowPlaying = ValueNotifier<String?>(null);
    await tester.pumpWidget(_wrap(_row(player, nowPlaying)));

    final button = find.byKey(const ValueKey('voiceClipPlayButton'));
    expect(button, findsOneWidget);
    expect(tester.getSize(button), const Size(44, 44));

    final container = tester.widget<Container>(button);
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.color, const Color(0xFFDA4B65));

    final icon = tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded));
    expect(icon.size, 26);
    expect(find.text('Voice message'), findsOneWidget);
  });

  testWidgets('tap plays, button switches to pause, tap again stops',
      (tester) async {
    final player = _FakePlayer();
    final nowPlaying = ValueNotifier<String?>(null);
    await tester.pumpWidget(_wrap(_row(player, nowPlaying)));

    await tester.tap(find.byKey(const ValueKey('voiceClipPlayButton')));
    await tester.pump();
    expect(player.playedUrls, ['https://example.com/clip.wav']);
    expect(nowPlaying.value, 'clip-1');
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

    await tester.tap(find.byKey(const ValueKey('voiceClipPlayButton')));
    await tester.pump();
    expect(player.stopCalls, 1);
    expect(nowPlaying.value, isNull);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets(
    'natural completion switches pause back to play, next tap replays',
    (tester) async {
      final player = _FakePlayer();
      final nowPlaying = ValueNotifier<String?>(null);
      await tester.pumpWidget(_wrap(_row(player, nowPlaying)));

      await tester.tap(find.byKey(const ValueKey('voiceClipPlayButton')));
      await tester.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // The clip ends on its own — no tap, no stop().
      player.simulateNaturalCompletion();
      await tester.pump();
      expect(player.stopCalls, 0);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      final labels = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((s) => s.properties.label)
          .toList();
      expect(labels, contains('Play voice message'));
      expect(labels, isNot(contains('Pause voice message')));

      // Tapping again replays the clip from the start instead of
      // toggling a stale "playing" state off.
      await tester.tap(find.byKey(const ValueKey('voiceClipPlayButton')));
      await tester.pump();
      expect(player.playedUrls, [
        'https://example.com/clip.wav',
        'https://example.com/clip.wav',
      ]);
      expect(player.stopCalls, 0);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    },
  );

  testWidgets('no clip renders nothing', (tester) async {
    final player = _FakePlayer();
    final nowPlaying = ValueNotifier<String?>(null);
    await tester.pumpWidget(
      _wrap(
        VoiceClipRow(
          player: player,
          nowPlaying: nowPlaying,
          clipKey: 'clip-1',
          iconColor: const Color(0xFFDA4B65),
          captionColor: const Color(0xFF888888),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('voiceClipPlayButton')), findsNothing);
    expect(find.text('Voice message'), findsNothing);
  });
}
