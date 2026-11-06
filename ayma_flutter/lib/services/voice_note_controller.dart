import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// The recording engine behind the WhatsApp-style voice-note composer.
///
/// One engine per chat surface: the Ayma chat's engine is the existing
/// [AsyncVoiceController] (record → queue → upload → Ayma understands in
/// the background); the DM chat's engine records → uploads → posts a
/// `voice` DM (the server transcribes for ingestion in the background).
/// In both, "send" means the clip leaves as a playable bubble immediately —
/// transcription/understanding never gates delivery.
abstract class VoiceNoteEngine extends ChangeNotifier {
  /// True while the microphone is capturing (including while paused).
  bool get isRecording;

  /// True while a locked recording is paused.
  bool get isPaused;

  /// How long the current recording has run, excluding paused spans.
  Duration get elapsed;

  /// Longest single voice note before the engine stops and sends itself.
  Duration get maxClipDuration;

  /// A one-shot recording failure for the UI to surface — cleared once read.
  String? takeError();

  /// Take the mic and start recording. False when recording cannot start
  /// ([takeError] says why) — the composer stays idle.
  Future<bool> startRecording();

  /// Stop the recorder and send the clip now (playable bubble immediately;
  /// any transcription happens later, in the background).
  Future<void> sendRecording();

  /// Stop the recorder and discard the clip — nothing is sent.
  Future<void> cancelRecording();

  /// Pause a (locked) recording; the elapsed clock stops too.
  Future<void> pauseRecording();

  /// Resume a paused recording.
  Future<void> resumeRecording();
}

/// The composer's gesture phases for a voice note (WhatsApp model).
enum VoiceNotePhase {
  /// No recording — the composer shows its normal text row.
  idle,

  /// The user is holding the mic. Slide left arms cancel, slide up locks;
  /// releasing sends (or cancels, when cancel is armed).
  holding,

  /// Recording hands-free after a slide-up lock. The composer shows the
  /// locked bar: timer, delete, pause/resume, send.
  locked,
}

/// The WhatsApp voice-note state machine shared by the Ayma chat composer
/// and the DM chat composer.
///
/// Gesture contract (founder, 2026-11-06):
/// - press-and-hold the mic → recording starts ([VoiceNotePhase.holding]);
/// - slide LEFT past [cancelSlideDistance] → cancel is armed; releasing
///   discards the clip, nothing is sent;
/// - slide UP past [lockSlideDistance] → the recording locks
///   ([VoiceNotePhase.locked]) and continues hands-free after release;
/// - release while holding (neither armed) → the clip sends immediately;
/// - locked: DELETE discards, PAUSE/RESUME hold the recorder, SEND sends.
class VoiceNoteController extends ChangeNotifier {
  VoiceNoteController({
    required this.engine,
    this.canStart,
    this.onStartRefused,
  }) {
    engine.addListener(_onEngineChanged);
  }

  /// The recording/delivery engine for this chat surface.
  final VoiceNoteEngine engine;

  /// Optional gate checked before a hold starts recording (the Ayma chat
  /// refuses while a live voice call owns the mic). Null always allows.
  final bool Function()? canStart;

  /// Called when [canStart] refuses a hold, so the UI can explain why.
  final VoidCallback? onStartRefused;

  /// Horizontal slide (logical px, leftwards) that arms cancel.
  static const double cancelSlideDistance = 70;

  /// Vertical slide (logical px, upwards) that locks the recording.
  static const double lockSlideDistance = 70;

  VoiceNotePhase _phase = VoiceNotePhase.idle;
  VoiceNotePhase get phase => _phase;

  /// True in any non-idle phase — the recording bar replaces the composer.
  bool get isActive => _phase != VoiceNotePhase.idle;

  bool _cancelArmed = false;

  /// While holding, whether the finger has slid into the cancel zone.
  bool get cancelArmed => _cancelArmed;

  bool _lockArmed = false;

