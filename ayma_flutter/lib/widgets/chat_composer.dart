import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// The three visual states the unified chat composer can be in. It is always
/// the same widget morphing between them — never three separate composers
/// appearing/disappearing.
enum ComposerMode {
  /// Idle chat input: mic · text field · attach · send.
  text,

  /// A voice call is live and the user's mic is the active side: mic ·
  /// status label · stop, with the composer's bottom border animating.
  listening,

  /// A voice call is live and Ayma is talking: mic · status label · stop,
  /// with the composer's top border animating (dipping into the box).
  aiSpeaking,
}

/// The single input surface anchoring the bottom of the Ayma chat screen.
///
/// One rounded composer plays all three roles in [ComposerMode] — the outer
/// shape, position and (aside from voice-mode's centred label swapping in for
/// the text field) height never jump between them. The composer's own border
/// carries a filled peach wave along the bottom while the user speaks and
/// along the top while Ayma speaks. Both waves stay inside the rounded frame.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.mode,
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.onSend,
    required this.onAttach,
    required this.onMicPressed,
    required this.onStopPressed,
    required this.onMuteTap,
    required this.muted,
    required this.userAmplitude,
    required this.aiAmplitude,
    this.statusLabel,
  });

  final ComposerMode mode;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Text mode only — whether the send button is enabled.
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  /// Text mode's mic button — starts a voice session.
  final VoidCallback onMicPressed;

  /// Voice modes' stop button — ends the live voice session.
  final VoidCallback onStopPressed;

  /// Voice modes' mic button — toggles mute.
  final VoidCallback onMuteTap;
  final bool muted;

  /// Normalised 0..1, already-smoothed audio levels, fed straight from
  /// `VoiceSessionController.micLevel` / `.aymaLevel` — no parallel amplitude
  /// pipeline. [userAmplitude] drives the bottom-edge wave in
  /// [ComposerMode.listening]; [aiAmplitude] drives the top-edge wave in
  /// [ComposerMode.aiSpeaking].
  final ValueListenable<double> userAmplitude;
  final ValueListenable<double> aiAmplitude;

  /// Centre label for the voice modes ("Listening…", "Ayma is speaking…",
  /// "Connecting…", "Muted", …). Ignored in [ComposerMode.text].
  final String? statusLabel;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with SingleTickerProviderStateMixin {
  AnimationController? _phase;

  // Eased pixel amplitudes + wave speeds for the two edges, stepped once per
  // animation tick toward their targets — same shape as VoiceWaveBar's own
  // _step(), just scaled down to a subtle border ripple (peak ~10px) instead
  // of a full-bleed bar.
  double _topAmp = 0;
  double _botAmp = 0;
  double _topSpeed = 1;
  double _botSpeed = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _phase?.dispose();
      _phase = null;
    } else if (_phase == null) {
      // Not auto-repeating: idle text mode never needs a ticker at all, so a
      // fresh composer starts fully at rest. [_syncTicker] starts it the
      // moment a voice mode actually needs the wave.
      _phase = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 5),
      );
      _syncTicker();
    }
  }

  @override
  void didUpdateWidget(covariant ChatComposer old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) _syncTicker();
  }

  /// Starts the ticker the moment a voice mode needs the wave; leaves it
  /// running on the way back to text mode so [_step] can ease the amplitude
  /// down to flat instead of snapping — [_step] is the one that stops it,
  /// once both edges have actually settled.
  void _syncTicker() {
    final phase = _phase;
    if (phase == null) return;
    if (widget.mode != ComposerMode.text && !phase.isAnimating) {
      phase.repeat();
    }
  }

  @override
  void dispose() {
    _phase?.dispose();
    super.dispose();
  }

  double _targetAmp(double level, bool active) {
    if (!active) return 0;
    final l = level.clamp(0.0, 1.0);
    // Silence reads as almost flat; a loud voice reads as a gentle ~9-10px
    // crest — clamped well short of anything that reads as an audio-bar
    // visualizer (§ spec "elegant and subtle rather than an audio visualizer").
    return (0.6 + l * 9.0).clamp(0.0, 10.0);
  }

  void _step() {
    final userActive = widget.mode == ComposerMode.listening;
    final aiActive = widget.mode == ComposerMode.aiSpeaking;
    final topTarget = _targetAmp(widget.aiAmplitude.value, aiActive);
    final botTarget = _targetAmp(widget.userAmplitude.value, userActive);
    final aiL = widget.aiAmplitude.value.clamp(0.0, 1.0);
    final micL = widget.userAmplitude.value.clamp(0.0, 1.0);
    final topSpeedTarget = 0.7 + aiL * aiL * 1.1;
    final botSpeedTarget = 0.9 + micL * 2.3;
    const k = 0.14; // per-frame lerp toward target — smooth, no hard snap
    _topAmp = lerpDouble(_topAmp, topTarget, k)!;
    _botAmp = lerpDouble(_botAmp, botTarget, k)!;
    _topSpeed = lerpDouble(_topSpeed, topSpeedTarget, k)!;
    _botSpeed = lerpDouble(_botSpeed, botSpeedTarget, k)!;

    // Both edges have eased back to flat and we're not waiting on a voice
    // mode any more — stop the ticker instead of spinning forever with
    // nothing to animate (keeps idle text mode fully at rest).
    const settled = 0.05;
    if (widget.mode == ComposerMode.text &&
        _topAmp < settled &&
        _botAmp < settled) {
      _topAmp = 0;
      _botAmp = 0;
      _phase?.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final phase = _phase;
    final voiceMode = widget.mode != ComposerMode.text;

    final content = Padding(
      key: ValueKey(voiceMode),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: voiceMode ? _voiceRow(ac) : _textRow(ac),
    );

    final switched = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: content,
    );

    final painted = phase == null
        ? _StaticFrame(
            lineColor: ac.lineSoft,
            fillColor: ac.bg,
            child: switched,
          )
        : AnimatedBuilder(
            animation: Listenable.merge([
              phase,
              widget.userAmplitude,
              widget.aiAmplitude,
            ]),
            builder: (context, child) {
              _step();
              return CustomPaint(
                painter: _ComposerBorderPainter(
                  lineColor: ac.lineSoft,
                  fillColor: ac.bg,
                  waveColor: ac.accent,
                  topAmp: _topAmp,
                  botAmp: _botAmp,
                  topSpeed: _topSpeed,
                  botSpeed: _botSpeed,
                  phase: phase.value,
                ),
                child: child,
              );
            },
            child: switched,
          );

    return RepaintBoundary(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        child: painted,
      ),
    );
  }

  Widget _textRow(AymaTokens ac) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _RoundIconButton(
          icon: Icons.mic_none_rounded,
          tooltip: 'Talk to Ayma',
          background: ac.bgElev,
          foreground: ac.fgDim,
          onPressed: widget.onMicPressed,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: AymaType.sans(size: 15, color: ac.fg),
              decoration: InputDecoration(
                filled: false,
                fillColor: Colors.transparent,
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                isCollapsed: true,
                hintText: 'Message Ayma',
                hintStyle: AymaType.sans(size: 15, color: ac.fgMute),
              ),
            ),
          ),
        ),
        _RoundIconButton(
          icon: Icons.add_photo_alternate_outlined,
          tooltip: 'Attach a photo',
          background: Colors.transparent,
          foreground: ac.fgDim,
          onPressed: widget.onAttach,
        ),
        const SizedBox(width: 4),
        _RoundIconButton(
          icon: Icons.arrow_upward_rounded,
          tooltip: 'Send',
          background: widget.canSend ? ac.accent : ac.bgElev,
          foreground: widget.canSend ? AymaColors.onAccent : ac.fgMute,
          onPressed: widget.canSend ? widget.onSend : null,
        ),
      ],
    );
  }

  Widget _voiceRow(AymaTokens ac) {
    return Row(
      children: [
        _RoundIconButton(
          icon: widget.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          tooltip: widget.muted ? 'Unmute' : 'Mute',
          background: widget.muted ? ac.bgElev : ac.accentSoft,
          foreground: widget.muted ? ac.fgMute : ac.accent,
          onPressed: widget.onMuteTap,
        ),
        Expanded(
          child: Center(
            child: Text(
              widget.statusLabel ?? '',
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: AymaType.mono(
                size: 10,
                color: ac.fgMute,
              ).copyWith(letterSpacing: 1.5),
            ),
          ),
        ),
        _RoundIconButton(
          icon: Icons.stop_rounded,
          tooltip: 'End voice',
          background: ac.accent,
          foreground: AymaColors.onAccent,
          onPressed: widget.onStopPressed,
        ),
      ],
    );
  }
}

