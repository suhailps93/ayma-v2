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
  DmVoiceNoteEngine({
    AsyncVoiceRecorder? recorder,
    required this.onSendClip,
    Duration? capDuration,
  }) : _recorder = recorder ?? RecordPluginRecorder(),
       _capDuration = capDuration ?? AsyncVoiceController.maxDuration;

  /// Called once per finished, sendable clip. Owns upload + posting; the
  /// engine is already back to idle when it runs.
  final Future<void> Function(File file) onSendClip;

  final AsyncVoiceRecorder _recorder;

  /// The cap this instance enforces — the shared 120s in production,
  /// injectable so tests can reach the cap without waiting.
  final Duration _capDuration;

  /// A clip stopped at the cap while locked, held unsent (F3).
  File? _heldFile;

  bool _holdClipAtCap = false;

  @override
  bool get hasCapHeldClip => _heldFile != null;

  @override
  bool get holdClipAtCap => _holdClipAtCap;

  @override
  set holdClipAtCap(bool value) => _holdClipAtCap = value;

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
  Duration get maxClipDuration => _capDuration;

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
    _heldFile = null;
    _holdClipAtCap = false;
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
    _capTimer = Timer(maxClipDuration, () => unawaited(_onCapReached()));
    notifyListeners();
    return true;
  }

  /// The max-duration cap fired. On the hold-to-record path this keeps the
  /// legacy behavior — stop and send what we have. When the controller
  /// armed [holdClipAtCap] (the recording is LOCKED, hands-free), the
  /// WhatsApp rule applies instead (Scout note 123, F3): stop the
  /// recorder and HOLD the finished clip unsent — it leaves only via an
  /// explicit [sendRecording] from the locked bar, and is discarded by an
  /// explicit [cancelRecording]. [onSendClip] is NOT called here.
  Future<void> _onCapReached() async {
    if (!_recording) return;
    if (!_holdClipAtCap) {
      await sendRecording();
      return;
    }
    _elapsed = _effectiveElapsed();
    _stopTimers();
    _recording = false;
    _pausedAt = null;
    _capRemaining = null;
    RecordedClip? clip;
    try {
      clip = await _recorder.stop();
    } catch (_) {
      clip = null;
    }
    if (clip == null || clip.sizeBytes < _minClipBytes) {
      if (clip != null) await _recorder.discard(clip.path);
      _resetToIdle();
      return;
    }
    _heldFile = File(clip.path);
    notifyListeners();
  }

  @override
  Future<void> sendRecording() async {
    // A cap-held clip (F3) sends from its stash — the recorder already
    // stopped at the cap, so there is nothing new to stop.
    final held = _heldFile;
    if (held != null) {
      _heldFile = null;
      _holdClipAtCap = false;
      _resetToIdle();
      await onSendClip(held);
      return;
    }
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
    // A cap-held clip (F3) is discarded from its stash — the recorder
    // already stopped at the cap, so there is nothing live to cancel.
    final held = _heldFile;
    if (held != null) {
      _heldFile = null;
      _holdClipAtCap = false;
      _resetToIdle();
      await _recorder.discard(held.path);
      return;
    }
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
        unawaited(_onCapReached());
        return;
      }
      _capTimer = Timer(remaining, () => unawaited(_onCapReached()));
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
    _heldFile = null;
    _holdClipAtCap = false;
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
