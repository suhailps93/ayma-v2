import 'dart:async';
import 'dart:io';

import 'async_voice_controller.dart';
import 'async_voice_recorder.dart';
import 'voice_note_controller.dart';

/// The DM chat's [VoiceNoteEngine]: record → hand the finished clip to
/// [onSendClip], which uploads it and posts the `voice` DM. Delivery is
/// immediate (the sender's bubble renders from the local file); the server
/// transcribes the note for ingestion in the background, never gating the
/// send (founder direction, 2026-11-05/06).
///
/// The recording lifecycle mirrors [AsyncVoiceController] (same recorder
/// seam, same mic-permission flow, same too-short-tap rule). Max duration:
/// the DM composer had no recording at all before this, so there was no
/// existing cap to keep — this reuses the Ayma voice-message cap
/// ([AsyncVoiceController.maxDuration], 120s) rather than inventing a
/// second number.
class DmVoiceNoteEngine extends VoiceNoteEngine {
  DmVoiceNoteEngine({AsyncVoiceRecorder? recorder, required this.onSendClip})
    : _recorder = recorder ?? RecordPluginRecorder();

  /// Called once per finished, sendable clip. Owns upload + posting; the
  /// engine is already back to idle when it runs.
  final Future<void> Function(File file) onSendClip;

  final AsyncVoiceRecorder _recorder;

  bool _recording = false;
  String? _error;
  String? _tempPath;
  Timer? _ticker;
  Timer? _capTimer;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  Duration _pausedAccum = Duration.zero;
  DateTime? _pausedAt;
  Duration? _capRemaining;
  bool _disposed = false;

  @override
  bool get isRecording => _recording;

  @override
  bool get isPaused => _pausedAt != null;

  @override
  Duration get elapsed => _elapsed;

  @override
  Duration get maxClipDuration => AsyncVoiceController.maxDuration;

  @override
  String? takeError() {
    final e = _error;
    _error = null;
    return e;
  }

  Duration _effectiveElapsed() {
    final started = _startedAt;
    if (started == null) return _elapsed;
    final end = _pausedAt ?? DateTime.now();
    final raw = end.difference(started) - _pausedAccum;
    return raw.isNegative ? Duration.zero : raw;
  }

  @override
  Future<bool> startRecording() async {
    if (_recording) return false;
    _error = null;
    bool allowed;
    try {
      allowed = await _recorder.ensurePermission();
    } catch (_) {
      allowed = false;
    }
    if (!allowed) {
      _error = 'Microphone access is off - Ayma needs it to record.';
      notifyListeners();
      return false;
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tempPath = '${Directory.systemTemp.path}/ayma_dm_voice_$stamp.wav';
    try {
      await _recorder.start(tempPath);
    } catch (_) {
      _error = "Couldn't start recording. Please try again.";
      notifyListeners();
      return false;
    }
    _tempPath = tempPath;
    _pausedAccum = Duration.zero;
    _pausedAt = null;
    _capRemaining = null;
    _startedAt = DateTime.now();
    _elapsed = Duration.zero;
    _recording = true;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed || _startedAt == null) return;
      _elapsed = _effectiveElapsed();
      notifyListeners();
    });
    _capTimer = Timer(maxClipDuration, () => unawaited(sendRecording()));
    notifyListeners();
    return true;
  }

  @override
  Future<void> sendRecording() async {
    if (!_recording) return;
    _stopTimers();
    _recording = false;
    _pausedAt = null;
    notifyListeners();
    RecordedClip? clip;
    try {
      clip = await _recorder.stop();
    } catch (_) {
      clip = null;
    }
    if (clip == null) {
      _resetToIdle();
      return;
    }
    if (clip.sizeBytes < _minClipBytes) {
      // A too-short tap records nothing - drop it like the Ayma path does.
      await _recorder.discard(clip.path);
      _resetToIdle();
      return;
    }
    final file = File(clip.path);
    _resetToIdle();
    await onSendClip(file);
  }

  @override
  Future<void> cancelRecording() async {
    if (!_recording) return;
    _stopTimers();
    _recording = false;
    _pausedAt = null;
    try {
      await _recorder.cancel();
    } catch (_) {}
    final temp = _tempPath;
    _resetToIdle();
    if (temp != null) await _recorder.discard(temp);
  }

  @override
  Future<void> pauseRecording() async {
    if (!_recording || _pausedAt != null) return;
    _pausedAt = DateTime.now();
    _elapsed = _effectiveElapsed();
    _capRemaining = maxClipDuration - _elapsed;
    _capTimer?.cancel();
    _capTimer = null;
    final r = _recorder;
    if (r is RecordPluginRecorder) await r.pause();
    notifyListeners();
  }

  @override
  Future<void> resumeRecording() async {
    final pausedAt = _pausedAt;
    if (!_recording || pausedAt == null) return;
    _pausedAccum += DateTime.now().difference(pausedAt);
    _pausedAt = null;
    final remaining = _capRemaining;
    _capRemaining = null;
    if (remaining != null) {
      if (remaining <= Duration.zero) {
        unawaited(sendRecording());
        return;
      }
      _capTimer = Timer(remaining, () => unawaited(sendRecording()));
    }
    final r = _recorder;
    if (r is RecordPluginRecorder) await r.resume();
    notifyListeners();
  }

  void _stopTimers() {
    _ticker?.cancel();
    _ticker = null;
    _capTimer?.cancel();
    _capTimer = null;
  }

  void _resetToIdle() {
    _stopTimers();
    _tempPath = null;
    _elapsed = Duration.zero;
    _startedAt = null;
    _pausedAccum = Duration.zero;
    _pausedAt = null;
    _capRemaining = null;
    if (!_disposed) notifyListeners();
  }

  /// A finished wav header alone is 44 bytes - anything under 1KB is a
  /// tap, not a message (same rule as [AsyncVoiceController]).
  static const _minClipBytes = 1024;

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _recorder.dispose();
    super.dispose();
  }
}
