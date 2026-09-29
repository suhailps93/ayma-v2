import 'package:ayma_flutter/theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Founder issue (iPhone testers): "no way to go back from one screen to
/// another". No iOS device in CI — these tests pin the mechanism instead:
/// the app theme must hand iOS the Cupertino transition (whose interactive
/// edge-swipe-back is the iPhone's only systemwide back gesture), and a
/// go_router-pushed MaterialPage must actually pop from an edge swipe.
void main() {
  testWidgets('theme pins Cupertino transitions (swipe-back) for iOS and macOS',
      (tester) async {
    for (final theme in [
      AymaTheme.light,
      AymaTheme.dark,
      AymaTheme.lightWithAccent(const Color(0xFF3A7BD5)),
      AymaTheme.darkWithAccent(const Color(0xFF3A7BD5)),
    ]) {
      final builders = theme.pageTransitionsTheme.builders;
      expect(builders[TargetPlatform.iOS],
          isA<CupertinoPageTransitionsBuilder>());
      expect(builders[TargetPlatform.macOS],
          isA<CupertinoPageTransitionsBuilder>());
      // Android keeps its current feel (framework default: predictive back).
      expect(builders[TargetPlatform.android],
          isA<PredictiveBackPageTransitionsBuilder>());
    }
  });

  testWidgets('iOS edge swipe pops a go_router-pushed route',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/detail'),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/detail',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('DETAIL'))),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: AymaTheme.dark,
      routerConfig: router,
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL'), findsOneWidget);

    // Native iOS back gesture: drag from the left screen edge to the right.
    final gesture = await tester.startGesture(const Offset(5, 300));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    // Must be restored before the test body ends (the framework's
    // foundation-variable invariant check runs before tearDowns).
    debugDefaultTargetPlatformOverride = null;

    expect(find.text('DETAIL'), findsNothing);
    expect(find.text('OPEN'), findsOneWidget);
  });

  testWidgets('the same edge drag does not pop on Android (feel unchanged)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/detail'),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/detail',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('DETAIL'))),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: AymaTheme.dark,
      routerConfig: router,
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(5, 300));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    // Android's back is the system gesture/button, not an in-app edge drag.
    expect(find.text('DETAIL'), findsOneWidget);
  });
}
