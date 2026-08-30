import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ayma_flutter/screens/credential_picker_screen.dart';
import 'package:ayma_flutter/screens/main_shell_screen.dart';
import 'package:ayma_flutter/screens/preboarding_flow_screen.dart';
import 'package:ayma_flutter/screens/splash_screen.dart';
import 'package:ayma_flutter/routing/app_router.dart';

void main() {
  testWidgets('splash routes to each placeholder / flow entry',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));

    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.tap(find.text('Go to Main shell'));
    await tester.pumpAndSettle();
    expect(find.byType(MainShellScreen), findsOneWidget);

    appRouter.go('/splash');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to Credential picker'));
    await tester.pumpAndSettle();
    expect(find.byType(CredentialPickerScreen), findsOneWidget);

    appRouter.go('/splash');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to Preboarding'));
    await tester.pumpAndSettle();
    expect(find.byType(PreboardingFlowScreen), findsOneWidget);
  });

  testWidgets('preboarding flow starts on the name step with a gated Next',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: PreboardingFlowScreen()),
    );

    expect(find.text('About you (1/6)'), findsOneWidget);
    expect(find.text('What should Ayma call you?'), findsOneWidget);

    // With a name entered, Next moves to the birthdate step.
    await tester.enterText(find.byType(TextField), 'Alex');
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('About you (2/6)'), findsOneWidget);
    expect(find.textContaining('date of birth'), findsOneWidget);
  });
}
