import 'package:ayma_flutter/widgets/out_of_credits.dart';
import 'package:flutter/material.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Widget _host({required WidgetBuilder body}) {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (c, _) => Scaffold(body: body(c)),
      ),
      GoRoute(
        path: '/profile/usage',
        builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
      ),
    ],
  );
  return MaterialApp.router(theme: AymaTheme.light, routerConfig: router);
}

void main() {
  testWidgets('showOutOfCreditsSnack shows the message and a Reload action '
      'that opens /profile/usage', (tester) async {
    await tester.pumpWidget(
      _host(
        body: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showOutOfCreditsSnack(context),
            child: const Text('trigger'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pump(); // surface the snack
    await tester.pump(const Duration(seconds: 1)); // finish the entrance anim

    expect(
      find.text("You're out of credits — tap Reload to top up."),
      findsOneWidget,
    );
    expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget);

    await tester.tap(find.widgetWithText(SnackBarAction, 'Reload'));
    await tester.pumpAndSettle();

    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets('showOutOfCreditsSnack honours a custom message', (tester) async {
    await tester.pumpWidget(
      _host(
        body: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showOutOfCreditsSnack(
              context,
              message: 'No voice credits left.',
            ),
            child: const Text('trigger'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('No voice credits left.'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Reload'), findsOneWidget);
  });

  testWidgets('OutOfCreditsBanner renders a Reload button that opens '
      '/profile/usage', (tester) async {
    await tester.pumpWidget(
      _host(body: (_) => const Center(child: OutOfCreditsBanner())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("You're out of credits — tap Reload to top up."),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Reload'));
    await tester.pumpAndSettle();

    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets('OutOfCreditsBanner uses onReload when given', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      _host(
        body: (_) =>
            Center(child: OutOfCreditsBanner(onReload: () => tapped++)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Reload'));
    await tester.pumpAndSettle();

    expect(tapped, 1);
    expect(find.text('USAGE SCREEN'), findsNothing);
  });
  testWidgets('banner stays compact with production theme on a narrow phone', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        body: (_) => const Center(
          child: SizedBox(width: 320, child: OutOfCreditsBanner()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(OutOfCreditsBanner)).height,
      lessThan(160),
    );
    expect(
      tester
          .getSize(find.text("You're out of credits — tap Reload to top up."))
          .width,
      greaterThan(100),
    );
  });

  testWidgets('Reload closes a chat sheet before showing credits', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        body: (context) => TextButton(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            builder: (_) => const OutOfCreditsBanner(),
          ),
          child: const Text('Open chat'),
        ),
      ),
    );
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reload'));
    await tester.pumpAndSettle();
    expect(find.text('USAGE SCREEN'), findsOneWidget);
    expect(find.byType(OutOfCreditsBanner), findsNothing);
  });
}
