import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/feature_tour_store.dart';
import '../services/tour_anchors.dart';
import '../services/tour_content.dart';
import '../theme.dart';

/// Padding grown around a spotlighted widget for both the painted cutout and
/// the press-through hit region, so the two always line up exactly.
const double _kHolePad = 8.0;

/// The interactive coach-mark / spotlight engine for the feature tour (§11.2a).
///
/// Rendered as a single full-screen layer on TOP of the whole app by [TourHost]
/// (in `MaterialApp.router`'s `builder`, above the `Navigator`), so it stays
/// mounted across route pushes and keeps the SAME floating callout open as the
/// tour moves between pages. It walks the user through the live UI one
/// [TourFeature] at a time: a dimming scrim with a rounded-rect spotlight cutout
/// around the step's target widget (resolved from its [TourAnchors] key), plus
/// an anchored callout — a short title, a one-line how-to, a step counter, a
/// persistent "Skip tour" and a "Next" / "Got it" button.
///
/// The spotlight is INTERACTIVE: the cutout is press-through (a [_HoleGate]
/// lets the tap fall through to the real widget behind, while a [Listener]
/// observes the same tap), so tapping the highlighted anchor performs its real
/// action AND advances the tour — tap the Profile tab and it opens Profile,
/// then the tour continues into its in-Profile sub-steps. Only the dimmed scrim
/// around the cutout absorbs taps. An off-screen anchor (a Profile row below the
/// fold) is scrolled into view before it's spotlighted.
///
/// Navigation-aware: before measuring each step the engine asks the host to
/// put the app where that step's anchor lives ([onPrepareStep]) — the root host
/// pops any pushed sub-page back to the shell and switches to the step's
/// [TourFeature.tab] — then re-acquires the anchor's rect on the new page and
/// keeps the same callout open. A step whose target still isn't present (a gated
/// feature, a missing widget, a page still transitioning in beyond
/// [maxMeasureAttempts] frames) is skipped gracefully — the tour never blocks on
/// a missing anchor. A step with no [TourFeature.anchorId] shows a centered
/// callout with no cutout (an intro/outro).
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
    this.onPrepareStep,
    this.resolveRect = TourAnchors.rectFor,
    this.maxMeasureAttempts = 40,
    this.onAnchorShown,
    this.onAnchorAbsent,
    this.onAnchorTapped,
    this.onStopPressed,
    this.hideNextButton = false,
    this.chromeless = false,
    this.stepIndex,
    this.stepTotal,
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

  /// Asks the host to put the app where the step's anchor lives before it's
  /// measured — the root host pops any pushed sub-page back to the shell and
  /// switches to the step's [TourFeature.tab]. Called once per step, for every
  /// step (so a press-through that pushed a sub-page is undone before the next
  /// anchor is measured). Null in standalone contexts (tests, layout matrix).
  final ValueChanged<TourFeature>? onPrepareStep;

  /// Resolves an anchor id to its on-screen rect; injectable for tests.
  final Rect? Function(String id) resolveRect;

  /// How many frames to re-try measuring a not-yet-laid-out anchor before
  /// skipping the step gracefully. Generous on device (default 40 ≈ 0.6s) so a
  /// step can ride out a route-pop transition + scroll-into-view; tests inject
  /// a small value so a genuinely-missing anchor skips within a few pumps.
  final int maxMeasureAttempts;

  // --- Ayma-driven tour hooks (§11.2b) — all null/false in the passive tour,
  // so its behaviour is unchanged. When set, one [CoachMarkOverlay] renders a
  // single backend-pushed step and reports back to the driver instead of
  // walking a local list.

  /// Fired once when this step's spotlight is up (its anchor resolved, or a
  /// centered step with no anchor) — the driver acks the step as shown.
  final VoidCallback? onAnchorShown;

  /// Fired when this step's anchor can't be resolved after
  /// [maxMeasureAttempts] frames. When set, this REPLACES the passive "skip to
  /// the next local step" so the driver can ack an honest absence and move on;
  /// when null, the overlay advances its own list as before.
  final VoidCallback? onAnchorAbsent;

  /// Fired when the user taps the spotlighted control (the press-through
  /// hole-tap). When set, this REPLACES the passive local advance — the real
  /// widget still acted (it was never blocked); the driver records the tap and
  /// the backend sends the next step. When null, a hole-tap advances the list.
  final VoidCallback? onAnchorTapped;

  /// What "Skip tour" does in driven mode — end the whole guided tour (the
  /// driver signals the backend). When null, Skip finishes the local tour as
  /// before (writing seen-state).
  final VoidCallback? onStopPressed;

  /// Hide the "Next" CTA so the only way forward is tapping the real control
  /// (driven mode). Skip stays, so the user can always leave.
  final bool hideNextButton;

  /// Ayma-DRIVEN tour (§11.2b): show ONLY the spotlight highlight — no callout
  /// card (no "NEW"/headline/description, no step counter, no prominent CTAs).
  /// The step's instruction is Ayma's own chat/voice line, not a card (founder,
  /// 2026-11-03: "I don't want the feature dialogues"). A single tiny,
  /// unobtrusive "Skip tour" affordance remains when [onStopPressed] is set.
  final bool chromeless;

  /// Override the 0-based step index displayed in the callout card counter
  /// ("N of M"). Used in driven mode where [features] only contains the single
  /// active step.
  final int? stepIndex;

  /// Override the total step count displayed in the callout card counter.
  /// Used in driven mode where [features] only contains the single active step.
  final int? stepTotal;

  @override
  State<CoachMarkOverlay> createState() => _CoachMarkOverlayState();
}

