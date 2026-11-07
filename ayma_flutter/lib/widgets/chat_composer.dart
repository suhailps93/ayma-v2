import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'keyboard_dismiss.dart';

/// Padding wrapping the composer bar at the bottom of a chat screen — shared
/// by the Ayma chat (`ChatScreen`'s `_Composer`) and the user-to-user DM
/// thread (`DmThreadScreen`) so the composer sits the same distance above the
/// persistent bottom nav bar on both screens (founder ask). Neither screen
/// should add a bottom safe-area inset on top of this: the nav bar below
/// (`AymaTabBar`, whether as `MainShellScreen`'s `bottomNavigationBar` or
/// `NavBarShell`'s Column sibling) already consumes the device inset itself.
const kComposerBarPadding = EdgeInsets.fromLTRB(12, 8, 12, 8);

/// Bottom padding inside a chat message list — the clearance between the last
/// bubble and the composer bar above [kComposerBarPadding]. Shared by the
/// Ayma chat's transcript and the DM thread's message list so the last
/// message clears the composer identically on both screens.
const kChatListBottomInset = 12.0;

/// The three visual states the unified chat composer can be in. It is always
/// the same widget morphing between them — never three separate composers
/// appearing/disappearing.
enum ComposerMode {
  /// Idle chat input: mic · text field · attach · send.
  text,

