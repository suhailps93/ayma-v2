import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:ayma_flutter/widgets/ayma_tab_bar.dart';
import 'package:ayma_flutter/widgets/coach_mark_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store double — no Firebase. Records what the engine marks seen.
class _FakeTourStore extends FeatureTourStore {
  final Set<String> seen = {};
  List<String>? lastMarked;

  @override
  Future<Set<String>> loadSeen() async => seen;

  @override
  Future<void> markSeen(Iterable<String> ids) async {
    lastMarked = ids.toList();
    seen.addAll(ids);
  }

  @override
  Future<void> reset() async => seen.clear();
}

// Step A anchors a real (dummy) widget; step B points at an anchor nothing
// mounts (must skip); step C is a centered closer (no anchor).
const _features = <TourFeature>[
  TourFeature(
    featureId: 'a',
    headline: 'Alpha',
    subtitle: 'first',
    anchorId: TourAnchors.homeOrb,
  ),
  TourFeature(
    featureId: 'b',
    headline: 'Bravo',
    subtitle: 'second',
    anchorId: 'ghost_anchor_never_mounted',
  ),
  TourFeature(
    featureId: 'c',
    headline: 'Charlie',
    subtitle: 'third',
    icon: Icons.star_rounded,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host({
    required FeatureTourStore store,
    required VoidCallback onFinish,
    List<TourFeature> features = _features,
    bool spotlight = false,
    bool reducedMotion = false,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
          child: Scaffold(
            body: Stack(
              children: [
                // A real target near the bottom for step A's spotlight.
                Positioned(
                  left: 24,
                  bottom: 24,
                  child: SizedBox(
                    key: TourAnchors.keyFor(TourAnchors.homeOrb),
                    width: 64,
                    height: 64,
                  ),
                ),
                Positioned.fill(
                  child: CoachMarkOverlay(
                    store: store,
                    onFinish: onFinish,
                    features: features,
                    spotlight: spotlight,
                    // A missing anchor should skip within a few pumps here (the
                    // on-device default is generous, to ride out transitions).
                    maxMeasureAttempts: 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Pumped WITHOUT `pumpAndSettle`: the spotlight ring pulses forever, so
  // settling would hang. Explicit frame pumps instead — several, because the
  // engine measures each step in a post-frame callback (and a skipped
  // missing-target step chains one more), then flips `_ready` on the next.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> advance(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('coach-next')));
    await settle(tester);
  }

  testWidgets('spotlights the target by key and shows its copy', (tester) async {
    await tester.pumpWidget(host(store: _FakeTourStore(), onFinish: () {}));
    await settle(tester);

    // The scrim/spotlight layer is painted, and the first step's copy shows.
    expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('1 of 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-skip')), findsOneWidget);
  });

  testWidgets('Next advances, and a missing-target step is skipped without '
      'crashing', (tester) async {
    await tester.pumpWidget(host(store: _FakeTourStore(), onFinish: () {}));
    await settle(tester);

    expect(find.text('Alpha'), findsOneWidget);
    await advance(tester);

    // Step B (anchor never mounted) is skipped — we land on Charlie, and Bravo
    // never renders.
    expect(find.text('Bravo'), findsNothing);
    expect(find.text('Charlie'), findsOneWidget);
    // Last step: the CTA reads "Done" (not "Next"-only framing changes).
    expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
  });

  testWidgets('completing the last step marks every shown feature seen and '
      'finishes', (tester) async {
    final store = _FakeTourStore();
    var finished = 0;
    await tester.pumpWidget(host(store: store, onFinish: () => finished++));
    await settle(tester);

    await advance(tester); // A -> (B skipped) -> C
    expect(find.text('Charlie'), findsOneWidget);
    expect(store.seen, isEmpty);

    await tester.tap(find.byKey(const ValueKey('coach-next'))); // Done
    await tester.pump();
    await settle(tester);

    expect(store.seen, {'a', 'b', 'c'});
    expect(finished, 1);
  });

  testWidgets('Skip exits and marks every feature seen', (tester) async {
    final store = _FakeTourStore();
    var finished = 0;
    await tester.pumpWidget(host(store: store, onFinish: () => finished++));
    await settle(tester);

    expect(store.seen, isEmpty);
    await tester.tap(find.byKey(const ValueKey('coach-skip')));
    await tester.pump();
    await settle(tester);

    expect(store.seen, {'a', 'b', 'c'});
    expect(finished, 1);
  });

  testWidgets('spotlight mode shows the NEW framing and a Got it CTA', (
    tester,
  ) async {
    const only = [
      TourFeature(
        featureId: 'c',
        headline: 'Charlie',
        subtitle: 'third',
        icon: Icons.star_rounded,
      ),
    ];
    await tester.pumpWidget(host(
      store: _FakeTourStore(),
      onFinish: () {},
      features: only,
      spotlight: true,
    ));
    await settle(tester);

    expect(find.text('NEW'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Got it'), findsOneWidget);
  });

  // A host that layers the overlay over a tappable anchor and a full-screen
  // background sensor, mirroring the real shell (overlay as a sibling above the
  // app) so press-through hit testing behaves the same.
  Widget pressHost({
    required FeatureTourStore store,
    required VoidCallback onAnchorTap,
    required VoidCallback onBgTap,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onBgTap,
              ),
            ),
            Positioned(
              left: 24,
              bottom: 24,
              child: GestureDetector(
                key: TourAnchors.keyFor(TourAnchors.homeOrb),
                behavior: HitTestBehavior.opaque,
                onTap: onAnchorTap,
                child: const SizedBox(width: 64, height: 64),
              ),
            ),
            Positioned.fill(
              child: CoachMarkOverlay(
                store: store,
                onFinish: () {},
                features: _features,
                maxMeasureAttempts: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('tapping the cutout presses through to the real widget AND '
      'advances the tour', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var anchorTaps = 0;
    var bgTaps = 0;
    await tester.pumpWidget(pressHost(
      store: _FakeTourStore(),
      onAnchorTap: () => anchorTaps++,
      onBgTap: () => bgTaps++,
    ));
    await settle(tester);
    expect(find.text('Alpha'), findsOneWidget);

    // Tap the spotlighted anchor (bottom-left 64x64 box, centered).
    await tester.tapAt(const Offset(56, 544));
    await settle(tester);

    // The real widget behind the cutout received the tap (press-through)...
    expect(anchorTaps, 1);
    expect(bgTaps, 0);
    // ...and the tour advanced (A -> B skipped -> Charlie).
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('tapping the dimmed scrim is absorbed — no press-through, no '
      'advance', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var anchorTaps = 0;
    var bgTaps = 0;
    await tester.pumpWidget(pressHost(
      store: _FakeTourStore(),
      onAnchorTap: () => anchorTaps++,
      onBgTap: () => bgTaps++,
    ));
    await settle(tester);
    expect(find.text('Alpha'), findsOneWidget);

    // Tap far from the cutout (bottom-left) and the callout (top) — pure scrim.
    await tester.tapAt(const Offset(700, 300));
    await settle(tester);

    expect(bgTaps, 0); // blocked by the scrim
    expect(anchorTaps, 0);
    expect(find.text('Alpha'), findsOneWidget); // did not advance
  });

  testWidgets('reduced motion renders without crashing', (tester) async {
    await tester.pumpWidget(
      host(store: _FakeTourStore(), onFinish: () {}, reducedMotion: true),
    );
    await settle(tester);

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-spotlight')), findsOneWidget);
  });

  // Bug A regression: the `home_orb` anchor must resolve to the real centre
  // ORB, not one of the tab icon buttons (the Messages/envelope icon). The
  // shell hands `AymaTabBar` its tour anchor keys by tab index; tab 0 is the
  // orb, tab 2 the Messages icon.
  testWidgets('home_orb anchor is on the orb, not a tab icon', (tester) async {
    final anchorKeys = <int, GlobalKey>{
      0: TourAnchors.keyFor(TourAnchors.homeOrb),
      1: TourAnchors.keyFor(TourAnchors.exploreTab),
      2: TourAnchors.keyFor(TourAnchors.messagesTab),
      3: TourAnchors.keyFor(TourAnchors.profileTab),
      AymaTabBar.kBellAnchor: TourAnchors.keyFor(TourAnchors.notificationsBell),
    };
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: Scaffold(
        bottomNavigationBar: AymaTabBar(
          index: 0,
          voice: null,
          onSelected: (_) {},
          anchorKeys: anchorKeys,
        ),
      ),
    ));
    await tester.pump();

    // The orb key wraps the real AymaOrb...
    expect(
      find.descendant(
        of: find.byKey(TourAnchors.keyFor(TourAnchors.homeOrb)),
        matching: find.byType(AymaOrb),
      ),
      findsOneWidget,
    );
    // ...and the Messages/envelope key does NOT (it's a different element).
    expect(
      find.descendant(
        of: find.byKey(TourAnchors.keyFor(TourAnchors.messagesTab)),
        matching: find.byType(AymaOrb),
      ),
      findsNothing,
    );
    // The resolved rects are distinct and the orb sits to the right of the
    // Messages icon (it's the visual centre of the bar).
    final orbRect = TourAnchors.rectFor(TourAnchors.homeOrb);
    final messagesRect = TourAnchors.rectFor(TourAnchors.messagesTab);
    expect(orbRect, isNotNull);
    expect(messagesRect, isNotNull);
    expect(orbRect == messagesRect, isFalse);
    expect(orbRect!.center.dx, greaterThan(messagesRect!.center.dx));
  });

  // Bug B regression: the overlay is hosted ABOVE the Navigator, so a route
  // pushed while the tour is up must NOT tear the callout down — it stays open
  // across pages (founder's "the pop-up goes away when you click to a different
  // page").
  testWidgets('the callout persists across a route push', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      navigatorKey: nav,
      // Mirrors `TourHost`: the overlay is a sibling ABOVE the Navigator.
      builder: (context, child) => Stack(
        children: [
          child!,
          Positioned.fill(
            child: CoachMarkOverlay(
              store: _FakeTourStore(),
              onFinish: () {},
              features: const [
                TourFeature(
                  featureId: 'c',
                  headline: 'Charlie',
                  subtitle: 'third',
                  icon: Icons.star_rounded,
                ),
              ],
              maxMeasureAttempts: 3,
            ),
          ),
        ],
      ),
      home: const Scaffold(body: Center(child: Text('Page one'))),
    ));
    await settle(tester);
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('Page one'), findsOneWidget);

    // Push a second page on top of the Navigator.
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('Page two'))),
      ),
    );
    await settle(tester);

    // The new page is up AND the floating callout is still open over it.
    expect(find.text('Page two'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
  });

  // Bug C regression: the callout must not overflow at text scale 2.0 on the
  // smallest supported window — it scrolls/wraps instead.
  testWidgets('callout renders without overflow at text scale 2.0',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 24,
                  bottom: 24,
                  child: SizedBox(
                    key: TourAnchors.keyFor(TourAnchors.homeOrb),
                    width: 64,
                    height: 64,
                  ),
                ),
                Positioned.fill(
                  child: CoachMarkOverlay(
                    store: _FakeTourStore(),
                    onFinish: () {},
                    features: _features,
                    maxMeasureAttempts: 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);

    expect(find.text('Alpha'), findsOneWidget);
    // No RenderFlex overflow / layout exception was thrown while laying out
    // the callout at 2.0.
    expect(tester.takeException(), isNull);
  });
}
