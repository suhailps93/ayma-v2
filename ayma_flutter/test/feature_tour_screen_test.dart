import 'package:ayma_flutter/screens/feature_tour_screen.dart';
import 'package:ayma_flutter/services/feature_tour_store.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Pumped WITHOUT `pumpAndSettle`: page 1's AymaOrb animates forever, so
  // settling would hang. Explicit frame pumps instead.
  Future<void> advance(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tour-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Widget host({
    required FeatureTourStore store,
    required VoidCallback onContinue,
    bool reducedMotion = false,
  }) {
    return MaterialApp(
      theme: AymaTheme.dark,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: FeatureTourScreen(store: store, onContinue: onContinue),
        ),
      ),
    );
  }

  testWidgets('pages advance on Next and the CTA becomes Get started on the '
      'last page', (tester) async {
    final store = FeatureTourStore();
    await tester.pumpWidget(host(store: store, onContinue: () {}));
    await tester.pump(const Duration(milliseconds: 400));

    // Page 1: first headline, no back chevron yet, CTA reads "Next".
    expect(find.text('Dating, by voice'), findsOneWidget);
    expect(find.byKey(const ValueKey('tour-back')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Next'), findsOneWidget);

    await advance(tester);
    // Page 2: headline updated (so the dots moved with it), back chevron shown.
    expect(find.text('She gets to know you'), findsOneWidget);
    expect(find.byKey(const ValueKey('tour-back')), findsOneWidget);

    await advance(tester); // page 3
    await advance(tester); // page 4
    await advance(tester); // page 5 (last)
    expect(find.text('Yours, and only yours'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Get started'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Next'), findsNothing);
  });

  testWidgets("the last page's CTA marks the tour seen and routes onward",
      (tester) async {
    final store = FeatureTourStore();
    var continued = 0;
    await tester.pumpWidget(host(store: store, onContinue: () => continued++));
    await tester.pump(const Duration(milliseconds: 400));

    await advance(tester); // 2
    await advance(tester); // 3
    await advance(tester); // 4
    await advance(tester); // 5
    expect(store.seen, isFalse);
    await tester.tap(find.byKey(const ValueKey('tour-next'))); // Get started
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.seen, isTrue);
    expect(continued, 1);
  });

  testWidgets('Skip marks the tour seen and routes onward', (tester) async {
    final store = FeatureTourStore();
    var continued = 0;
    await tester.pumpWidget(host(store: store, onContinue: () => continued++));
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.seen, isFalse);
    await tester.tap(find.byKey(const ValueKey('tour-skip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.seen, isTrue);
    expect(continued, 1);
  });

  testWidgets('reduced motion renders the demo illustrations static',
      (tester) async {
    final store = FeatureTourStore();
    await tester.pumpWidget(
      host(store: store, onContinue: () {}, reducedMotion: true),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // Reach page 2 (the auto-filling profile card).
    await advance(tester);
    expect(find.text('She gets to know you'), findsOneWidget);

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
