import 'dart:async';

import 'package:flutter/material.dart';

import '../services/voice_note_controller.dart';
import '../theme.dart';

/// The WhatsApp-style mic button that sits in the composer's send slot
/// while the input is empty (founder, 2026-11-06).
///
/// A tap goes to [onTap] (the Ayma chat starts a live voice call; the DM
/// chat shows a hold hint). A press-and-hold drives [controller]: hold to
/// record, slide left to arm cancel, slide up to lock, release to send.
///
/// Deliberately NOT wrapped in a [Tooltip] and NOT an [InkWell]: both run
/// their own long-press recognizers that would win the gesture arena over
/// the slide-tracking detector and the hold would never be seen whole.
class VoiceNoteMicButton extends StatelessWidget {
  const VoiceNoteMicButton({
    super.key,
    required this.controller,
    required this.background,
    required this.foreground,
    this.onTap,
    this.size = 44,
  });

  final VoiceNoteController controller;
  final VoidCallback? onTap;
  final Color background;
  final Color foreground;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Voice message. Hold to record.',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPressStart: (_) => unawaited(controller.handleHoldStart()),
        onLongPressMoveUpdate: (details) =>
            controller.handleDragUpdate(details.offsetFromOrigin),
        onLongPressEnd: (_) => unawaited(controller.handleHoldEnd()),
        onLongPressCancel: () => unawaited(controller.handleHoldCancel()),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: background),
          child: Icon(Icons.mic_none_rounded, size: 20, color: foreground),
        ),
      ),
    );
  }
}

/// The recording bar that replaces the composer row while a voice note is
/// being recorded (WhatsApp model, founder 2026-11-06):
///
/// - holding: red dot, live timer, "Release to send", a "Slide to cancel"
///   affordance that lights up (with "Release to cancel") once the finger
///   is in the cancel zone, and a lock hint;
/// - locked: lock icon, live timer, DELETE (discard), PAUSE/RESUME and
///   SEND controls.
///
/// Sized to the composer row it replaces; renders nothing while idle.
class VoiceNoteRecordingBar extends StatelessWidget {
  const VoiceNoteRecordingBar({super.key, required this.controller});

  final VoiceNoteController controller;

  static String clock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.engine]),
      builder: (context, _) {
        if (!controller.isActive) return const SizedBox.shrink();
        final ac = context.ac;
        final elapsed = clock(controller.engine.elapsed);
        if (controller.phase == VoiceNotePhase.locked) {
          return _lockedBar(context, ac, elapsed);
        }
        return _holdingBar(context, ac, elapsed);
      },
    );
  }

  Widget _holdingBar(BuildContext context, AymaTokens ac, String elapsed) {
    final cancelArmed = controller.cancelArmed;
    return Container(
      key: const ValueKey('voiceNoteRecordingBar'),
      color: ac.bg,
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AymaColors.error,
            ),
          ),
          const SizedBox(width: 8),
          Text(elapsed, style: AymaType.mono(size: 14, color: ac.fg)),
          const SizedBox(width: 10),
          Text(
            cancelArmed ? 'Release to cancel' : 'Release to send',
            style: AymaType.sans(
              size: 13,
              color: cancelArmed ? AymaColors.error : ac.fgMute,
            ),
          ),
          const Spacer(),
          Icon(
            Icons.chevron_left_rounded,
            size: 18,
            color: cancelArmed ? AymaColors.error : ac.fgMute,
          ),
          Text(
            'Slide to cancel',
            style: AymaType.sans(
              size: 13,
              color: cancelArmed ? AymaColors.error : ac.fgMute,
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.lock_outline_rounded, size: 16, color: ac.fgMute),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _lockedBar(BuildContext context, AymaTokens ac, String elapsed) {
    final paused = controller.engine.isPaused;
    return Container(
      key: const ValueKey('voiceNoteRecordingBar'),
      color: ac.bg,
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          Icon(Icons.lock_rounded, size: 16, color: ac.accent),
          const SizedBox(width: 8),
          if (!paused)
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AymaColors.error,
              ),
            ),
          if (!paused) const SizedBox(width: 8),
          Text(elapsed, style: AymaType.mono(size: 14, color: ac.fg)),
          const SizedBox(width: 10),
          Text(
            paused ? 'Paused' : 'Recording',
            style: AymaType.sans(size: 13, color: ac.fgMute),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('voiceNoteDeleteButton'),
            tooltip: 'Delete recording',
            onPressed: () => unawaited(controller.discardLocked()),
            icon: Icon(Icons.delete_outline_rounded, color: ac.fgDim),
          ),
          IconButton(
            key: const ValueKey('voiceNotePauseButton'),
            tooltip: paused ? 'Resume recording' : 'Pause recording',
            onPressed: () => unawaited(controller.togglePause()),
            icon: Icon(
              paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: ac.fgDim,
            ),
          ),
          IconButton(
            key: const ValueKey('voiceNoteSendButton'),
            tooltip: 'Send voice message',
            onPressed: () => unawaited(controller.sendLocked()),
            icon: Icon(Icons.send_rounded, color: ac.accent),
          ),
        ],
      ),
    );
  }
}
