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
}