/// A circular icon button sized for a comfortable touch target even when its
/// visible circle reads smaller in the composer's compact row.
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 20, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// Reduced-motion fallback: the plain rounded frame with no animated wave.
class _StaticFrame extends StatelessWidget {
  const _StaticFrame({
    required this.lineColor,
    required this.fillColor,
    required this.child,
  });

  final Color lineColor;
  final Color fillColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        border: Border.all(color: lineColor, width: 1),
      ),
      child: child,
    );
  }
}

/// Paints a continuous rounded frame with filled, inward-facing voice waves.
class _ComposerBorderPainter extends CustomPainter {
  _ComposerBorderPainter({
    required this.lineColor,
    required this.fillColor,
    required this.waveColor,
    required this.topAmp,
    required this.botAmp,
    required this.topSpeed,
    required this.botSpeed,
    required this.phase,
  });

  final Color lineColor;
  final Color fillColor;
  final Color waveColor;
  final double topAmp; // eased pixels
  final double botAmp; // eased pixels
  final double topSpeed;
  final double botSpeed;
  final double phase; // 0..1, repeating

  static const double _maxRadius = 28.0;
  // Near the full width, tapering right up to the rounded corners — matches
  // the founder's reference mockup, which shows the wave running almost
  // edge-to-edge, not confined to a small centre section.
  static const double _windowFraction = 0.90;
  static const double _lobes = 5.0;
  static const double _sampleStep = 3.0;
  static const double _lineWidth = 1.0;
  static const double _activeThreshold = 0.15;

