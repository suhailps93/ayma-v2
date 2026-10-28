import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/feature_tour_store.dart';
import '../services/tour_content.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/overflow_guards.dart';
import 'main_shell_screen.dart';

/// Arguments for the `/tour` route, passed as `GoRouterState.extra` by the
/// surface that launches it:
///  * the main-shell gate (first-run full walkthrough, or a new-feature
///    spotlight of just the unseen ids),
///  * the Settings "How to use Ayma" replay (the full tour on demand),
///  * the Developer panel preview.
class FeatureTourArgs {
  const FeatureTourArgs({this.features, this.spotlight = false});

  /// Which features to show, in order. Null → the full [tourFeatures] list.
  final List<TourFeature>? features;

  /// A new-feature spotlight (changes the framing/CTA) vs the full tour.
  final bool spotlight;
}

/// Feature tour (§11.2): a swipeable walkthrough of the app's key features,
/// each a [TourFeature] from the single `tour_content.dart` list. Shown
/// automatically ONCE, right after pre-boarding and before the first chat (the
/// main-shell gate), then replayable any time from Settings. When a later build
/// ships a new feature, the same screen runs in `spotlight` mode over just the
/// unseen ids.
///
/// On the last page's CTA (and on Skip) it marks every shown feature's
/// `feature_id` seen ([FeatureTourStore]) and hands back to wherever it was
/// launched from. Pure client-side UI: it never touches auth, the
/// server-derived `session_mode`, or the age/consent gates.
///
/// Dark-theme, large serif headline, one-line subtitle, a small demo
/// illustration per page, a page-dot progress indicator and back chevron at the
/// top, and a big pill button at the bottom. Honours reduced motion
/// (`MediaQuery.disableAnimationsOf`): every illustration falls back to its
/// final static state when animations are off.
class FeatureTourScreen extends StatefulWidget {
  const FeatureTourScreen({
    super.key,
    this.store,
    this.onContinue,
    this.features,
    this.spotlight = false,
  });

  static const path = '/tour';

  /// Injected in tests; defaults to the app-wide [featureTourStoreGlobal].
  final FeatureTourStore? store;

  /// What to do once the tour is dismissed (seen state already written).
  /// Defaults to popping back to the launching surface, or home if there is
  /// nothing to pop. Injected in tests to observe the hand-off.
  final VoidCallback? onContinue;

  /// Which features to walk through, in order. Null → the full tour.
  final List<TourFeature>? features;

  /// New-feature spotlight framing (vs the full first-run walkthrough).
  final bool spotlight;

  @override
  State<FeatureTourScreen> createState() => _FeatureTourScreenState();
}

