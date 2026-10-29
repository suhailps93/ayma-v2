import 'package:flutter/material.dart';

import '../services/feature_tour_store.dart';
import '../services/tour_anchors.dart';
import '../services/tour_content.dart';
import '../theme.dart';

/// The interactive coach-mark / spotlight engine for the feature tour (§11.2a).
///
/// Rendered as a full-screen layer on TOP of the real app (the main shell), it
/// walks the user through the live UI one [TourFeature] at a time: a dimming
/// scrim with a rounded-rect spotlight cutout around the step's target widget
/// (resolved from its [TourAnchors] key), plus an anchored callout — a short
/// title, a one-line how-to, a step counter, a persistent "Skip tour" and a
/// "Next" / "Got it" button that prompts the user to press through.
///
/// Cross-screen: a step whose anchor lives on another shell tab names that tab
/// ([TourFeature.tab]); the engine asks the host to switch there ([onSwitchTab])
/// before spotlighting. A step whose target isn't present on this build (a
/// gated feature, a missing widget) is skipped gracefully — the tour never
/// blocks on a missing anchor. A step with no [TourFeature.anchorId] shows a
/// centered callout with no cutout (an intro/outro).
///
/// Finishing OR skipping marks every shown feature's `feature_id` seen (via
/// [FeatureTourStore]) so it doesn't nag again, then calls [onFinish] to
/// dismiss. Reduced-motion safe: the pulsing spotlight ring is dropped when
/// `MediaQuery.disableAnimations` is set.
class CoachMarkOverlay extends StatefulWidget {
  const CoachMarkOverlay({
    super.key,
    required this.features,
    required this.onFinish,
    this.spotlight = false,
    this.store,
    this.onSwitchTab,
    this.resolveRect = TourAnchors.rectFor,
  });

  /// The ordered steps to walk through.
  final List<TourFeature> features;

  /// Dismiss the overlay (the host clears its tour state). Seen-state is
  /// already written by the time this fires.
  final VoidCallback onFinish;

  /// New-feature spotlight framing (a "NEW" chip, "Got it" CTA) vs the full
  /// first-run walkthrough.
  final bool spotlight;

  /// Injected in tests; defaults to the app-wide [featureTourStoreGlobal].
  final FeatureTourStore? store;

  /// Asks the host to make [TourFeature.tab] the active shell body before a
  /// step is spotlighted. Null in standalone contexts (tests, layout matrix).
  final ValueChanged<int>? onSwitchTab;

  /// Resolves an anchor id to its on-screen rect; injectable for tests.
  final Rect? Function(String id) resolveRect;

  @override
  State<CoachMarkOverlay> createState() => _CoachMarkOverlayState();
}

class _CoachMarkOverlayState extends State<CoachMarkOverlay>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  Rect? _rect;
  bool _ready = false;
  bool _finishing = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  FeatureTourStore get _store => widget.store ?? featureTourStoreGlobal;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour reduced motion for the pulsing spotlight ring — start/stop here
    // (MediaQuery isn't available in initState).
    final animate = !MediaQuery.disableAnimationsOf(context);
    if (animate && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!animate && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// After the next frame, switch to the step's tab (if any) and measure its
  /// anchor. A non-null anchor that doesn't resolve skips the step.
  void _scheduleMeasure() {
    final feature = widget.features[_index];
    final tab = feature.tab;
    if (tab != null) widget.onSwitchTab?.call(tab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchorId = feature.anchorId;
      final rect = anchorId == null ? null : widget.resolveRect(anchorId);
      if (anchorId != null && rect == null) {
        // Target absent on this build — skip gracefully, never block.
        _advance();
        return;
      }
      setState(() {
        _rect = rect;
        _ready = true;
      });
    });
  }

  void _advance() {
    if (_finishing) return;
    if (_index >= widget.features.length - 1) {
      _finish();
      return;
    }
    setState(() {
      _index++;
      _ready = false;
      _rect = null;
    });
    _scheduleMeasure();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await _store.markSeen(widget.features.map((f) => f.featureId));
    if (!mounted) return;
    widget.onFinish();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final feature = widget.features[_index];
    final isLast = _index == widget.features.length - 1;
    // Back is handled by the host shell's single PopScope (it skips the tour),
    // so this overlay owns no navigation of its own.
    return Material(
      type: MaterialType.transparency,
      child: SizedBox.expand(
        child: Stack(
          children: [
            // Scrim + spotlight. Full-screen (outside SafeArea) so its paint
            // origin matches the global rects the anchors report.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {}, // absorb taps on the dimmed area
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('coach-spotlight'),
                    painter: _SpotlightPainter(
                      hole: _ready ? _rect : null,
                      scrim: Colors.black.withValues(alpha: 0.72),
                      ring: ac.accent,
                      glow: _pulse.isAnimating ? _pulse.value : 0,
                    ),
                  ),
                ),
              ),
            ),
            if (_ready) SafeArea(child: _buildCallout(ac, feature, isLast)),
          ],
        ),
      ),
    );
  }

  Widget _buildCallout(AymaTokens ac, TourFeature feature, bool isLast) {
    final card = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: _CalloutCard(
        feature: feature,
        spotlight: widget.spotlight,
        index: _index,
        total: widget.features.length,
        isLast: isLast,
        finishing: _finishing,
        onNext: _advance,
        onSkip: _finish,
      ),
    );
    final size = MediaQuery.sizeOf(context);
    // Place the callout in the half of the screen opposite the spotlight so it
    // never sits on top of the highlighted element; centered when there's no
    // target. Scroll-safe: pinned to an edge, scrolls only if it can't fit.
    final targetInBottomHalf =
        _rect != null && _rect!.center.dy > size.height / 2;
    final align = _rect == null
        ? MainAxisAlignment.center
        : (targetInBottomHalf ? MainAxisAlignment.start : MainAxisAlignment.end);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
          child: Column(
            mainAxisAlignment: align,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [card],
          ),
        ),
      ),
    );
  }
}

