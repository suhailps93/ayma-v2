import 'package:ayma_flutter/widgets/staggered.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FadeSlideIn starts hidden and ends fully visible', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FadeSlideIn(
          delay: Duration(milliseconds: 100),
          child: Text('hello'),
        ),
      ),
    ));

    // First frame: still within the delay window -> invisible.
    Opacity op() => tester.widget<Opacity>(find.byType(Opacity));
    expect(op().opacity, 0.0);

    await tester.pump(const Duration(milliseconds: 60));
    expect(op().opacity, 0.0); // delay not elapsed yet

    await tester.pumpAndSettle();
    expect(op().opacity, 1.0);
    expect(find.text('hello'), findsOneWidget);
  });

  test('staggerDelay ramps then caps', () {
    expect(staggerDelay(0).inMilliseconds, 0);
    expect(staggerDelay(3).inMilliseconds, 120);
    expect(staggerDelay(100).inMilliseconds, 320); // capped
  });
}
