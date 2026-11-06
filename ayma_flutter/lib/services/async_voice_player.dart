import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays async voice-message clips (Chunk A): the user's recorded file and
/// Ayma's spoken reply URL.
///
/// Abstracted behind an interface so widget tests inject a fake instead of
/// touching platform audio. One clip at a time: starting a new one stops
/// whatever was playing.
abstract class AsyncVoicePlayer {
  /// Stop anything playing, then start [url] from the beginning. Completes
  /// once playback has started (not when the clip ends).
  Future<void> playUrl(String url);

  /// Stop anything playing, then start the local file at [path].
  Future<void> playFile(String path);

  /// Stop playback (no-op if nothing is playing).
  Future<void> stop();

  /// True while a clip is playing (false when paused, stopped or finished).
  ValueListenable<bool> get playing;

  /// Release native resources. The instance is unusable afterwards.
  void dispose();
}

/// [AsyncVoicePlayer] backed by `just_audio` (the same engine as the
/// voice-preset previews).
///
/// The platform player is created on first use, never in the constructor,
/// so merely building the chat screen (widget tests included) never touches
/// a platform channel.
class JustAudioVoicePlayer implements AsyncVoicePlayer {
  JustAudioVoicePlayer({AudioPlayer? player}) {
    _player = player;
    if (player != null) _watch(player);
  }

  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _sub;
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);
  int _token = 0;

  AudioPlayer get _p {
    final existing = _player;
    if (existing != null) return existing;
    final created = AudioPlayer();
    _player = created;
    _watch(created);
    return created;
  }

  void _watch(AudioPlayer p) {
    _sub = p.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // just_audio keeps `playing` true after a clip finishes naturally
        // — it stays true until pause()/stop() is called (see the play()
        // docs in just_audio 0.10.6). Copying state.playing verbatim here
        // therefore left VoiceClipRow stuck on the pause icon after a
        // clip ended on its own (founder, 2026-11-06, build 2317).
        // A completed clip is finished: report not-playing so the button
        // resets to play, and pause + rewind the platform player so its
        // own state matches and a replay starts from the beginning.
        _playing.value = false;
        _resetAfterCompletion(p);
        return;
      }
      _playing.value = state.playing;
    });
  }

  /// Pauses and rewinds [p] after natural completion. Fire-and-forget:
  /// the clip is already over, so a failure here is not actionable — the
  /// next play goes through [_start], which stops and reloads anyway.
  Future<void> _resetAfterCompletion(AudioPlayer p) async {
    try {
      await p.pause();
      await p.seek(Duration.zero);
    } catch (_) {
      // Player disposed or platform gone — nothing left to reset.
    }
  }

  @override
  ValueListenable<bool> get playing => _playing;

  Future<void> _start(Future<Duration?> Function(AudioPlayer p) load) async {
    final token = ++_token;
    final player = _p;
    await player.stop();
    if (token != _token) return;
    try {
      await load(player);
    } catch (_) {
      if (token != _token) return; // superseded by a newer request
      rethrow;
    }
    if (token != _token) return;
    // Not awaited: it completes only when the clip ends, and a newer tap
    // must be able to start while this one is still playing.
    player.play().catchError((Object _) {});
  }

  @override
  Future<void> playUrl(String url) => _start((p) => p.setUrl(url));

  @override
  Future<void> playFile(String path) => _start((p) => p.setFilePath(path));

  @override
  Future<void> stop() async {
    _token++;
    await _player?.stop();
  }

  @override
  void dispose() {
    _token++;
    _sub?.cancel();
    _sub = null;
    _playing.dispose();
    _player?.dispose();
    _player = null;
  }
}
