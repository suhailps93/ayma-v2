import 'dart:io';

import 'package:record/record.dart';

/// A finished recording: where it is and how big — reported by the
/// recorder so callers can drop too-short taps without touching the file
/// system themselves (widget tests stay IO-free).
class RecordedClip {
  const RecordedClip({required this.path, required this.sizeBytes});

  final String path;
  final int sizeBytes;
}

/// Records one async voice message to a wav file (Chunk A).
///
/// Abstracted behind an interface so widget tests inject a fake instead of
/// touching the microphone. Exactly one recording at a time per instance.
/// All file IO lives behind this seam (the real plugin impl stats and
/// deletes); fakes answer from memory, keeping widget tests IO-free.
abstract class AsyncVoiceRecorder {
  /// The mic permission, requesting it when needed. False means recording
  /// cannot start (denied / restricted) — the caller explains, not retries.
  Future<bool> ensurePermission();

  /// Start recording to [path] (16kHz mono wav — the format the LiveKit
  /// gateway transcribes), clearing any stale file already there. Throws
  /// when the platform refuses to start.
  Future<void> start(String path);

  /// Stop and describe the finished clip (null when nothing recorded).
  Future<RecordedClip?> stop();

  /// Stop and delete the in-progress recording, if any. Never throws.
  Future<void> cancel();

  /// Delete a finished clip (a tap too short to send). Best-effort.
  Future<void> discard(String path);

  /// Release native resources. The instance is unusable afterwards.
  void dispose();
}

/// [AsyncVoiceRecorder] backed by the `record` plugin.
///
/// The platform recorder is created on first use, never in the constructor,
/// so merely building the chat screen (widget tests included) never touches
/// a platform channel.
class RecordPluginRecorder implements AsyncVoiceRecorder {
  RecordPluginRecorder({AudioRecorder? recorder}) {
    _recorder = recorder;
  }

  AudioRecorder? _recorder;
  AudioRecorder get _r => _recorder ??= AudioRecorder();

  /// 16kHz mono wav: the smallest the gateway's STT decodes well (~32KB/s),
  /// so a two-minute message uploads fast even on a weak connection.
  static const _config = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  );

  @override
  Future<bool> ensurePermission() => _r.hasPermission();

  @override
  Future<void> start(String path) async {
    try {
      final stale = File(path);
      if (await stale.exists()) await stale.delete();
    } catch (_) {
      // Best-effort: the platform encoder overwrites anyway.
    }
    await _r.start(_config, path: path);
  }

  @override
  Future<RecordedClip?> stop() async {
    final r = _recorder;
    if (r == null) return null;
    final path = await r.stop();
    if (path == null) return null;
    try {
      final size = await File(path).length();
      return RecordedClip(path: path, sizeBytes: size);
    } catch (_) {
      return null;
    }
  }

  /// Pause the in-progress recording (the file keeps its place; [resume]
  /// continues into the same clip). Best-effort — a recorder that was never
  /// started simply ignores it.
  Future<void> pause() async {
    try {
      await _recorder?.pause();
    } catch (_) {
      // Best-effort: there may be nothing to pause.
    }
  }

  /// Resume a recording paused with [pause]. Best-effort.
  Future<void> resume() async {
    try {
      await _recorder?.resume();
    } catch (_) {
      // Best-effort: there may be nothing to resume.
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _recorder?.cancel();
    } catch (_) {
      // Best-effort: there may be nothing to cancel.
    }
  }

  @override
  Future<void> discard(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort.
    }
  }

  @override
  void dispose() {
    _recorder?.dispose();
    _recorder = null;
  }
}