  /// While holding, whether the finger has slid into the lock zone (the
  /// lock itself engages the moment this arms — see [handleDragUpdate]).
  bool get lockArmed => _lockArmed;

  bool _disposed = false;

  void _onEngineChanged() {
    if (_disposed) return;
    // The engine stopping on its own (max-duration auto-send, an error)
    // ends whatever gesture phase we were in.
    if (!engine.isRecording && _phase != VoiceNotePhase.idle) {
      _phase = VoiceNotePhase.idle;
      _cancelArmed = false;
      _lockArmed = false;
    }
    notifyListeners();
  }

  /// The mic hold registered: start recording unless gated or busy.
  Future<void> handleHoldStart() async {
    if (_phase != VoiceNotePhase.idle) return;
    if (canStart != null && !canStart!()) {
      onStartRefused?.call();
      return;
    }
    final started = await engine.startRecording();
    if (_disposed) return;
    if (started) {
      _phase = VoiceNotePhase.holding;
      _cancelArmed = false;
      _lockArmed = false;
      notifyListeners();
    }
  }

  /// The held finger moved by [offsetFromStart] (cumulative, logical px;
  /// left/up are negative). Updates the cancel arm and engages the lock.
  void handleDragUpdate(Offset offsetFromStart) {
    if (_phase != VoiceNotePhase.holding) return;
    final armed = offsetFromStart.dx <= -cancelSlideDistance;
    if (armed != _cancelArmed) {
      _cancelArmed = armed;
      notifyListeners();
    }
    if (offsetFromStart.dy <= -lockSlideDistance && !_lockArmed) {
      _lockArmed = true;
      _phase = VoiceNotePhase.locked;
      _cancelArmed = false;
      notifyListeners();
    }
  }

  /// The held finger was released. In [VoiceNotePhase.holding] this sends
  /// the clip — or discards it when cancel is armed. Once locked, release
  /// is a no-op: recording continues hands-free.
  Future<void> handleHoldEnd() async {
    if (_phase == VoiceNotePhase.locked) return;
    if (_phase != VoiceNotePhase.holding) return;
    final cancel = _cancelArmed;
    _phase = VoiceNotePhase.idle;
    _cancelArmed = false;
    _lockArmed = false;
    notifyListeners();
    if (cancel) {
      await engine.cancelRecording();
    } else {
      await engine.sendRecording();
    }
  }

  /// The hold gesture itself was cancelled by the framework (pointer
  /// cancelled, widget unmounted mid-hold). While still holding, that is a
  /// discard — the user never chose to send. Once locked it is a no-op.
  Future<void> handleHoldCancel() async {
    if (_phase != VoiceNotePhase.holding) return;
    _phase = VoiceNotePhase.idle;
    _cancelArmed = false;
    _lockArmed = false;
    notifyListeners();
    await engine.cancelRecording();
  }

  /// Locked bar: discard the recording — nothing is sent.
  Future<void> discardLocked() async {
    if (_phase != VoiceNotePhase.locked) return;
    _phase = VoiceNotePhase.idle;
    notifyListeners();
    await engine.cancelRecording();
  }

  /// Locked bar: send the recording now.
  Future<void> sendLocked() async {
    if (_phase != VoiceNotePhase.locked) return;
    _phase = VoiceNotePhase.idle;
    notifyListeners();
    await engine.sendRecording();
  }

  /// Locked bar: pause/resume the recording.
  Future<void> togglePause() async {
    if (_phase != VoiceNotePhase.locked) return;
    if (engine.isPaused) {
      await engine.resumeRecording();
    } else {
      await engine.pauseRecording();
    }
    if (!_disposed) notifyListeners();
  }

  /// A one-shot engine error for the UI to surface — cleared once read.
  String? takeError() => engine.takeError();

  @override
  void dispose() {
    _disposed = true;
    engine.removeListener(_onEngineChanged);
    super.dispose();
  }
}