/// The anchored callout: icon, title, one-line how-to, a step counter (or a
/// "NEW" chip in spotlight mode), a persistent Skip and the Next / Got it CTA.
class _CalloutCard extends StatelessWidget {
  const _CalloutCard({
    required this.feature,
    required this.spotlight,
    required this.index,
    required this.total,
    required this.isLast,
    required this.finishing,
    required this.onNext,
    required this.onSkip,
  });

  final TourFeature feature;
  final bool spotlight;
  final int index;
  final int total;
  final bool isLast;
  final bool finishing;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (spotlight)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('NEW', style: AymaType.mono(size: 11, color: ac.accent)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '${index + 1} of $total',
                style: AymaType.mono(size: 11, color: ac.fgMute),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (feature.icon != null) ...[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ac.accentFaint,
                    border: Border.all(color: ac.accentSoft, width: 0.5),
                  ),
                  child: Icon(feature.icon, size: 22, color: ac.accent),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Text(
                  feature.headline,
                  style: AymaType.serif(size: 24, color: ac.fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            feature.subtitle,
            style: AymaType.sans(size: 15, height: 1.4, color: ac.fgDim),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('coach-skip'),
                    onPressed: finishing ? null : onSkip,
                    child: Text(
                      'Skip tour',
                      style: AymaType.sans(
                        size: 14,
                        weight: FontWeight.w600,
                        color: ac.fgDim,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const ValueKey('coach-next'),
                    onPressed: finishing ? null : onNext,
                    style: FilledButton.styleFrom(
                      backgroundColor: ac.accent,
                      foregroundColor: ac.onAccent,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                      shape: const StadiumBorder(),
                      textStyle: AymaType.sans(size: 15, weight: FontWeight.w600),
                    ),
                    child: Text(
                      isLast ? (spotlight ? 'Got it' : 'Done') : 'Next',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Paints the dimming scrim with a rounded-rect cutout around the spotlighted
/// widget, plus a pulsing accent ring (dropped when [glow] is 0 / reduced
/// motion). A null [hole] dims the whole screen (a centered callout step, or
/// while the next step's anchor is still being measured).
class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({
    required this.hole,
    required this.scrim,
    required this.ring,
    required this.glow,
  });

  final Rect? hole;
  final Color scrim;
  final Color ring;
  final double glow;

  static const _radius = 16.0;
  static const _pad = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    if (hole == null) {
      canvas.drawRect(full, Paint()..color = scrim);
      return;
    }
    final cut = hole!.inflate(_pad);
    canvas.saveLayer(full, Paint());
    canvas.drawRect(full, Paint()..color = scrim);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cut, const Radius.circular(_radius)),
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();
    if (glow > 0) {
      final grow = _pad + 6 * glow;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          hole!.inflate(grow),
          Radius.circular(_radius + 6 * glow),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring.withValues(alpha: (1 - glow).clamp(0.0, 1.0) * 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_SpotlightPainter old) =>
      old.hole != hole || old.glow != glow || old.scrim != scrim;
}
