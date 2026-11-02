import 'package:ayma_flutter/core/app_recovery.dart';
import 'package:ayma_flutter/widgets/graceful_error.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A widget whose `build` throws, to exercise the global `ErrorWidget.builder`
/// path the way a real failed-rebuild does.
class _ThrowsOnBuild extends StatelessWidget {
  const _ThrowsOnBuild();
  @override
  Widget build(BuildContext context) => throw StateError('boom in build');
}

void main() {
  testWidgets('gracefulErrorWidget renders a calm fallback, never an ErrorWidget',
      (tester) async {
    await tester.pumpWidget(
      gracefulErrorWidget(FlutterErrorDetails(exception: StateError('x'))),
    );
    expect(find.text("Something didn't load"), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'GATE-RED: when a build throws, the override shows the fallback, not the red block',
      (tester) async {
    // Restore inside the body (flutter_test verifies ErrorWidget.builder is
    // back to default before the test ends — a tearDown runs too late).
    final previous = ErrorWidget.builder;
    ErrorWidget.builder = gracefulErrorWidget;
    try {
      await tester.pumpWidget(const _ThrowsOnBuild());

      // The thrown build is replaced by the graceful fallback — no red ErrorWidget.
      expect(find.text("Something didn't load"), findsOneWidget);
      expect(find.byType(ErrorWidget), findsNothing);
      // Reporting path is unaffected: the framework still recorded the exception.
      expect(tester.takeException(), isStateError);
    } finally {
      ErrorWidget.builder = previous;
    }
  });

  testWidgets(
      'SWEEP91-J1R S2: the fallback renders under a Material canvas (no debug underlines)',
      (tester) async {
    await tester.pumpWidget(
      gracefulErrorWidget(FlutterErrorDetails(exception: StateError('x'))),
    );
    // The yellow "no Material" debug underlines QA saw on the full-screen error
    // mean the Text had no Material ancestor. The fallback now brings its own
    // Material canvas (and Directionality), so every Text sits under a Material.
    expect(
      find.ancestor(
        of: find.text("Something didn't load"),
        matching: find.byType(Material),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'SWEEP91-J1R S2: tapping Go back actually recovers (bumps the app-root epoch)',
      (tester) async {
    // QA (dbd8154): "Go back" rendered but tapping left an identical frame — it
    // did not pop/navigate. The recovery must force the app root to rebuild
    // (so the frame changes even when the Router itself was torn out), which it
    // signals by bumping [appRecoveryEpoch]. Assert the tap bumps it.
    final before = appRecoveryEpoch.value;
    await tester.pumpWidget(
      gracefulErrorWidget(FlutterErrorDetails(exception: StateError('x'))),
    );
    final goBack = find.text('Go back');
    expect(goBack, findsOneWidget);
    await tester.tap(goBack);
    await tester.pump();
    expect(appRecoveryEpoch.value, greaterThan(before),
        reason: 'Go back must trigger an app-root rebuild, not a no-op');
    expect(tester.takeException(), isNull);
  });
}
