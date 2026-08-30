import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/preboarding_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/routing/app_router.dart';

void main() {
  testWidgets('router starts on splash and navigates to placeholders',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: appRouter),
    );

    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.tap(find.text('Go to Preboarding'));
    await tester.pumpAndSettle();
    expect(find.byType(PreboardingScreen), findsOneWidget);

    await tester.tap(find.text('Go to Main shell'));
    await tester.pumpAndSettle();
    expect(find.byType(MainShellScreen), findsOneWidget);
  });
}
