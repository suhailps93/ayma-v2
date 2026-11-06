import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_clip_registry.dart';
import 'voice_session_controller.dart';

/// How one `play_voice_clip` command turned out at the moment playback
/// started — what the command's ack reports back to the backend tool.
@immutable
class PlaybackStart {
  const PlaybackStart({
    required this.ok,
    required this.voicePaused,
    required this.message,
  });

  const PlaybackStart.failed(this.message)
      : ok = false,
        voicePaused = false;

  final bool ok;

  /// True when a live voice session was disconnected to play the clip
  /// (it is reconnected once the clip finishes — see [VoiceClipPlayback]).
  final bool voicePaused;

  /// The honest one-liner the backend tool relays: what is playing.
  final String message;
}

/// Plays a voice clip for Ayma, following the founder's sanctioned
/// pattern for a live voice call (2026-11-06, feedback items 7+8):
///
/// 1. Ayma announces it herself (her tool description tells her to say
///    she is pausing to play the clip before calling the tool; the
///    [announceGrace] delay here lets that line finish before the room
///    drops);
/// 2. the voice session **disconnects** — playback never runs inside
///    the LiveKit room, which is what used to kill the call silently;
/// 3. the clip plays on the chat's own player;
/// 4. the **same** session reconnects (`stop()` then `start()` on the
///    one controller, the reconnect_voice shape), seeded with context:
///    a resume note is attached to the next `/bootstrap` recent-turns,
///    so the reconnected Ayma knows she disconnected to play the clip,
///    which clip it was, and that it has finished.
///
/// With no live session, the clip simply plays.
///
/// Every step is injectable so the sequence is unit-testable with a
/// fake session. The defaults act on [VoiceSessionController.active].
class VoiceClipPlayback {
  VoiceClipPlayback({
    VoiceSessionController? Function()? activeSession,
    Future<void> Function(VoiceSessionController session)? stopSession,
    Future<void> Function(VoiceSessionController session)? startSession,
    void Function(VoiceSessionController session, String note)? noteResume,
    this.announceGrace = const Duration(milliseconds: 1200),
    this.pollInterval = const Duration(milliseconds: 100),
    this.startWait = const Duration(seconds: 2),
    this.maxPlayWait = const Duration(minutes: 3),
  })  : _activeSession =
            activeSession ?? (() => VoiceSessionController.active),
        _stopSession = stopSession ?? ((s) => s.stop()),
        _startSession = startSession ?? ((s) => s.start()),
        _noteResume = noteResume ??
            ((s, note) => s.noteResumeContext(note));

  final VoiceSessionController? Function() _activeSession;
  final Future<void> Function(VoiceSessionController session) _stopSession;
  final Future<void> Function(VoiceSessionController session) _startSession;
  final void Function(VoiceSessionController session, String note) _noteResume;

  /// Grace between Ayma's spoken announcement and the disconnect, so
  /// the announcement is heard before the room drops (the same reason
  /// `reconnect_voice` waits before tearing down).
  final Duration announceGrace;

  /// How often the clip's playing state is polled while waiting for it
  /// to finish.
  final Duration pollInterval;

  /// How long to wait for playback to register as started before
  /// concluding it finished instantly (a very short clip) or failed to
  /// start.
  final Duration startWait;

  /// Hard cap on waiting for a clip to finish before reconnecting
  /// anyway — a stuck player state must never strand the user without
  /// their call. Voice notes are capped at 120 seconds on record, so
  /// three minutes is generous headroom for a spoken reply.
  final Duration maxPlayWait;

  /// The resume note seeded into the reconnected session's context.
  /// Phrased as Ayma's own recollection, because that is how the
  /// `/bootstrap` recent-turns window reads to her.
  static String resumeNote(VoiceClipHandle clip) =>
      'You disconnected from the voice call just now to play '
      '${clip.label} for the user. The clip has finished playing. '
      'You are now reconnected — continue the conversation from where '
      'it left off, and mention the clip naturally if it is relevant.';

  /// Begin playing [clip]. [started] completes once playback has
  /// begun (or honestly failed) — that is what the command acks.
  /// [done] completes when the whole sequence is over: the clip has
  /// finished and, if a session was paused, it has been reconnected
  /// (or the reconnect attempt has failed — the chat surface's own
  /// error handling owns that state from there).
  ({Future<PlaybackStart> started, Future<void> done}) begin(
      VoiceClipHandle clip) {
    final done = Completer<void>();
    final started = _run(clip, done);
    return (started: started, done: done.future);
  }

  Future<PlaybackStart> _run(
      VoiceClipHandle clip, Completer<void> done) async {
    final session = _activeSession();
    final paused = session != null && session.isActive;
    if (!paused) {
      try {
        await clip.start();
      } catch (e) {
        debugPrint('Ayma play_voice_clip failed to start: $e');
        done.complete();
        return PlaybackStart.failed(
            'The clip could not be played on this phone.');
      }
      unawaited(_finish(clip, null, done));
      return PlaybackStart(
        ok: true,
        voicePaused: false,
        message: 'Playing ${clip.label} now.',
      );
    }
    // Live call: announce grace → note the context → disconnect → play.
    await Future<void>.delayed(announceGrace);
    _noteResume(session, resumeNote(clip));
    try {
      await _stopSession(session);
    } catch (e) {
      debugPrint('Ayma play_voice_clip: voice stop failed: $e');
      done.complete();
      return PlaybackStart.failed(
          'The voice call could not be paused to play the clip.');
    }
    try {
      await clip.start();
    } catch (e) {
      debugPrint('Ayma play_voice_clip failed to start: $e');
      // The call is already down — bring Ayma back before reporting.
      unawaited(_finish(clip, session, done, waitForClip: false));
      return PlaybackStart.failed(
          'The clip could not be played; Ayma is reconnecting.');
    }
    unawaited(_finish(clip, session, done));
    return PlaybackStart(
      ok: true,
      voicePaused: true,
      message: 'Playing ${clip.label} now. Ayma disconnected to play '
          'it and will reconnect when it finishes.',
    );
  }

  /// Wait for the clip to finish, then reconnect the paused session.
  Future<void> _finish(
    VoiceClipHandle clip,
    VoiceSessionController? session,
    Completer<void> done, {
    bool waitForClip = true,
  }) async {
    try {
      if (waitForClip) await _awaitFinished(clip);
      if (session != null) {
        try {
          await _startSession(session);
        } catch (e) {
          debugPrint('Ayma play_voice_clip: voice restart failed: $e');
        }
      }
    } finally {
      if (!done.isCompleted) done.complete();
    }
  }

  /// Poll until the clip reports not-playing. First waits (briefly)
  /// for playback to register as started, so a clip that takes a
  /// moment to buffer is not mistaken for finished; a clip that never
  /// registers as playing is treated as finished/failed rather than
  /// waited on.
  Future<void> _awaitFinished(VoiceClipHandle clip) async {
    final startDeadline = DateTime.now().add(startWait);
    while (!clip.isPlaying()) {
      if (DateTime.now().isAfter(startDeadline)) return;
      await Future<void>.delayed(pollInterval);
    }
    final deadline = DateTime.now().add(maxPlayWait);
    while (clip.isPlaying()) {
      if (DateTime.now().isAfter(deadline)) {
        try {
          await clip.stop();
        } catch (_) {
          // A stuck player is not worth stranding the reconnect over.
        }
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}
