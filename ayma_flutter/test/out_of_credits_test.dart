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
        path: '/profile/usage/plans',
        builder: (_, __) => const Scaffold(body: Text('USAGE SCREEN')),
      ),
    ],
  );
  return MaterialApp.router(theme: AymaTheme.light, routerConfig: router);
}

void main() {
  testWidgets('showOutOfCreditsSheet explains what is still free and Upgrade '
      'opens /profile/usage/plans', (tester) async {
    await tester.pumpWidget(
      _host(
        body: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showOutOfCreditsSheet(context),
            child: const Text('trigger'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();

    expect(find.text("You're out of credits"), findsOneWidget);
    expect(find.textContaining('browse and find other users'), findsOneWidget);
    expect(find.textContaining('chat with them'), findsOneWidget);
    expect(find.textContaining('needs credits'), findsOneWidget);
    expect(find.text('Keep exploring'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
    await tester.pumpAndSettle();

    expect(find.text('USAGE SCREEN'), findsOneWidget);
  });

  testWidgets('Keep exploring dismisses the sheet without navigating', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        body: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showOutOfCreditsSheet(context),
            child: const Text('trigger'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep exploring'));
    await tester.pumpAndSettle();

    expect(find.text("You're out of credits"), findsNothing);
    expect(find.text('USAGE SCREEN'), findsNothing);
  });

  testWidgets('OutOfCreditsBanner renders an Upgrade button that opens '
      '/profile/usage/plans', (tester) async {
    await tester.pumpWidget(
      _host(body: (_) => const Center(child: OutOfCreditsBanner())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("You're out of credits."),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
    await tester.pumpAndSettle();
    expect(find.text('Keep exploring'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade').last);
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

    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
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
          .getSize(find.text("You're out of credits."))
          .width,
      greaterThan(80),
    );
  });

  testWidgets('Upgrade closes a chat sheet before showing credits', (
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
    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade').last);
    await tester.pumpAndSettle();
    expect(find.text('USAGE SCREEN'), findsOneWidget);
    expect(find.byType(OutOfCreditsBanner), findsNothing);
  });
}