  /// A voice session is still being established — fetching a token, joining
  /// the room, or waking the scale-to-zero agent (controller phases
  /// `connecting`/`waking`). The leading slot shows a connecting indicator
  /// (never the lit capturing mic), the status label reads "Connecting…" /
  /// "Waking Ayma…", and neither border wave animates — the mic is NOT yet
  /// being listened to, so the composer must not read as "listening".
  connecting,

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
    this.micKey,
    required this.onStopPressed,
    required this.onMuteTap,
    this.onExpandTap,
    required this.muted,
    required this.userAmplitude,
    required this.aiAmplitude,
    this.statusLabel,
    this.rootKey,
  });

  /// Feature-tour anchor for the whole composer (the "say hi to Ayma" box the
  /// coach-mark engine spotlights). Only the main shell's chat passes it, so it
  /// never collides with the second composer the Ask-Ayma popup builds.
  final Key? rootKey;

  final ComposerMode mode;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Text mode only — whether the send button is enabled.
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  /// Text mode's mic button — starts a voice session.
  final VoidCallback onMicPressed;

  /// Key for the text mode's mic button (the feature-tour anchor) — the
  /// main shell's chat passes it, so it never collides with the Ask-Ayma
  /// popup's second composer.
  final Key? micKey;

  /// Voice modes' stop button — ends the live voice session.
  final VoidCallback onStopPressed;

  /// Voice modes' mic button — toggles mute.
  final VoidCallback onMuteTap;

  /// Voice modes only — tapping the status label re-opens the full-screen
  /// voice view for a call that's already live (e.g. after switching back to
  /// this tab from elsewhere collapsed it to just this inline bar). Null
  /// disables the tap target entirely (no-op text mode, or a caller that
  /// hasn't wired the full-screen view up yet).
  final VoidCallback? onExpandTap;
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

  // Eased pixel amplitude ceilings for the two edges, stepped once per
  // animation tick toward their targets. This is now just the envelope's *ceiling*; the actual wave
  // shape comes from [_topBuffer]/[_botBuffer] below.
  double _topAmp = 0;
  double _botAmp = 0;

  // Rolling amplitude-history buffers — the real "voice waveform" data the
  // painter draws through, refreshed at a steady cadence independent of the
  // frame rate. Fixed-length and mutated in place (no per-sample
  // allocation).
  static const int _bufferLength = 40;
  static const int _sampleIntervalMs = 55;
  final AmplitudeWaveBuffer _topBuffer = AmplitudeWaveBuffer(_bufferLength);
  final AmplitudeWaveBuffer _botBuffer = AmplitudeWaveBuffer(_bufferLength);
  final Stopwatch _sampleClock = Stopwatch()..start();
  int _lastSampleMs = -_sampleIntervalMs;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onComposerInputChanged);
  }

  void _onComposerInputChanged() {
    if (mounted) setState(() {});
  }

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
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onComposerInputChanged);
      widget.controller.addListener(_onComposerInputChanged);
    }
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
    widget.controller.removeListener(_onComposerInputChanged);
    _phase?.dispose();
    super.dispose();
  }

  double _targetAmp(double level, bool active) {
    if (!active) return 0;
    final l = level.clamp(0.0, 1.0);
    // A raw mic/TTS level rarely sits near 1.0 even for normal speech, so a
    // linear mapping read as barely-there in practice (founder, twice now:
    // "very small ... make it way large so it's visible" / "more amplitude
    // than this flat wave"). `sqrt` lifts typical low/mid levels much closer
    // to the ceiling; the floor and coefficient below are pushed hard enough
    // that even a quiet moment sits well up the composer's height, and a
    // normal-speech moment already presses right up against the painter's
    // hard clamp (`clampWaveDisplacement`, keyed to the composer's own
    // actual half-height) instead of sitting comfortably under it — that
    // clamp is what keeps this safely inside the rounded frame regardless of
    // how high this ceiling reaches.
    return (11.0 + math.sqrt(l) * 26.0).clamp(0.0, 37.0);
  }

  void _step() {
    final userActive = widget.mode == ComposerMode.listening;
    final aiActive = widget.mode == ComposerMode.aiSpeaking;
    final topTarget = _targetAmp(widget.aiAmplitude.value, aiActive);
    final botTarget = _targetAmp(widget.userAmplitude.value, userActive);
    const k = 0.14; // per-frame lerp toward target — smooth, no hard snap
    _topAmp = lerpDouble(_topAmp, topTarget, k)!;
    _botAmp = lerpDouble(_botAmp, botTarget, k)!;

    // Sample the rolling history buffers at a steady ~55ms cadence, decoupled
    // from the frame rate (a real voice-memo waveform's cadence) rather than
    // resampling the same smoothed scalar every frame — that would just be
    // uniform noise at a different frequency, not real texture.
    final nowMs = _sampleClock.elapsedMilliseconds;
    if (nowMs - _lastSampleMs >= _sampleIntervalMs) {
      _lastSampleMs = nowMs;
      _topBuffer.push(widget.aiAmplitude.value);
      _botBuffer.push(widget.userAmplitude.value);
    }

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
                  topSamples: _topBuffer.samples,
                  botSamples: _botBuffer.samples,
                  topVersion: _topBuffer.version,
                  botVersion: _botBuffer.version,
                ),
                child: child,
              );
            },
            child: switched,
          );

    // KeepKeyboardOnTap: the whole composer (mic / attach / send included) is
    // a keep-the-keyboard zone for the app-root tap-outside-dismiss —
    // firing Send repeatedly with the keyboard up is core chat UX. Pure
    // registry marker, changes nothing about hit testing.
    return KeepKeyboardOnTap(
      key: widget.rootKey,
      child: RepaintBoundary(
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.center,
          child: painted,
        ),
      ),
    );
  }

  Widget _textRow(AymaTokens ac) {
    // WhatsApp swap (founder, 2026-11-06): the bottom-right slot is the
    // MIC while the input is empty and nothing is staged, and the SEND
    // button only while there is text or a staged attachment (the
    // caller's [canSend] carries the attachment/staged state). The mic is
    // tap-only: it starts a live voice call. Voice-note recording lives
    // only in human-to-human DMs (founder, 2026-11-06) — holding the mic
    // here starts nothing.
    final hasText = widget.controller.text.trim().isNotEmpty;
    final showSend = widget.canSend || hasText;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
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
        if (showSend)
          _RoundIconButton(
            key: const ValueKey('composerSendButton'),
            icon: Icons.arrow_upward_rounded,
            tooltip: 'Send',
            background: ac.accent,
            foreground: ac.onAccent,
            onPressed: widget.onSend,
          )
        else
          _RoundIconButton(
            key: widget.micKey,
            icon: Icons.mic_none_rounded,
            tooltip: 'Talk to Ayma',
            background: ac.bgElev,
            foreground: ac.fgDim,
            onPressed: widget.onMicPressed,
          ),
      ],
    );
    return row;
  }

  Widget _voiceRow(AymaTokens ac) {
    // While connecting/waking the mic is NOT yet being captured, so the
    // leading slot shows a dimmed, unlit microphone — still clearly a mic, just
    // muted/inactive — rather than the lit, tappable "capturing" mic (tapping
    // which would be a no-op mute before the call is live anyway). A static
    // dimmed mic reads as "not listening yet" without implying the composer is
    // already capturing audio.
    final leading = widget.mode == ComposerMode.connecting
        ? _ConnectingLead(color: ac.fgMute)
        : _RoundIconButton(
            icon: widget.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            tooltip: widget.muted ? 'Unmute' : 'Mute',
            background: widget.muted ? ac.bgElev : ac.accentSoft,
            foreground: widget.muted ? ac.fgMute : ac.accent,
            onPressed: widget.onMuteTap,
          );
    return Row(
      children: [
        leading,
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onExpandTap,
            child: Tooltip(
              message: 'Open full-screen voice view',
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
          ),
        ),
        _RoundIconButton(
          icon: Icons.stop_rounded,
          tooltip: 'End voice',
          background: ac.accent,
          foreground: ac.onAccent,
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
    super.key,
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

/// The leading slot of the voice row while a session is still being
/// established ([ComposerMode.connecting]): a dimmed, unlit microphone glyph
/// (founder: the mic should stay visible, just clearly not-yet-listening — not
/// an orb and not a spinner) sized to match [_RoundIconButton]'s 44px touch
/// slot so the row height never jumps when it swaps to the real mic button once
/// live. Non-interactive — there is nothing to mute yet. Static in every case,
/// including reduced motion, which still reads as "not listening yet".
class _ConnectingLead extends StatelessWidget {
  const _ConnectingLead({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Icon(Icons.mic_none_rounded, size: 20, color: color),
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

/// A small rolling history of recent amplitude samples for one wave edge, so
/// the border draws a real, ever-changing voice-waveform shape instead of a
/// fixed mathematical curve resized by a single scalar. Samples are pushed at
/// a steady cadence (see [_ChatComposerState]'s ticker) with a loosely
/// correlated wobble plus a genuine fast oscillation layered on top, so
/// consecutive peaks vary the way real speech does and the wave reads as
/// busy rather than one slow blob, while the underlying level still tracks
/// the live input (loud stays busier and taller, quiet stays flatter).
///
/// Index 0 is always the oldest sample and `length - 1` the newest — pushing
/// shifts the whole history left by one, so this is always a rolling recent
/// window, never the whole session. The backing array is fixed-size and
/// mutated in place: no allocation on the sampling hot path.
@visibleForTesting
class AmplitudeWaveBuffer {
  AmplitudeWaveBuffer(this.length, {math.Random? random})
    : samples = Float64List(length),
      _rng = random ?? math.Random();

  final int length;
  final Float64List samples;
  final math.Random _rng;

  double _levelEma = 0;
  double _jitterState = 0;
  double _wigglePhase = 0;

  /// Bumped on every [push]. A painter compares this (not the mutable,
  /// reused [samples] array itself, which is always the same reference) to
  /// know the history actually changed since the last frame.
  int version = 0;

  /// Pushes one new sample derived from [level] (0..1, already-smoothed
  /// audio level). Tracks it briskly rather than snapping the newest sample
  /// straight to it, and layers in both a loosely-correlated wobble and a
  /// genuine fast oscillation so it reads as busy, organic texture — not
  /// white noise, not a resized copy of the same shape, and not a mechanical
  /// metronome either.
  void push(double level) {
    final target = level.clamp(0.0, 1.0);
    // Brisk half-life-style smoothing: tracks a real level change within a
    // sample or two rather than averaging it away, so short-timescale
    // variation in the input actually survives into the buffer.
    _levelEma = _levelEma + (target - _levelEma) * 0.6;
    // A smoothed random walk bounded to [-1, 1] by construction (a weighted
    // average of itself and a fresh random step never leaves the range).
    // Weighted more toward the fresh step than before — still correlated
    // enough to read as voice rather than static, but loose enough that
    // consecutive samples visibly differ instead of drifting as one slow
    // blob.
    _jitterState = (_jitterState * 0.45 + (_rng.nextDouble() * 2 - 1) * 0.55)
        .clamp(-1.0, 1.0);
    // A genuine higher-frequency oscillation riding on top of the smoothed
    // level — this is what actually raises the wave's *frequency*, not just
    // its ceiling: several distinct cycles land inside one buffer's worth of
    // history, so louder moments visibly wiggle faster as well as taller.
    // The per-sample phase step is itself randomized within a band so the
    // cadence isn't perfectly periodic (which would read as a mechanical
    // sawtooth) while still landing a handful of clear peaks per second.
    _wigglePhase += 0.85 + _rng.nextDouble() * 0.55;
    final wiggle = math.sin(_wigglePhase);
    // Louder moments wobble and wiggle more in absolute terms; quiet moments
    // stay close to flat. A small floor keeps even a silent stretch faintly
    // alive.
    final jittered =
        (_levelEma +
                _jitterState * 0.28 * _levelEma +
                wiggle * 0.32 * _levelEma)
            .clamp(0.0, 1.3);
    final sample = math.max(0.03, jittered);

    if (length > 1) {
      for (var i = 0; i < length - 1; i++) {
        samples[i] = samples[i + 1];
      }
      samples[length - 1] = sample;
    } else if (length == 1) {
      samples[0] = sample;
    }
    version++;
  }
}

/// The tapering multiplier applied along the active window: 0 at both ends
/// (`t == 0` / `t == 1`) so the wave blends seamlessly into the flat border,
/// reaching full strength well before the window's midpoint.
@visibleForTesting
double waveEnvelope(double t) => math.min(1.0, math.sin(math.pi * t) * 3);

/// Clamps a wave crest's pixel displacement so it always stays strictly
/// inside the composer's own rounded frame — whatever the eased amplitude
/// ceiling or a jittered sample peak computes to, the drawn point can never
/// pass the frame's own midline.
@visibleForTesting
double clampWaveDisplacement(double raw, double composerHeight) {
  final maxAllowed = math.max(
    0.0,
    composerHeight / 2 - _ComposerBorderPainter._lineWidth,
  );
  return raw.clamp(0.0, maxAllowed);
}

/// Paints a continuous rounded frame with filled, inward-facing voice waves.
class _ComposerBorderPainter extends CustomPainter {
  _ComposerBorderPainter({
    required this.lineColor,
    required this.fillColor,
    required this.waveColor,
    required this.topAmp,
    required this.botAmp,
    required this.topSamples,
    required this.botSamples,
    required this.topVersion,
    required this.botVersion,
  });

  final Color lineColor;
  final Color fillColor;
  final Color waveColor;
  final double topAmp; // eased pixels — the current envelope ceiling
  final double botAmp; // eased pixels — the current envelope ceiling
  final Float64List topSamples; // rolling amplitude history, oldest..newest
  final Float64List botSamples;
  final int topVersion; // bumped whenever topSamples' content changes
  final int botVersion;

  static const double _maxRadius = 28.0;
  // Near the full width, tapering right up to the rounded corners — matches
  // the founder's reference mockup, which shows the wave running almost
  // edge-to-edge, not confined to a small centre section.
  static const double _windowFraction = 0.90;
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
      _drawWave(canvas, size, r, top: true, amp: topAmp, samples: topSamples);
    }
    if (botActive) {
      _drawWave(canvas, size, r, top: false, amp: botAmp, samples: botSamples);
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

  /// One sample's plotted position — a pure function of the buffer content,
  /// kept separate from Canvas/Path so the shape and the bounds-safety are
  /// easy to reason about independently.
  Offset _point(
    Float64List samples,
    int i,
    int n,
    double winStart,
    double width,
    double baseY,
    double dir,
    double amp,
    double composerHeight,
  ) {
    final t = n <= 1 ? 0.0 : i / (n - 1);
    final envelope = waveEnvelope(t);
    final displacement = clampWaveDisplacement(
      amp * envelope * samples[i],
      composerHeight,
    );
    return Offset(winStart + t * width, baseY + dir * displacement);
  }

  void _drawWave(
    Canvas canvas,
    Size size,
    double r, {
    required bool top,
    required double amp,
    required Float64List samples,
  }) {
    final (winStart, winEnd) = _window(size, r);
    final width = winEnd - winStart;
    if (width <= 0) return;
    final baseY = top ? 0.0 : size.height;
    final dir = top ? 1.0 : -1.0; // always toward the interior
    final n = samples.length;

    final path = Path()..moveTo(winStart, baseY);
    if (n == 0) {
      path.lineTo(winEnd, baseY);
      path.close();
      return;
    }

    // Catmull-Rom through the buffered samples, mapped evenly across the
    // active window — a smooth-but-irregular curve through real recent
    // amplitude data instead of a perfectly regular sine/cosine. Carrying a
    // rolling 4-point window instead of building a points list keeps this
    // allocation-light on the per-frame paint path.
    Offset p0 = _point(
      samples,
      0,
      n,
      winStart,
      width,
      baseY,
      dir,
      amp,
      size.height,
    );
    Offset p1 = p0;
    Offset p2 = n > 1
        ? _point(samples, 1, n, winStart, width, baseY, dir, amp, size.height)
        : p0;
    path.lineTo(p0.dx, p0.dy);
    for (var i = 0; i < n - 1; i++) {
      final p3 = i + 2 < n
          ? _point(
              samples,
              i + 2,
              n,
              winStart,
              width,
              baseY,
              dir,
              amp,
              size.height,
            )
          : p2;
      final c1 = p1 + (p2 - p0) / 6.0;
      final c2 = p2 - (p3 - p1) / 6.0;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
      p0 = p1;
      p1 = p2;
      p2 = p3;
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
      old.topVersion != topVersion ||
      old.botVersion != botVersion ||
      old.lineColor != lineColor ||
      old.fillColor != fillColor ||
      old.waveColor != waveColor;
}