class _FeatureTourScreenState extends State<FeatureTourScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _finishing = false;

  FeatureTourStore get _store => widget.store ?? featureTourStoreGlobal;

  List<TourFeature> get _features =>
      (widget.features == null || widget.features!.isEmpty)
      ? tourFeatures
      : widget.features!;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _back() {
    if (_page == 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  void _next() {
    if (_page >= _features.length - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await _store.markSeen(_features.map((f) => f.featureId));
    if (!mounted) return;
    (widget.onContinue ?? _defaultContinue)();
  }

  /// Back to wherever the tour was launched from, or home if it was entered by
  /// a full navigation with nothing to pop.
  void _defaultContinue() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(MainShellScreen.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final features = _features;
    final isLast = _page == features.length - 1;
    return Scaffold(
      backgroundColor: ac.bg,
      body: SafeArea(
        child: ChromeColumn(
          headerShare: 0.22,
          footerShare: 0.3,
          header: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: _page > 0
                        ? IconButton(
                            key: const ValueKey('tour-back'),
                            icon: Icon(Icons.chevron_left, color: ac.fg),
                            tooltip: 'Back',
                            onPressed: _back,
                          )
                        : null,
                  ),
                  Expanded(
                    child: Center(
                      child: _Dots(count: features.length, index: _page),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('tour-skip'),
                    onPressed: _finishing ? null : _finish,
                    child: Text(
                      widget.spotlight ? 'Dismiss' : 'Skip',
                      style: AymaType.sans(
                        size: 14,
                        weight: FontWeight.w600,
                        color: ac.fgDim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          body: PageView.builder(
            controller: _controller,
            itemCount: features.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => _TourPageView(
              feature: features[i],
              spotlight: widget.spotlight,
            ),
          ),
          footer: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('tour-next'),
                  onPressed: _finishing ? null : _next,
                  style: FilledButton.styleFrom(
                    backgroundColor: ac.accent,
                    foregroundColor: ac.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: const StadiumBorder(),
                    textStyle: AymaType.sans(size: 16, weight: FontWeight.w600),
                  ),
                  child: Text(isLast ? _lastCtaLabel : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _lastCtaLabel => widget.spotlight ? 'Got it' : 'Get started';
}

/// One page: the illustration above, the serif headline and subtitle below.
/// Scrolls instead of overflowing in short/landscape windows (`CenteredScroll`).
class _TourPageView extends StatelessWidget {
  const _TourPageView({required this.feature, required this.spotlight});

  final TourFeature feature;
  final bool spotlight;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final animate = !MediaQuery.disableAnimationsOf(context);
    return CenteredScroll(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spotlight) ...[
            Text('NEW', style: AymaType.mono(size: 11, color: ac.accent)),
            const SizedBox(height: 16),
          ],
          _TourIllustration(feature: feature, animate: animate),
          const SizedBox(height: 36),
          Text(
            feature.headline,
            textAlign: TextAlign.center,
            style: AymaType.serif(size: 38, color: ac.fg),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              feature.subtitle,
              textAlign: TextAlign.center,
              style: AymaType.sans(size: 16, height: 1.45, color: ac.fgDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _TourIllustration extends StatelessWidget {
  const _TourIllustration({required this.feature, required this.animate});

  final TourFeature feature;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    switch (feature.visual) {
      case TourVisual.orb:
        // AymaOrb reads reduced motion itself; the listening state gives the
        // gentle breathing pulse.
        return const SizedBox(
          height: 160,
          child: Center(
            child: AymaOrb(size: 132, state: AymaOrbState.listening),
          ),
        );
      case TourVisual.profileFill:
        return _ProfileFillCard(animate: animate);
      case TourVisual.chatBubbles:
        return _ChatBubblesDemo(animate: animate);
      case TourVisual.coachChips:
        return _CoachChipsDemo(animate: animate);
      case TourVisual.shield:
        return const _Glyph(Icons.shield_rounded);
      case TourVisual.icon:
        return _Glyph(feature.icon ?? Icons.star_rounded);
    }
  }
}

/// Page 2: a mock profile card whose fields fill in one after another.
class _ProfileFillCard extends StatefulWidget {
  const _ProfileFillCard({required this.animate});

  final bool animate;

  @override
  State<_ProfileFillCard> createState() => _ProfileFillCardState();
}

class _ProfileFillCardState extends State<_ProfileFillCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  static const _fields = <(String, String)>[
    ('Name', 'Maya'),
    ('Interests', 'climbing · jazz · ramen'),
    ('Vibe', 'warm, a little witty'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'YOUR PROFILE',
            style: AymaType.mono(size: 10, color: ac.accent),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _buildRow(ac, i),
          ],
        ],
      ),
    );
  }

  Widget _buildRow(AymaTokens ac, int i) {
    final (label, value) = _fields[i];
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(label, style: AymaType.sans(size: 12, color: ac.fgMute)),
        ),
        Expanded(
          child: Text(
            value,
            style: AymaType.sans(
              size: 14,
              weight: FontWeight.w500,
              color: ac.fg,
            ),
          ),
        ),
      ],
    );
    if (!widget.animate) return row;
    // Each field fades + rises in sequence.
    final start = i / _fields.length;
    final anim = CurvedAnimation(
      parent: _c,
      curve: Interval(
        start,
        (start + 0.45).clamp(0.0, 1.0),
        curve: Curves.easeOut,
      ),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - anim.value)),
          child: child,
        ),
      ),
      child: row,
    );
  }
}

/// Practice page: two or three chat bubbles animating in one after another,
/// using the shared [ChatBubble].
class _ChatBubblesDemo extends StatefulWidget {
  const _ChatBubblesDemo({required this.animate});

  final bool animate;

  @override
  State<_ChatBubblesDemo> createState() => _ChatBubblesDemoState();
}

class _ChatBubblesDemoState extends State<_ChatBubblesDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  static const _bubbles = <(bool, String)>[
    (false, 'So… first date. Where are you taking me? 😄'),
    (true, "There's this tiny ramen place I'm a little obsessed with"),
    (false, 'Sold.'),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _bubbles.length; i++) _buildBubble(ac, i),
        ],
      ),
    );
  }

  Widget _buildBubble(AymaTokens ac, int i) {
    final (mine, text) = _bubbles[i];
    final bubble = ChatBubble(
      mine: mine,
      copyText: '',
      child: Text(
        text,
        style: AymaType.message(color: mine ? ac.onAccent : ac.fg),
      ),
    );
    if (!widget.animate) return bubble;
    final start = i / _bubbles.length;
    final anim = CurvedAnimation(
      parent: _c,
      curve: Interval(
        start,
        (start + 0.45).clamp(0.0, 1.0),
        curve: Curves.easeOut,
      ),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - anim.value)),
          child: child,
        ),
      ),
      child: bubble,
    );
  }
}

