import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayma_flutter/main.dart';

void main() {
  testWidgets('App boots to a blank Scaffold', (WidgetTester tester) async {
    await tester.pumpWidget(const AymaApp());

    expect(find.byType(Scaffold), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
