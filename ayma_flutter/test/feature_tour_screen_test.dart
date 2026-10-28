import 'package:ayma_flutter/screens/feature_tour_screen.dart';
import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:ayma_flutter/services/tour_content.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store double — no Firebase. Records what the screen marks seen.
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

const _features = <TourFeature>[
  TourFeature(
    featureId: 'a',
    headline: 'Alpha',
    subtitle: 'first',
    visual: TourVisual.orb,
  ),
  TourFeature(
    featureId: 'b',
    headline: 'Bravo',
    subtitle: 'second',
    visual: TourVisual.profileFill,
  ),
  TourFeature(
    featureId: 'c',
    headline: 'Charlie',
    subtitle: 'third',
    visual: TourVisual.icon,
    icon: Icons.star_rounded,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Pumped WITHOUT `pumpAndSettle`: the AymaOrb animates forever, so settling
  // would hang. Explicit frame pumps instead.
  Future<void> advance(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tour-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Widget host({
    required FeatureTourStore store,
    required VoidCallback onContinue,
    List<TourFeature> features = _features,
    bool spotlight = false,
    bool reducedMotion = false,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: FeatureTourScreen(
            store: store,
            onContinue: onContinue,
            features: features,
            spotlight: spotlight,
          ),
        ),
      ),
    );
  }

  testWidgets('pages advance on Next and the CTA becomes Get started on the '
      'last page', (tester) async {
    await tester.pumpWidget(host(store: _FakeTourStore(), onContinue: () {}));
    await tester.pump(const Duration(milliseconds: 400));

    // Page 1: first headline, no back chevron yet, CTA reads "Next".
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.byKey(const ValueKey('tour-back')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Next'), findsOneWidget);

    await advance(tester);
    // Page 2: headline updated (so the dots moved with it), back chevron shown.
    expect(find.text('Bravo'), findsOneWidget);
    expect(find.byKey(const ValueKey('tour-back')), findsOneWidget);

    await advance(tester); // page 3 (last)
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Next'), findsNothing);
  });

  testWidgets("the last page's CTA marks every shown feature seen and routes "
      'onward', (tester) async {
    final store = _FakeTourStore();
    var continued = 0;
    await tester.pumpWidget(host(store: store, onContinue: () => continued++));
    await tester.pump(const Duration(milliseconds: 400));

    await advance(tester); // 2
    await advance(tester); // 3 (last)
    expect(store.seen, isEmpty);
    await tester.tap(find.byKey(const ValueKey('tour-next'))); // Get started
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.lastMarked, ['a', 'b', 'c']);
    expect(store.seen, {'a', 'b', 'c'});
    expect(continued, 1);
  });

  testWidgets('Skip marks every shown feature seen and routes onward',
      (tester) async {
    final store = _FakeTourStore();
    var continued = 0;
    await tester.pumpWidget(host(store: store, onContinue: () => continued++));
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.seen, isEmpty);
    await tester.tap(find.byKey(const ValueKey('tour-skip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.seen, {'a', 'b', 'c'});
    expect(continued, 1);
  });

  testWidgets('spotlight mode shows the NEW framing and a Got it CTA, and '
      'marks only the spotlighted ids', (tester) async {
    final store = _FakeTourStore();
    // A single new feature, as the new-feature spotlight would pass.
    const only = [
      TourFeature(
        featureId: 'c',
        headline: 'Charlie',
        subtitle: 'third',
        visual: TourVisual.icon,
        icon: Icons.star_rounded,
      ),
    ];
    await tester.pumpWidget(host(
      store: store,
      onContinue: () {},
      features: only,
      spotlight: true,
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget); // Skip label in spotlight
    expect(find.widgetWithText(FilledButton, 'Got it'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tour-next'))); // Got it
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.seen, {'c'});
  });

  testWidgets('reduced motion renders the demo illustrations static',
      (tester) async {
    await tester.pumpWidget(
      host(store: _FakeTourStore(), onContinue: () {}, reducedMotion: true),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // Reach page 2 (the auto-filling profile card).
    await advance(tester);
    expect(find.text('Bravo'), findsOneWidget);

    // The mock field value is present...
    expect(find.text('Maya'), findsOneWidget);
    // ...and NOT wrapped in the fade/slide Opacity used for the animated path
    // — i.e. it renders in its final static state.
    expect(
      find.ancestor(
        of: find.text('Maya'),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });
}
