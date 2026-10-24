import 'dart:convert';

import 'package:ayma_flutter/screens/plans_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/credits_balance.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeRc extends RevenueCatService {
  _FakeRc({
    required this.on,
    this.restoreOutcome = PurchaseOutcome.success,
    this.subscribedTo,
  });
  final bool on;
  final String? subscribedTo;
  final PurchaseOutcome restoreOutcome;
  int restores = 0;

  @override
  bool get enabled => on;

  @override
  Future<List<PlanOption>> plans() async => RevenueCatService.fallbackPlans;

  @override
  Future<ActiveSubscription?> activeSubscription() async => subscribedTo == null
      ? null
      : ActiveSubscription(productId: subscribedTo!);

  @override
  Future<PurchaseOutcome> restore() async {
    restores++;
    return restoreOutcome;
  }
}

ApiClient _api(int remaining, void Function() onUsage) {
  final mock = MockClient((req) async {
    expect(req.url.path, '/usage');
    onUsage();
    return http.Response(
      jsonEncode({
        'total': 0,
        'features': {},
        'credits': {
          'grant': 100,
          'added': 0,
          'used': 0,
          'remaining': remaining,
        },
        'tokens_per_credit': 1000,
      }),
      200,
    );
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _app(Widget home) => MaterialApp(theme: AymaTheme.light, home: home);

void main() {
  testWidgets('disabled build lists the 3 static plans, prices and the '
      'auto-renew note, with purchase actions off', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(PlansScreen(service: _FakeRc(on: false), api: _api(0, () {}))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plus'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);
    expect(find.text('\$10 / month'), findsOneWidget);
    expect(find.text('\$20 / month'), findsOneWidget);
    expect(find.text('\$100 / month'), findsOneWidget);
    expect(find.text('700 credits per month'), findsOneWidget);
    expect(find.text('1400 credits per month'), findsOneWidget);
    expect(find.text('8000 credits per month'), findsOneWidget);
    expect(find.textContaining('renew automatically'), findsOneWidget);
    expect(find.textContaining('store account settings'), findsOneWidget);
    final buy = tester.widget<FilledButton>(
      find.byKey(const ValueKey('buy-ayma_plus_monthly')),
    );
    expect(buy.onPressed, isNull);
    expect(find.text('Restore purchases'), findsOneWidget);
  });

  testWidgets('restore refreshes credits from the backend', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var usageCalls = 0;
    final rc = _FakeRc(on: true);
    await tester.pumpWidget(
      _app(PlansScreen(service: rc, api: _api(77, () => usageCalls++))),
    );
    await tester.pumpAndSettle();
    usageCalls = 0;

    await tester.tap(find.byKey(const ValueKey('restore-purchases')));
    await tester.pumpAndSettle();

    expect(rc.restores, 1);
    expect(usageCalls, 2); // plan status reload + credits refresh
    expect(CreditsBalance.instance.remaining.value, 77);
    expect(find.text('Purchases restored.'), findsOneWidget);
  });

  testWidgets('restore with nothing to restore does not hit the backend', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var usageCalls = 0;
    await tester.pumpWidget(
      _app(
        PlansScreen(
          service: _FakeRc(
            on: true,
            restoreOutcome: PurchaseOutcome.nothingToRestore,
          ),
          api: _api(5, () => usageCalls++),
        ),
      ),
    );
    await tester.pumpAndSettle();
    usageCalls = 0;

    await tester.tap(find.byKey(const ValueKey('restore-purchases')));
    await tester.pumpAndSettle();

    expect(usageCalls, 0);
    expect(find.text('No purchases to restore.'), findsOneWidget);
  });

  testWidgets('free user sees the Free plan row', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(PlansScreen(service: _FakeRc(on: true), api: _api(0, () {}))),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('free-plan-row')), findsOneWidget);
    expect(find.text("You're on the Free plan"), findsOneWidget);
    expect(find.text('Daily credits refresh every day.'), findsOneWidget);
  });

  testWidgets('subscriber sees Current plan and no Free plan row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        PlansScreen(
          service: _FakeRc(on: true, subscribedTo: 'ayma_pro_monthly'),
          api: _api(0, () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('free-plan-row')), findsNothing);
    expect(find.text('Current plan'), findsOneWidget);
  });
}
