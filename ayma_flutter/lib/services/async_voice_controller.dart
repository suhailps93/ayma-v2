import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'async_voice_queue.dart';
import 'async_voice_recorder.dart';
import 'ids.dart';

/// What the async voice UI is doing right now.
enum AsyncVoiceUiState {
  /// Nothing recording or sending.
  idle,

  /// The mic is hot: the user is holding it down and speaking.
  recording,

  /// The clip is on its way (queued / uploading / the job running) — the
  /// wing loader's stage comes from the queue ([AsyncVoiceQueue.stageFor]).
  working,
}

/// Press-speak-release state for one async voice message (Chunk A).
///
/// Owns the recorder and the handoff into [AsyncVoiceQueue]; the UI reads
/// [state]/[elapsed]/[activeJobId] from here and the delivery stage from
/// the queue. One message at a time: starting while busy is a no-op.
class AsyncVoiceController extends ChangeNotifier {
  AsyncVoiceController({AsyncVoiceRecorder? recorder, AsyncVoiceQueue? queue})
    : _recorder = recorder ?? RecordPluginRecorder(),
      _queue = queue ?? AsyncVoiceQueue.instance;

  final AsyncVoiceRecorder _recorder;
  final AsyncVoiceQueue _queue;

  /// The longest a single voice message may run before the controller
  /// stops it itself (~3.8MB at 16kHz mono — inside the server's clip cap).
  static const maxDuration = Duration(seconds: 120);

  AsyncVoiceUiState _state = AsyncVoiceUiState.idle;
  AsyncVoiceUiState get state => _state;

  /// How long the current recording has run (ticks while [state] is
  /// [AsyncVoiceUiState.recording]).
  Duration get elapsed => _elapsed;
  Duration _elapsed = Duration.zero;

  /// The in-flight message's job id, while recording or working.
  String? get activeJobId => _jobId;
  String? _jobId;

  /// A one-shot recording failure for the UI to surface (`mic denied`,
  /// `couldn't start recording`) — cleared once read.
  String? takeError() {
    final e = _error;
    _error = null;
    return e;
  }

  String? _error;
  String? _tempPath;
  Timer? _ticker;
  Timer? _capTimer;
  DateTime? _startedAt;
  bool _disposed = false;

  /// Press: take the mic and start recording. Returns false when recording
  /// cannot start ([takeError] says why) — the UI stays idle.
  Future<bool> startRecording() async {
    if (_state != AsyncVoiceUiState.idle) return false;
    _error = null;
    bool allowed;
    try {
      allowed = await _recorder.ensurePermission();
    } catch (_) {
      allowed = false;
    }
    if (!allowed) {
      _error = 'Microphone access is off — Ayma needs it to record.';
      notifyListeners();
      return false;
    }
    final jobId = newVoiceJobId();
    final tempPath = '${Directory.systemTemp.path}/ayma_async_$jobId.wav';
    try {
      await _recorder.start(tempPath);
    } catch (_) {
      _error = "Couldn't start recording. Please try again.";
      notifyListeners();
      return false;
    }
    _jobId = jobId;
    _tempPath = tempPath;
    _startedAt = DateTime.now();
    _elapsed = Duration.zero;
    _state = AsyncVoiceUiState.recording;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed || _startedAt == null) return;
      _elapsed = DateTime.now().difference(_startedAt!);
      notifyListeners();
    });
    _capTimer = Timer(maxDuration, () {
      // A finger held forever still ends: stop and send what we have.
      unawaited(stopAndSend());
    });
    notifyListeners();
    return true;
  }

  /// Release: stop the recorder and hand the clip to the queue for upload
  /// whenever the connection allows. A too-short tap records nothing and
  /// drops back to idle instead of sending silence.
  ///
  /// Touches no file IO itself (the recorder reports the clip's size, the
  /// queue moves the bytes), so widget tests drive this in the fake zone.
  Future<void> stopAndSend() async {
    if (_state != AsyncVoiceUiState.recording) return;
    _stopTimers();
    _state = AsyncVoiceUiState.working;
    notifyListeners();
    final jobId = _jobId;
    RecordedClip? clip;
    try {
      clip = await _recorder.stop();
    } catch (_) {
      clip = null;
    }
    if (jobId == null || clip == null) {
      _resetToIdle();
      return;
    }
    try {
      if (clip.sizeBytes < _minClipBytes) {
        await _recorder.discard(clip.path);
        _resetToIdle();
        return;
      }
      await _queue.enqueue(jobId, File(clip.path));
    } catch (_) {
      _error = "Couldn't queue that recording. Please try again.";
      _resetToIdle();
      return;
    }
    // Working until the queue finishes this job (or drops it).
    _queue.addListener(_onQueueChanged);
    _onQueueChanged();
  }

  /// Give up on the in-progress recording (release outside the button,
  /// sheet dismissed mid-record): nothing is queued or sent.
  Future<void> cancelRecording() async {
    if (_state != AsyncVoiceUiState.recording) return;
    _stopTimers();
    try {
      await _recorder.cancel();
    } catch (_) {}
    await _deleteTemp();
    _resetToIdle();
  }

  void _onQueueChanged() {
    if (_disposed || _state != AsyncVoiceUiState.working) return;
    final jobId = _jobId;
    if (jobId == null) return;
    final gone =
        _queue.jobStatuses[jobId] == null &&
        !_queue.items.any((m) => m.jobId == jobId);
    if (gone) {
      _queue.removeListener(_onQueueChanged);
      _resetToIdle();
    } else {
      notifyListeners(); // stage advanced — the loader follows
    }
  }

  void _stopTimers() {
    _ticker?.cancel();
    _ticker = null;
    _capTimer?.cancel();
    _capTimer = null;
  }

  Future<void> _deleteTemp() async {
    final temp = _tempPath;
    _tempPath = null;
    if (temp == null) return;
    await _recorder.discard(temp);
  }

  void _resetToIdle() {
    _stopTimers();
    _tempPath = null;
    _jobId = null;
    _elapsed = Duration.zero;
    _startedAt = null;
    if (_state != AsyncVoiceUiState.idle) {
      _state = AsyncVoiceUiState.idle;
      notifyListeners();
    }
  }

  /// A finished wav header alone is 44 bytes — anything under 1KB is a tap,
  /// not a message.
  static const _minClipBytes = 1024;

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _queue.removeListener(_onQueueChanged);
    _recorder.dispose();
    super.dispose();
  }
}
