import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/feature_tour_store.dart';
import '../theme.dart';
import '../widgets/ayma_orb.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/overflow_guards.dart';
import 'splash_screen.dart';

/// First-launch feature tour (§11.2): a swipeable, five-page walkthrough shown
/// ONCE, before the anonymous landing, on the very first launch. It is a pure
/// client-side pre-screen — it never touches auth, the server-derived
/// `session_mode`, or the age/consent gates. The last page's "Get started" CTA
/// and the top "Skip" both mark the tour seen ([FeatureTourStore]) and hand off
/// to the normal splash → `entryRouteFor` flow.
///
/// Dark-theme, large serif headline, one-line subtitle, a small animated demo
/// illustration per page (reusing [AymaOrb] and [ChatBubble]), a page-dot
/// progress indicator and back chevron at the top, and a big pill button at the
/// bottom. Honours reduced motion (`MediaQuery.disableAnimationsOf`): every
/// illustration falls back to its final static state when animations are off.
class FeatureTourScreen extends StatefulWidget {
  const FeatureTourScreen({super.key, this.store, this.onContinue});

  static const path = '/tour';

  /// Injected in tests; defaults to the app-wide [featureTourStoreGlobal].
  final FeatureTourStore? store;

  /// What to do once the tour is dismissed (seen flag already set). Defaults to
  /// routing back to splash, which re-runs the normal entry flow. Injected in
  /// tests to observe the hand-off without a full router.
  final VoidCallback? onContinue;

  @override
  State<FeatureTourScreen> createState() => _FeatureTourScreenState();
}

class _FeatureTourScreenState extends State<FeatureTourScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _finishing = false;

  FeatureTourStore get _store => widget.store ?? featureTourStoreGlobal;

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
    if (_page >= _tourPages.length - 1) {
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
    await _store.markSeen();
    if (!mounted) return;
    (widget.onContinue ?? _defaultContinue)();
  }

  void _defaultContinue() => context.go(SplashScreen.path);

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final isLast = _page == _tourPages.length - 1;
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
                      child: _Dots(count: _tourPages.length, index: _page),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('tour-skip'),
                    onPressed: _finishing ? null : _finish,
                    child: Text(
                      'Skip',
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
            itemCount: _tourPages.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => _TourPageView(page: _tourPages[i]),
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
                  child: Text(isLast ? 'Get started' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One page's copy + which demo illustration it shows. Copy is easy to edit —
/// just this one const list.
class _TourPage {
  const _TourPage({
    required this.headline,
    required this.subtitle,
    required this.visual,
  });

  final String headline;
  final String subtitle;
  final _TourVisual visual;
}

enum _TourVisual { orb, profileFill, chatBubbles, coachChips, shield }

const _tourPages = <_TourPage>[
  _TourPage(
    headline: 'Dating, by voice',
    subtitle: 'Meet Ayma. Talk to her like a friend — no endless swiping.',
    visual: _TourVisual.orb,
  ),
  _TourPage(
    headline: 'She gets to know you',
    subtitle: 'Just talk. Ayma builds your profile as you chat.',
    visual: _TourVisual.profileFill,
  ),
  _TourPage(
    headline: 'Practice before you meet',
    subtitle:
        'Rehearse the date — text or voice — with a simulation of your match.',
    visual: _TourVisual.chatBubbles,
  ),
  _TourPage(
    headline: 'Your wingman in every chat',
    subtitle: 'Stuck on what to say? Ayma opens for you and coaches you '
        'line by line.',
    visual: _TourVisual.coachChips,
  ),
  _TourPage(
    headline: 'Yours, and only yours',
    subtitle: "18+, consent-first, private. You're always in control.",
    visual: _TourVisual.shield,
  ),
];

/// One page: the illustration above, the serif headline and subtitle below.
/// Scrolls instead of overflowing in short/landscape windows (`CenteredScroll`).
class _TourPageView extends StatelessWidget {
  const _TourPageView({required this.page});

  final _TourPage page;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final animate = !MediaQuery.disableAnimationsOf(context);
    return CenteredScroll(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TourIllustration(visual: page.visual, animate: animate),
          const SizedBox(height: 36),
          Text(
            page.headline,
            textAlign: TextAlign.center,
            style: AymaType.serif(size: 38, color: ac.fg),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              page.subtitle,
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
  const _TourIllustration({required this.visual, required this.animate});

  final _TourVisual visual;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    switch (visual) {
      case _TourVisual.orb:
        // AymaOrb reads reduced motion itself; the listening state gives the
        // gentle breathing pulse.
        return const SizedBox(
          height: 160,
          child: Center(
            child: AymaOrb(size: 132, state: AymaOrbState.listening),
          ),
        );
      case _TourVisual.profileFill:
        return _ProfileFillCard(animate: animate);
      case _TourVisual.chatBubbles:
        return _ChatBubblesDemo(animate: animate);
      case _TourVisual.coachChips:
        return _CoachChipsDemo(animate: animate);
      case _TourVisual.shield:
        return const _ShieldGlyph();
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
          child: Text(
            label,
            style: AymaType.sans(size: 12, color: ac.fgMute),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: AymaType.sans(size: 14, weight: FontWeight.w500, color: ac.fg),
          ),
        ),
      ],
    );
    if (!widget.animate) return row;
    // Each field fades + rises in sequence.
    final start = i / _fields.length;
    final anim = CurvedAnimation(
      parent: _c,
      curve: Interval(start, (start + 0.45).clamp(0.0, 1.0),
          curve: Curves.easeOut),
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

/// Page 3: two or three chat bubbles animating in one after another, using the
/// shared [ChatBubble].
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
      curve: Interval(start, (start + 0.45).clamp(0.0, 1.0),
          curve: Curves.easeOut),
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

/// Page 4: suggestion chips sliding in above a mock composer, plus a one-line
/// tip.
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
        style: AymaType.sans(size: 13, weight: FontWeight.w500, color: ac.accent),
      ),
    );
    if (!widget.animate) return chip;
    final start = i / _chips.length;
    final anim = CurvedAnimation(
      parent: _c,
      curve: Interval(start, (start + 0.5).clamp(0.0, 1.0),
          curve: Curves.easeOut),
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

/// Page 5: a shield/lock glyph — privacy, 18+, consent-first.
class _ShieldGlyph extends StatelessWidget {
  const _ShieldGlyph();

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
          child: Icon(Icons.shield_rounded, size: 64, color: ac.accent),
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
    return Row(
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
    );
  }
}
