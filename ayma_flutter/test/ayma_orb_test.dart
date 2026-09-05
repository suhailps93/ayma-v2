import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/ayma_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AymaTheme.dark,
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('renders and animates in every state without throwing',
      (tester) async {
    for (final state in OrbState.values) {
      await tester.pumpWidget(host(AymaOrb(size: 120, state: state)));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(AymaOrb), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the active shortcut still paints (tab-bar usage)',
      (tester) async {
    await tester.pumpWidget(host(const AymaOrb(size: 22, active: true)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