class _CoachMarkOverlayState extends State<CoachMarkOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    _scheduleMeasure();
  }

  /// The composer's cutout must follow the composer when the keyboard opens and
  /// pushes it up — otherwise the text field / Send move out of the stale hole
  /// and the scrim swallows their taps. A typing-allowed step re-resolves its
  /// anchor whenever view metrics change; every other step keeps the measured
  /// rect it settled on.
  @override
  void didChangeMetrics() {
    _syncTypingHole();
  }

  void _syncTypingHole() {
    if (!mounted || !_ready) return;
    final feature = widget.features[_index];
    if (!feature.typingAllowed) return;
    final anchorId = feature.anchorId;
    if (anchorId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = widget.features[_index];
      if (!current.typingAllowed || current.anchorId != anchorId) return;
      final rect = widget.resolveRect(anchorId);
      if (rect != null && rect != _rect) {
        setState(() => _rect = rect);
      }
    });
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
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  /// The last rect seen while waiting for it to stop moving (see below).
  Rect? _pendingRect;

  /// Measure this step's anchor after the next frame, first asking the host to
  /// put the app where the anchor lives (pop to the shell, switch tab). A
  /// cross-tab anchor (a Profile row) is scrolled into view first; an anchor
  /// that still doesn't resolve within [CoachMarkOverlay.maxMeasureAttempts]
  /// frames skips the step.
  void _scheduleMeasure() {
    _pendingRect = null;
    _measureAfterFrame(widget.features[_index], attempt: 0);
  }

  void _measureAfterFrame(TourFeature feature, {required int attempt}) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Navigate to the step's page on the first attempt — in a post-frame
      // callback, never synchronously during build, since it may `go()` or fire
      // a `TabRequest` that rebuilds the shell. Later attempts just re-measure
      // once that navigation has laid out.
      if (attempt == 0) widget.onPrepareStep?.call(feature);
      final anchorId = feature.anchorId;
      if (anchorId == null) {
        // A centered intro/outro step — no spotlight, no cutout.
        setState(() {
          _rect = null;
          _ready = true;
        });
        widget.onAnchorShown?.call();
        return;
      }
      // Scroll the target into view when it lives in a scrollable (a Profile
      // row below the fold) so the spotlight lands on it rather than skipping.
      // Only on the first attempt, so later re-measures don't nudge it each
      // frame while we wait for it to settle.
      final anchorContext = TourAnchors.contextFor(anchorId);
      if (attempt == 0 && anchorContext != null && anchorContext.mounted) {
        try {
          await Scrollable.ensureVisible(
            anchorContext,
            alignment: 0.5,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        } catch (_) {/* no scrollable ancestor — measure as-is */}
        if (!mounted) return;
      }
      final rect = widget.resolveRect(anchorId);
      if (rect == null) {
        // Not laid out yet (a tab still switching in, a pushed sub-page still
        // popping back to the shell) — retry for a bounded number of frames
        // before giving up and skipping gracefully, never blocking.
        if (attempt < widget.maxMeasureAttempts) {
          _measureAfterFrame(feature, attempt: attempt + 1);
          return;
        }
        // Driven mode: hand the absence to the driver (it acks honestly and the
        // backend skips the step) instead of advancing a local list.
        final onAbsent = widget.onAnchorAbsent;
        if (onAbsent != null) {
          onAbsent();
          return;
        }
        _advance();
        return;
      }
      // Commit only once the rect has STOPPED moving between frames. A
      // route-pop transition (a press-through that opened a sub-page, now
      // popping back) or an in-progress scroll can shift the anchor for several
      // frames; committing the first value would lock the spotlight onto a
      // stale mid-transition position (e.g. the wrong Profile row). Require two
      // consecutive equal measurements before showing it.
      if (rect != _pendingRect && attempt < widget.maxMeasureAttempts) {
        _pendingRect = rect;
        _measureAfterFrame(feature, attempt: attempt + 1);
        return;
      }
      setState(() {
        _rect = rect;
        _ready = true;
      });
      widget.onAnchorShown?.call();
    });
  }

  void _advance() {
    if (_finishing) return;
    // Drop any keyboard a press-through tap raised (e.g. the chat composer) so
    // it never covers the next step's anchor.
    FocusManager.instance.primaryFocus?.unfocus();
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

  /// The transparent cutout's rect in global coordinates — the painted hole and
  /// the press-through hit region share it, or null while no anchor is shown.
  Rect? get _holeRect =>
      _ready && _rect != null ? _rect!.inflate(_kHolePad) : null;

  /// True when [position] lands on the composer's mic — the one control that
  /// advances a typing-allowed step. Send / attach / text-field taps press
  /// through but do not move the tour.
  bool _isMicTap(Offset position) {
    final mic = widget.resolveRect(TourAnchors.asyncVoiceMic);
    return mic != null && mic.contains(position);
  }

  Offset? _downInHole;

  /// A press-through tap begins: remember where, to tell a tap on the cutout
  /// (which also reaches the real widget behind) from a drag or a scrim tap.
  void _onPointerDown(PointerDownEvent event) {
    final hole = _holeRect;
    _downInHole =
        hole != null && hole.contains(event.position) ? event.position : null;
  }

  /// A press-through tap on the cutout both let the real widget act (it was
  /// never blocked) and advances the tour — so tapping Profile opens Profile
  /// and moves on to its sub-steps.
  void _onPointerUp(PointerUpEvent event) {
    final down = _downInHole;
    _downInHole = null;
    if (down == null || _finishing) return;
    final hole = _holeRect;
    if (hole == null || !hole.contains(event.position)) return;
    // Typing-allowed step (the composer): the user must be able to tap the text
    // field, type and send without the tour stealing focus or advancing. Only
    // the mic is an anchor tap here — Done / Skip still move the tour forward.
    if (widget.features[_index].typingAllowed && !_isMicTap(event.position)) {
      return;
    }
    // Driven mode: the real control just acted; tell the driver so the backend
    // sends the next step — don't advance a local list.
    final onTapped = widget.onAnchorTapped;
    if (onTapped != null) {
      FocusManager.instance.primaryFocus?.unfocus();
      onTapped();
      return;
    }
    _advance();
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
            // origin matches the global rects the anchors report. The dimmed
            // area absorbs taps, but the cutout is press-through — the
            // [_HoleGate] lets the hit fall through to the real widget behind,
            // and the [Listener] observes the same tap to advance the tour.
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _onPointerDown,
                onPointerUp: _onPointerUp,
                child: _HoleGate(
                  hole: _holeRect,
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
            ),
            // Driven tour: no callout card at all — just the spotlight and a
            // tiny, low-emphasis "Skip tour" so the instruction is purely
            // Ayma's spoken/typed line. Passive tour: the full callout card.
            if (_ready && widget.chromeless)
              _buildChromelessSkip(ac)
            else if (_ready)
              SafeArea(child: _buildCallout(ac, feature, isLast)),
          ],
        ),
      ),
    );
  }

  /// The only chrome in driven mode: a small, unobtrusive "Skip tour" pinned to
  /// the bottom. Nothing else is drawn over the app but the spotlight. Omitted
  /// when there's no stop handler.
  Widget _buildChromelessSkip(AymaTokens ac) {
    if (widget.onStopPressed == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextButton(
              key: const ValueKey('coach-skip'),
              onPressed: _finishing ? null : widget.onStopPressed,
              style: TextButton.styleFrom(
                foregroundColor: ac.fgMute,
                textStyle: AymaType.sans(size: 12, weight: FontWeight.w500),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
              child: const Text('Skip tour'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallout(AymaTokens ac, TourFeature feature, bool isLast) {
    final effectiveIndex = widget.stepIndex ?? _index;
    final effectiveTotal = widget.stepTotal ?? widget.features.length;
    final effectiveIsLast = isLast || effectiveIndex >= effectiveTotal - 1;
    final card = _CalloutCard(
      feature: feature,
      spotlight: widget.spotlight,
      index: effectiveIndex,
      total: effectiveTotal,
      isLast: effectiveIsLast,
      finishing: _finishing,
      onNext: widget.onAnchorTapped != null
          ? () {
              FocusManager.instance.primaryFocus?.unfocus();
              widget.onAnchorTapped!();
            }
          : _advance,
      // Driven mode: "Skip tour" ends the whole guided tour via the driver;
      // otherwise it finishes the local tour (writing seen-state) as before.
      onSkip: widget.onStopPressed ?? _finish,
      hideNext: widget.hideNextButton,
    );
    final size = MediaQuery.sizeOf(context);
    // The card is always centered HORIZONTALLY (a centred Align + a capped
    // width, so it reads as a centred dialogue on phones and tablets alike).
    // Vertically: a non-anchored (summary) step is centred on screen; an
    // anchored step's callout sits in the half OPPOSITE its spotlight so it
    // never covers the highlighted element — and, crucially, never covers the
    // press-through cutout. The card shrink-wraps its height and scrolls
    // internally only when it can't fit (overflow-safe at text scale 2.0), so
    // the empty area around it passes taps through to the scrim/cutout below.
    final targetInBottomHalf =
        _rect != null && _rect!.center.dy > size.height / 2;
    final alignment = _rect == null
        ? Alignment.center
        : (targetInBottomHalf ? Alignment.topCenter : Alignment.bottomCenter);
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 400,
            maxHeight: constraints.maxHeight,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: card,
          ),
        ),
      ),
    );
  }
}

