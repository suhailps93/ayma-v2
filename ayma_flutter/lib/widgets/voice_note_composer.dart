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
/// Pointer handling is RAW ([Listener] + a dwell timer), not a
/// [GestureDetector] long-press (founder defect, 2026-11-06 ~19:43 PT:
/// on his phone the long-press recognizer delivered no usable move
/// updates once the recording bar was up — sliding left never armed
/// cancel and the bar rendered static, while the bench's synthetic
/// dwell-then-slide passed). A raw listener hears every move of the
/// pointer that went down on this button, measured from the pointer-down
/// point, independent of the gesture arena and of anything the recording
/// bar paints above the row. Deliberately NOT a [Tooltip]/[InkWell]
/// either: their recognizers compete for the same pointer.
class VoiceNoteMicButton extends StatefulWidget {
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
  State<VoiceNoteMicButton> createState() => _VoiceNoteMicButtonState();
}

class _VoiceNoteMicButtonState extends State<VoiceNoteMicButton> {
  /// Dwell before a press becomes a hold — the same 500 ms the
  /// long-press recognizer used, so tap vs hold feels unchanged.
  static const Duration _holdDelay = Duration(milliseconds: 500);

  /// Drift allowed during the dwell before the press stops being a
  /// hold/tap candidate (a finger swiping through is neither).
  static const double _dwellSlop = 24;

  int? _pointer;
  Offset? _downPosition;
  Timer? _holdTimer;
  bool _holding = false;
  bool _tapEligible = true;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) return; // first finger only
    // A voice note is already recording (this is a fresh touch, e.g. a
    // tap while locked): the mic is inert until the note resolves.
    if (widget.controller.isActive) return;
    _pointer = event.pointer;
    _downPosition = event.position;
    _holding = false;
    _tapEligible = true;
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdDelay, _fireHold);
  }

  void _fireHold() {
    if (_pointer == null || _holding) return;
    _holding = true;
    unawaited(widget.controller.handleHoldStart());
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downPosition == null) return;
    final offset = event.position - _downPosition!;
    if (!_holding) {
      if (offset.distance > _dwellSlop) {
        // Moving away during the dwell: not a hold, and no longer a tap
        // either — the recognizer pair this replaces rejected both too.
        _holdTimer?.cancel();
        _tapEligible = false;
      }
      return;
    }
    widget.controller.handleDragUpdate(offset);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final wasHolding = _holding;
    final tap = _tapEligible && !_holding;
    _resetPointer();
    if (wasHolding) {
      unawaited(widget.controller.handleHoldEnd());
    } else if (tap) {
      widget.onTap?.call();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    final wasHolding = _holding;
    _resetPointer();
    if (wasHolding) {
      unawaited(widget.controller.handleHoldCancel());
    }
  }

  void _resetPointer() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _pointer = null;
    _downPosition = null;
    _holding = false;
    _tapEligible = true;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Voice message. Hold to record.',
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            // Bubble-up (founder, 2026-11-06): while this mic's note is
            // recording, the button itself swells and lights accent -
            // visible proof the hold registered, before any slide. The
            // composers leave the mic slot uncovered by the recording
            // bar so this stays on screen for the whole hold.
            final active = widget.controller.isActive;
            final ac = context.ac;
            return AnimatedScale(
              scale: active ? 1.22 : 1.0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? ac.accent : widget.background,
                ),
                child: Icon(
                  active ? Icons.mic_rounded : Icons.mic_none_rounded,
                  size: 20,
                  color: active ? ac.onAccent : widget.foreground,
                ),
              ),
            );
          },
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

  static const double _width = 30;
  static const double _height = 52;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final p = progress.clamp(0.0, 1.0);
    final fillColor = Color.lerp(ac.bgElev, ac.accent, p * 0.85)!;
    final borderColor = Color.lerp(ac.fgDim, ac.accent, p)!;
    final iconColor = Color.lerp(ac.fgDim, ac.accent, p)!;
    return Transform.translate(
      // The bubble lifts toward the finger as the slide progresses.
      offset: Offset(0, -10 * p),
      child: Container(
        key: const ValueKey('voiceNoteLockBubble'),
        width: _width,
        height: _height,
        decoration: BoxDecoration(
          // Solid at rest - a small filled pill riding the bar's right
          // end, never a big hollow oval (founder, 2026-11-06 ~19:51).
          color: ac.bgCard,
          borderRadius: BorderRadius.circular(_width / 2),
          border: Border.all(color: borderColor, width: 1.2),
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
                  color: fillColor.withValues(alpha: 0.45 + 0.5 * p),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    size: 15,
                    color: iconColor,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Transform.scale(
                      scale: 1 + 0.3 * p,
                      child: Icon(
                        // Filled lock once the slide is most of the way.
                        p >= 0.6
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        size: 14,
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

/// The recording dot in the holding bar: pulses while the mic is live so
/// the hold state never renders as a static strip (founder, 2026-11-06).
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_pulse),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AymaColors.error,
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
    // WhatsApp tracking: the whole bar content leans left with the
    // finger as it slides toward cancel (capped), so the slide is felt
    // in the bar itself, not just in a label.
    final lean = (controller.dragOffset.dx < 0 ? controller.dragOffset.dx : 0.0)
        * 0.35;
    return Container(
      key: const ValueKey('voiceNoteRecordingBar'),
      color: ac.bg,
      constraints: const BoxConstraints(minHeight: 64),
      child: Transform.translate(
        offset: Offset(lean < -48 ? -48 : lean, 0),
        child: Row(
        children: [
          Expanded(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _PulsingDot(),
                  const SizedBox(width: 8),
                  Text(elapsed, style: AymaType.mono(size: 14, color: ac.fg)),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      cancelArmed ? 'Release to cancel' : 'Release to send',
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: AymaType.sans(
                        size: 13,
                        color: cancelArmed ? AymaColors.error : ac.fgMute,
                      ),
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
          ),
          Transform.translate(
            // The cancel cluster leans toward the finger as it slides
            // left, and a trash glyph grows in as cancel nears.
            offset: Offset(-24 * cancelProgress, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: cancelProgress,
                  child: Transform.scale(
                    scale: 0.6 + 0.4 * cancelProgress,
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 19,
                      color: cancelArmed ? AymaColors.error : ac.fgDim,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
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
