import 'package:ayma_flutter/services/fresh_data.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/freshness_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('live renders nothing', (tester) async {
    await tester.pumpWidget(
      _wrap(const FreshnessIndicator(state: FreshnessState.live)),
    );
    expect(find.text('Updating…'), findsNothing);
    expect(find.text('Offline — showing saved data'), findsNothing);
    expect(find.text("Couldn't refresh"), findsNothing);
  });

  testWidgets('syncing shows Updating', (tester) async {
    await tester.pumpWidget(
      _wrap(const FreshnessIndicator(state: FreshnessState.syncing)),
    );
    expect(find.text('Updating…'), findsOneWidget);
  });

  testWidgets('stale shows offline caption', (tester) async {
    await tester.pumpWidget(
      _wrap(const FreshnessIndicator(state: FreshnessState.stale)),
    );
    expect(find.text('Offline — showing saved data'), findsOneWidget);
  });

  testWidgets('refused shows retry when provided', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(FreshnessIndicator(
        state: FreshnessState.refused,
        onRetry: () => taps++,
      )),
    );
    expect(find.text("Couldn't refresh"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(taps, 1);
  });

  testWidgets('fromFresh uses FreshData.state', (tester) async {
    await tester.pumpWidget(
      _wrap(FreshnessIndicator.fromFresh(
        const FreshData<int>(data: 1, isFromCache: true),
      )),
    );
    expect(find.text('Offline — showing saved data'), findsOneWidget);
  });
}