  double _radius(Size size) => math.min(_maxRadius, size.height / 2);

  (double, double) _window(Size size, double r) {
    final half = size.width * _windowFraction / 2;
    final cx = size.width / 2;
    // Keep clear of the corners on very narrow composers.
    final minX = r + 6;
    final maxX = size.width - r - 6;
    return ((cx - half).clamp(minX, maxX), (cx + half).clamp(minX, maxX));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = _radius(size);
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(r),
    );
    canvas.drawRRect(rrect, Paint()..color = fillColor);

    final topActive = topAmp > _activeThreshold;
    final botActive = botAmp > _activeThreshold;

    canvas.save();
    canvas.clipRRect(rrect);
    if (topActive) {
      _drawWave(canvas, size, r, top: true, amp: topAmp, speed: topSpeed);
    }
    if (botActive) {
      _drawWave(canvas, size, r, top: false, amp: botAmp, speed: botSpeed);
    }
    canvas.restore();
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _lineWidth
        ..color = botActive ? waveColor.withValues(alpha: 0.65) : lineColor,
    );
  }

  void _drawWave(
    Canvas canvas,
    Size size,
    double r, {
    required bool top,
    required double amp,
    required double speed,
  }) {
    final (winStart, winEnd) = _window(size, r);
    final width = winEnd - winStart;
    if (width <= 0) return;
    final baseY = top ? 0.0 : size.height;
    final dir = top ? 1.0 : -1.0; // always toward the interior

    final path = Path()..moveTo(winStart, baseY);
    for (double x = 0; x <= width; x += _sampleStep) {
      final t = x / width;
      // Amplitude envelope tapering to 0 at both ends of the window so the
      // wave blends seamlessly back into the flat border either side.
      final envelope = math.min(1.0, math.sin(math.pi * t) * 3);
      // A raised-cosine ("smooth lobes") waveform — always >= 0, so combined
      // with [dir] the edge only ever moves toward the interior, never past
      // its resting flat position.
      final wave =
          0.5 -
          0.5 *
              math.cos(_lobes * 2 * math.pi * t + phase * speed * 2 * math.pi);
      final y = baseY + dir * amp * envelope * wave;
      path.lineTo(winStart + x, y);
    }
    path.lineTo(winEnd, baseY);
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                waveColor.withValues(alpha: top ? 0.55 : 0.35),
                waveColor.withValues(alpha: top ? 0.25 : 0.75),
              ],
            ).createShader(
              Rect.fromLTWH(winStart, top ? 0 : baseY - amp, width, amp),
            ),
    );
  }

  @override
  bool shouldRepaint(_ComposerBorderPainter old) =>
      old.topAmp != topAmp ||
      old.botAmp != botAmp ||
      old.topSpeed != topSpeed ||
      old.botSpeed != botSpeed ||
      old.phase != phase ||
      old.lineColor != lineColor ||
      old.fillColor != fillColor ||
      old.waveColor != waveColor;
}
