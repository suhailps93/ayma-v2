import 'package:ayma_flutter/screens/underage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Jobs pass (cluster 10) layout assertions for the under-18 hard stop:
/// screen edge 20, body -> "Read the Terms" gap 24, Sign out tap target >= 44.
/// Behaviour (the age gate, sign-out) is covered by test/age_gate_test.dart and
/// is unchanged here.
void main() {
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: UnderageScreen(signOut: () async {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('scroll-view edge is 20 on every side', (tester) async {
    await pump(tester);
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .padding,
      const EdgeInsets.all(20),
    );
  });

  testWidgets('body -> Read the Terms gap is 24', (tester) async {
    await pump(tester);
    final bodyBottom = tester
        .getBottomLeft(find.textContaining("come back when you're 18"))
        .dy;
    final termsTop =
        tester.getTopLeft(find.byKey(const Key('underage_terms'))).dy;
    expect(termsTop - bodyBottom, moreOrLessEquals(24, epsilon: 0.5));
  });

  testWidgets('Sign out TextButton renders >= 44 tall (M3 padded target)', (
    tester,
  ) async {
    await pump(tester);
    expect(
      tester.getSize(find.byKey(const Key('underage_sign_out'))).height,
      greaterThanOrEqualTo(44),
    );
  });
}
