import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps a bare [ScoreBar] inside a themed host and returns its two fill
/// [Container]s: [track, fill] (Stack children in build order).
Future<List<Container>> _pump(WidgetTester tester, ScoreBar bar) async {
  await tester.pumpWidget(MaterialApp(
    theme: AymaTheme.light,
    home: Scaffold(body: Center(child: bar)),
  ));
  return tester
      .widgetList<Container>(
          find.descendant(of: find.byType(ScoreBar), matching: find.byType(Container)))
      .toList();
}

void main() {
  testWidgets('flat mode: fills with a single accent color, out of 10',
      (tester) async {
    final containers = await _pump(tester, const ScoreBar(value: 7.1, max: 10));
    final track = containers[0];
    final fill = containers[1];

    expect(track.color, AymaTheme.light.extension<AymaTokens>()!.lineSoft);
    expect(fill.color, AymaTheme.light.extension<AymaTokens>()!.accent);

    final widthFactor =
        tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor;
    expect(widthFactor, closeTo(0.71, 1e-9));
  });

  testWidgets('flat mode: honors a custom color and track color',
      (tester) async {
    final containers = await _pump(
      tester,
      const ScoreBar(
        value: 4,
        max: 10,
        color: Colors.purple,
        trackColor: Colors.grey,
      ),
    );
    expect(containers[0].color, Colors.grey);
    expect(containers[1].color, Colors.purple);
  });

  testWidgets('banded mode: colorFor picks green/amber/red by value, out of 100',
      (tester) async {
    Color band(double s) =>
        s >= 60 ? Colors.green : (s >= 40 ? Colors.orange : Colors.red);

    for (final entry in {72.0: Colors.green, 50.0: Colors.orange, 20.0: Colors.red}
        .entries) {
      final containers = await _pump(
        tester,
        ScoreBar(
          value: entry.key,
          max: 100,
          height: 6,
          colorFor: (context, value, max) => band(value),
        ),
      );
      expect(containers[1].color, entry.value,
          reason: 'value ${entry.key} should band to ${entry.value}');
    }
  });

  testWidgets('clamps the fill fraction for out-of-range values',
      (tester) async {
    await _pump(tester, const ScoreBar(value: 15, max: 10));
    expect(
        tester
            .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
            .widthFactor,
        1.0);

    await _pump(tester, const ScoreBar(value: -2, max: 10));
    expect(
        tester
            .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
            .widthFactor,
        0.0);
  });
}
