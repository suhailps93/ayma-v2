import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the short voice-preset preview clips on the voice-preference screen
/// (§13.3). The screen owns exactly one instance; starting a new preview stops
/// whatever was playing. Abstracted behind an interface so widget tests inject
/// a no-op instead of touching platform audio.
abstract class VoicePreviewPlayer {
  /// Stop anything currently playing, then start [url] from the beginning.
  /// Completes once playback has started (not when the clip ends). A call
  /// superseded by a newer [play] / [stop] returns without playing.
  Future<void> play(String url);

  /// Stop playback (no-op if nothing is playing).
  Future<void> stop();

  /// Release native resources. The instance is unusable afterwards.
  void dispose();

  /// Callback fired when playback completes naturally.
  VoidCallback? onComplete;
}

/// [VoicePreviewPlayer] backed by `just_audio`.
///
/// Every [play] / [stop] takes a monotonically increasing token; after each
/// await a superseded call aborts without touching the player, so the latest
/// request always wins.
class JustAudioPreviewPlayer implements VoicePreviewPlayer {
  JustAudioPreviewPlayer() {
    _sub = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // just_audio keeps `playing` true after a clip finishes naturally until
        // stop()/pause() is called (see async_voice_player.dart). Stop the
        // player so its native state matches, and notify listeners.
        _player.stop().catchError((Object _) {});
        onComplete?.call();
      }
    });
  }

  final AudioPlayer _player = AudioPlayer();
  int _token = 0;
  StreamSubscription<PlayerState>? _sub;

  @override
  VoidCallback? onComplete;

  @override
  Future<void> play(String url) async {
    final token = ++_token;
    await _player.stop();
    if (token != _token) return;
    try {
      await _player.setUrl(url);
    } catch (_) {
      if (token != _token) return; // interrupted by a newer request
      rethrow;
    }
    if (token != _token) return;
    // Not awaited: it completes only when the clip ends, and a newer tap must
    // be able to start while this one is still playing. Stopping completes it
    // normally; a failed start is not actionable beyond silence.
    _player.play().catchError((Object _) {});
  }

  @override
  Future<void> stop() {
    _token++;
    return _player.stop();
  }

  @override
  void dispose() {
    _token++;
    _sub?.cancel();
    _player.dispose();
  }
}