/// Coach page: suggestion chips sliding in above a mock composer, plus a
/// one-line tip.
class _CoachChipsDemo extends StatefulWidget {
  const _CoachChipsDemo({required this.animate});

  final bool animate;

  @override
  State<_CoachChipsDemo> createState() => _CoachChipsDemoState();
}

class _CoachChipsDemoState extends State<_CoachChipsDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  static const _chips = <String>[
    'Ask about her trip',
    'Keep it playful',
    'Suggest Saturday',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _chips.length; i++) _buildChip(ac, i),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Tap a line — Ayma drops it in for you.',
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 12, color: ac.fgMute),
          ),
          const SizedBox(height: 14),
          // Mock composer.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: ac.bgCard,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: ac.lineSoft, width: 0.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Message…',
                    style: AymaType.sans(size: 14, color: ac.fgMute),
                  ),
                ),
                Icon(Icons.arrow_upward_rounded, size: 20, color: ac.accent),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(AymaTokens ac, int i) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: ac.accentFaint,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: ac.accentSoft, width: 0.5),
      ),
      child: Text(
        _chips[i],
        style: AymaType.sans(
          size: 13,
          weight: FontWeight.w500,
          color: ac.accent,
        ),
      ),
    );
    if (!widget.animate) return chip;
    final start = i / _chips.length;
    final anim = CurvedAnimation(
      parent: _c,
      curve: Interval(
        start,
        (start + 0.5).clamp(0.0, 1.0),
        curve: Curves.easeOut,
      ),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - anim.value)),
          child: child,
        ),
      ),
      child: chip,
    );
  }
}

/// A circular accent glyph — the generic illustration for a feature that
/// doesn't ship a bespoke animated demo (privacy, Story, models, etc.).
class _Glyph extends StatelessWidget {
  const _Glyph(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return SizedBox(
      height: 160,
      child: Center(
        child: Container(
          width: 128,
          height: 128,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ac.accentFaint,
            border: Border.all(color: ac.accentSoft, width: 1),
          ),
          child: Icon(icon, size: 64, color: ac.accent),
        ),
      ),
    );
  }
}

/// Page-dot progress indicator: the active dot widens to an accent pill.
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    // Scale the dot strip down rather than overflow: with many features (and a
    // 48px back slot + the Skip button eating the header at large text scales
    // on a 320px screen) a fixed-width Row would overflow. FittedBox keeps it
    // centered and shrinks it to fit — no fixed sizes, layout-matrix safe.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 20 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: i == index ? ac.accent : ac.lineSoft,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
        ],
      ),
    );
  }
}
