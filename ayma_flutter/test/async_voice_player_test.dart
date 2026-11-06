import 'dart:async';

import 'package:ayma_flutter/services/async_voice_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

/// An [AudioPlayer] whose state stream is driven by the test and whose
/// pause/seek calls are recorded instead of touching a platform channel.
class _FakeAudioPlayer extends AudioPlayer {
  final StreamController<PlayerState> _states =
      StreamController<PlayerState>.broadcast();
  int pauseCalls = 0;
  final List<Duration?> seeks = [];

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(position);
  }

  @override
  Future<void> dispose() async {
    await _states.close();
  }

  void emit(PlayerState state) => _states.add(state);
}

void main() {
  // AudioPlayer's constructor touches AudioSession's method channel,
  // which needs a binding even though no platform call is ever made.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'natural completion reports not playing and rewinds the player',
    () async {
      final fake = _FakeAudioPlayer();
      final player = JustAudioVoicePlayer(player: fake);
      addTearDown(player.dispose);

      expect(player.playing.value, isFalse);

      fake.emit(PlayerState(true, ProcessingState.ready));
      await pumpEventQueue();
      expect(player.playing.value, isTrue);

      // just_audio keeps `playing` true in the completed state — it stays
      // true until pause()/stop() is called. The wrapper must still report
      // not-playing so VoiceClipRow resets its button from pause to play.
      fake.emit(PlayerState(true, ProcessingState.completed));
      await pumpEventQueue();
      expect(player.playing.value, isFalse);
      expect(fake.pauseCalls, 1);
      expect(fake.seeks, [Duration.zero]);
    },
  );

  test('ordinary playing/paused states pass through unchanged', () async {
    final fake = _FakeAudioPlayer();
    final player = JustAudioVoicePlayer(player: fake);
    addTearDown(player.dispose);

    fake.emit(PlayerState(true, ProcessingState.ready));
    await pumpEventQueue();
    expect(player.playing.value, isTrue);

    fake.emit(PlayerState(false, ProcessingState.ready));
    await pumpEventQueue();
    expect(player.playing.value, isFalse);
    expect(fake.pauseCalls, 0);
    expect(fake.seeks, isEmpty);
  });
}
