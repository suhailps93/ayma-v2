import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:ayma_flutter/services/tour_anchors.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/theme.dart';
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
}
