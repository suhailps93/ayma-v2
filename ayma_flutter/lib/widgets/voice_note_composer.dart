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

/// The WhatsApp-style lock bubble shown while holding to record
/// (founder, 2026-11-06: "slide up to lock is not clear — make it more
/// interactive"). A vertical pill at the right end of the recording bar:
/// as the finger slides up it RISES and FILLS with accent, its chevron
/// and lock glyph light up, and at full progress the lock engages (the
/// bar snaps to the locked controls). [progress] is 0 at rest and 1 at
/// the lock threshold.
class VoiceNoteLockBubble extends StatelessWidget {
  const VoiceNoteLockBubble({super.key, required this.progress});

  /// Upward slide progress toward locking, 0..1.
  final double progress;

  static const double _width = 38;
  static const double _height = 56;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final p = progress.clamp(0.0, 1.0);
    final fillColor = Color.lerp(ac.bgElev, ac.accent, p * 0.85)!;
    final borderColor = Color.lerp(ac.fgMute, ac.accent, p)!;
    final iconColor = Color.lerp(ac.fgMute, ac.accent, p)!;
    return Transform.translate(
      // The bubble lifts toward the finger as the slide progresses.
      offset: Offset(0, -12 * p),
      child: Container(
        key: const ValueKey('voiceNoteLockBubble'),
        width: _width,
        height: _height,
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(_width / 2),
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_width / 2),
          child: Stack(
            children: [
              // Accent fill rising from the bottom with drag progress.
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: _width,
                  height: _height * p,
                  color: fillColor.withValues(alpha: 0.35 + 0.45 * p),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 17,
                    color: iconColor,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Transform.scale(
                      scale: 1 + 0.3 * p,
                      child: Icon(
                        // Filled lock once the slide is most of the way.
                        p >= 0.6
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        size: 17,
                        color: iconColor,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The recording bar that replaces the composer row while a voice note is
/// being recorded (WhatsApp model, founder 2026-11-06):
///
/// - holding: red dot, live timer, "Release to send", a "Slide to cancel"
///   affordance that leans in and lights up (with "Release to cancel")
///   as the finger slides left, a "Slide up to lock" hint, and the
///   [VoiceNoteLockBubble] that rises and fills as the finger slides up;
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
          return _LockedBar(controller: controller, elapsed: elapsed);
        }
        return _holdingBar(context, ac, elapsed);
      },
    );
  }

  Widget _holdingBar(BuildContext context, AymaTokens ac, String elapsed) {
    final cancelArmed = controller.cancelArmed;
    final lockProgress = controller.lockProgress;
    final cancelProgress = controller.cancelProgress;
    return Container(
      key: const ValueKey('voiceNoteRecordingBar'),
      color: ac.bg,
      constraints: const BoxConstraints(minHeight: 68),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
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
                ],
              ),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 15,
                    color: Color.lerp(ac.fgMute, ac.accent, lockProgress),
                  ),
                  Text(
                    'Slide up to lock',
                    style: AymaType.sans(
                      size: 12,
                      color: Color.lerp(ac.fgMute, ac.accent, lockProgress),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          Transform.translate(
            // The cancel label leans toward the finger as it slides left.
            offset: Offset(-10 * cancelProgress, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
              ],
            ),
          ),
          const SizedBox(width: 10),
          VoiceNoteLockBubble(progress: lockProgress),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// The locked recording bar: timer, DELETE, PAUSE/RESUME, SEND. Mounts
/// the moment a slide-up lock engages, so its lock icon plays a one-shot
/// snap (scale punch) as the hands-free state takes over.
class _LockedBar extends StatefulWidget {
  const _LockedBar({required this.controller, required this.elapsed});

  final VoiceNoteController controller;
  final String elapsed;

  @override
  State<_LockedBar> createState() => _LockedBarState();
}

class _LockedBarState extends State<_LockedBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();
  late final Animation<double> _scale = Tween<double>(begin: 1.6, end: 1.0)
      .animate(CurvedAnimation(parent: _snap, curve: Curves.easeOutBack));

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final controller = widget.controller;
    final paused = controller.engine.isPaused;
    // F3: the recording hit the cap and stopped, holding the clip unsent.
    // The bar stays up in a stopped state — no recording dot, no pause —
    // until the user explicitly sends or deletes.
    final stopped = controller.engine.hasCapHeldClip;
    return Container(
      key: const ValueKey('voiceNoteRecordingBar'),
      color: ac.bg,
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          ScaleTransition(
            scale: _scale,
            child: Icon(Icons.lock_rounded, size: 18, color: ac.accent),
          ),
          const SizedBox(width: 8),
          if (!paused && !stopped)
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AymaColors.error,
              ),
            ),
          if (!paused && !stopped) const SizedBox(width: 8),
          Text(widget.elapsed, style: AymaType.mono(size: 14, color: ac.fg)),
          const SizedBox(width: 10),
          Text(
            stopped ? 'Stopped' : (paused ? 'Paused' : 'Recording'),
            style: AymaType.sans(size: 13, color: ac.fgMute),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('voiceNoteDeleteButton'),
            tooltip: 'Delete recording',
            onPressed: () => unawaited(controller.discardLocked()),
            icon: Icon(Icons.delete_outline_rounded, color: ac.fgDim),
          ),
          if (!stopped)
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
