import 'package:flutter/material.dart';

import '../theme.dart';
import 'ayma_orb.dart';

/// The one branded loading indicator: the Ayma logo — the canonical
/// [AymaOrb] itself, painted live from the user's accent colour, never a
/// bundled picture file (a static PNG can only ever show the accent it was
/// rendered with, so the loader used to glow Cherry Fuchsia next to orbs in
/// the user's own colour) — with a gentle, tasteful loading animation: a
/// soft breathing pulse plus a halo glow that swells and fades. Used
/// wherever the app is waiting on something the user is looking at: the
/// voice wake/connect state (the mic row while the session is still being
/// established) and the report / page loaders that used to show a bare
/// [CircularProgressIndicator] or a static orb, so every "Ayma is working"
/// moment reads the same.
///
/// Founder ask ("the Ayma logo should have a loading animation"). Respects
/// reduced motion: when [MediaQuery.disableAnimations] is on (or [reduceMotion]
/// is forced), it renders the logo completely still — the static
/// [AymaOrbMark], no pulse, no controller running — which still reads
/// clearly as "loading" alongside its label.
class AymaLogoLoader extends StatefulWidget {
  const AymaLogoLoader({
    super.key,
    this.size = 64,
    this.label,
    this.reduceMotion,
  });

  /// Diameter of the logo in logical pixels. The glow extends a little beyond
  /// it, so callers should leave a touch of breathing room.
  final double size;

  /// Optional caption under the logo (e.g. "Loading your report…"). Omitted
  /// when null so the widget is just the animated mark.
  final String? label;

  /// Forces the static, motion-free rendering regardless of [MediaQuery].
  /// Null (the default) reads the ambient [MediaQuery.disableAnimations].
  final bool? reduceMotion;

  @override
  State<AymaLogoLoader> createState() => _AymaLogoLoaderState();
}

class _AymaLogoLoaderState extends State<AymaLogoLoader>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  bool get _reduceMotion =>
      widget.reduceMotion ??
      (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Start (or stop) the pulse once we can read the ambient MediaQuery.
    // Reduced motion never spins a controller up at all.
    if (_reduceMotion) {
      _controller?.stop();
      return;
    }
    _controller ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // The canonical orb, live from the ambient accent: the thinking state
    // while motion is allowed; the static mark (the same painter's rest
    // frame) when reduced motion is in force, so nothing ticks at all.
    final Widget logo = _reduceMotion
        ? AymaOrbMark(size: widget.size)
        : AymaOrb(size: widget.size, state: AymaOrbState.thinking);

    final controller = _controller;
    final Widget mark = (_reduceMotion || controller == null)
        ? logo
        : AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              // A single eased wave drives both the breathing scale and the
              // halo so they stay in phase.
              final t = Curves.easeInOut.transform(controller.value);
              final scale = 0.92 + 0.08 * t;
              final glow = 0.18 + 0.32 * t;
              return Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: ac.accent.withValues(alpha: glow),
                      blurRadius: widget.size * 0.35,
                      spreadRadius: widget.size * 0.04,
                    ),
                  ],
                ),
                child: Transform.scale(scale: scale, child: child),
              );
            },
            child: logo,
          );

    final label = widget.label;
    return Semantics(
      label: label ?? 'Loading',
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          if (label != null) ...[
            SizedBox(height: widget.size * 0.28),
            Text(
              label,
              textAlign: TextAlign.center,
              style: AymaType.mono(size: 12, color: ac.fgMute)
                  .copyWith(letterSpacing: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