/// A hit-test gate that blocks pointers over the dimmed scrim but lets them
/// fall through the spotlight [hole] to the real widget behind the overlay, so
/// the highlighted anchor stays tappable (§11.2a). Its child is paint-only
/// (the scrim), so it never contributes its own hits.
class _HoleGate extends SingleChildRenderObjectWidget {
  const _HoleGate({required this.hole, super.child});

  final Rect? hole;

  @override
  _RenderHoleGate createRenderObject(BuildContext context) =>
      _RenderHoleGate(hole);

  @override
  void updateRenderObject(BuildContext context, _RenderHoleGate renderObject) {
    renderObject.hole = hole;
  }
}

class _RenderHoleGate extends RenderProxyBox {
  _RenderHoleGate(this._hole);

  Rect? _hole;
  set hole(Rect? value) {
    if (value != _hole) _hole = value;
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final hole = _hole;
    // Inside the cutout: report no hit so the tap reaches the app behind.
    if (hole != null && hole.contains(position)) return false;
    // Everywhere else: absorb the tap (dim the app) without probing the
    // paint-only child.
    if (size.contains(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
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
    this.hideNext = false,
  });

  final TourFeature feature;
  final bool spotlight;
  final int index;
  final int total;
  final bool isLast;
  final bool finishing;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  /// Hide the Next CTA (driven mode — the user advances by tapping the real
  /// highlighted control, not a button).
  final bool hideNext;

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
              if (!hideNext) ...[
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 22, vertical: 12),
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

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    if (hole == null) {
      canvas.drawRect(full, Paint()..color = scrim);
      return;
    }
    final cut = hole!.inflate(_kHolePad);
    canvas.saveLayer(full, Paint());
    canvas.drawRect(full, Paint()..color = scrim);
    canvas.drawRRect(
      RRect.fromRectAndRadius(cut, const Radius.circular(_radius)),
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();
    if (glow > 0) {
      final grow = _kHolePad + 6 * glow;
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
