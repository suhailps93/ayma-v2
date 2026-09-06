import 'package:just_audio/just_audio.dart';

/// Plays the short voice-preset preview clips on the voice-preference screen
/// (§13.3). The screen owns exactly one instance; starting a new preview stops
/// whatever was playing. Abstracted behind an interface so widget tests inject
/// a no-op instead of touching platform audio.
abstract class VoicePreviewPlayer {
  /// Stop anything currently playing, then start [url] from the beginning.
  Future<void> play(String url);

  /// Stop playback (no-op if nothing is playing).
  Future<void> stop();

  /// Release native resources. The instance is unusable afterwards.
  void dispose();
}

/// [VoicePreviewPlayer] backed by `just_audio`.
class JustAudioPreviewPlayer implements VoicePreviewPlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> play(String url) async {
    await _player.stop();
    await _player.setUrl(url);
    await _player.play();
  }

  @override
  Future<void> stop() => _player.stop();

  @override
  void dispose() => _player.dispose();
}
