import 'package:ayma_flutter/widgets/out_of_credits.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show PeriodUnit;
import 'package:shared_preferences/shared_preferences.dart';
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

const _offer = TrialOffer(
  plan: PlanOption(
    name: 'Pro',
    productId: 'ayma_pro_monthly',
    price: r'$20 / month',
    blurb: 'b',
    credits: 1400,
  ),
  unit: PeriodUnit.day,
  value: 30,
);

class _FakeRc extends RevenueCatService {
  _FakeRc({this.offer, this.sub, this.fail = false});
  final TrialOffer? offer;
  final ActiveSubscription? sub;
  final bool fail;

  @override
  bool get enabled => true;

  @override
  Future<TrialOffer?> proTrialOffer() async {
    if (fail) throw StateError('boom');
    return offer;
  }

  @override
  Future<ActiveSubscription?> activeSubscription() async => sub;
}

Future<void> _openSheet(WidgetTester tester, RevenueCatService rc) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    _host(
      body: (context) => Center(
        child: ElevatedButton(
          onPressed: () => showOutOfCreditsSheet(context, service: rc),
          child: const Text('trigger'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('trigger'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sheet shows the Pro trial hint and Start free trial when '
      'eligible', (tester) async {
    await _openSheet(tester, _FakeRc(offer: _offer));
    expect(find.text('Try Pro free for 30 days'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Start free trial'),
      findsOneWidget,
    );
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('sheet has no trial hint when there is no offer, the user is '
      'subscribed or loading fails', (tester) async {
    for (final rc in [
      _FakeRc(),
      _FakeRc(
        offer: _offer,
        sub: const ActiveSubscription(productId: 'ayma_pro_monthly'),
      ),
      _FakeRc(fail: true),
    ]) {
      await _openSheet(tester, rc);
      expect(find.textContaining('Try Pro free'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Upgrade'), findsOneWidget);
      await tester.tap(find.text('Keep exploring'));
      await tester.pumpAndSettle();
    }
  });

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

    expect(find.text("You're out of credits."), findsOneWidget);

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
      tester.getSize(find.text("You're out of credits.")).width,
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
