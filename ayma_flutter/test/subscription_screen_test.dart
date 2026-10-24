import 'dart:convert';

import 'package:ayma_flutter/screens/plans_screen.dart';
import 'package:ayma_flutter/screens/subscription_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeRc extends RevenueCatService {
  _FakeRc({this.sub, this.on = true});
  final ActiveSubscription? sub;
  final bool on;

  @override
  bool get enabled => on;

  @override
  Future<List<PlanOption>> plans() async => [
    for (final p in RevenueCatService.fallbackPlans)
      PlanOption(
        name: p.name,
        productId: p.productId,
        price: p.price,
        blurb: p.blurb,
        credits: p.credits,
      ),
  ];

  @override
  Future<ActiveSubscription?> activeSubscription() async => sub;
}

ApiClient _api({String plan = 'free', String? periodEnd, bool fail = false}) {
  final mock = MockClient((req) async {
    if (fail) return http.Response('boom', 500);
    return http.Response(
      jsonEncode({
        'total': 0,
        'features': {},
        'credits': {'grant': 100, 'added': 0, 'used': 0, 'remaining': 100},
        'plan': plan,
        'period_end': periodEnd,
        'tokens_per_credit': 1000,
      }),
      200,
    );
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _app(Widget home) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => home),
      GoRoute(
        path: PlansScreen.path,
        builder: (_, __) => const Scaffold(body: Text('plans-page')),
      ),
    ],
  );
  return MaterialApp.router(theme: AymaTheme.light, routerConfig: router);
}

void main() {
  testWidgets('subscriber sees plan, cancel date and opens the RevenueCat '
      'management URL', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      _app(
        SubscriptionScreen(
          service: _FakeRc(
            sub: ActiveSubscription(
              productId: 'ayma_pro_monthly',
              expiresAt: DateTime(2026, 11, 5, 12),
              willRenew: false,
              managementUrl: 'https://store.example/manage',
            ),
          ),
          api: _api(),
          openUrl: (u) async {
            opened = u;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Cancels on Nov 5, 2026'), findsOneWidget);
    expect(find.textContaining('keeps your access'), findsOneWidget);
    expect(find.textContaining('\$'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('manage-plan')));
    await tester.pumpAndSettle();
    expect(opened.toString(), 'https://store.example/manage');
  });

  testWidgets('falls back to the store page when RevenueCat has no URL', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      _app(
        SubscriptionScreen(
          service: _FakeRc(
            sub: const ActiveSubscription(productId: 'ayma_plus_monthly'),
          ),
          api: _api(),
          openUrl: (u) async {
            opened = u;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manage-plan')));
    await tester.pumpAndSettle();
    expect(opened.toString(), RevenueCatService.fallbackManagementUrl);
  });

  testWidgets('without RevenueCat the backend plan and renewal date show', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SubscriptionScreen(
          service: _FakeRc(on: false),
          api: _api(plan: 'max', periodEnd: '2026-12-01T12:00:00+00:00'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Max'), findsOneWidget);
    expect(find.textContaining('Renews on Dec'), findsOneWidget);
    expect(find.byKey(const ValueKey('change-plan')), findsOneWidget);
  });

  testWidgets('backend failure and no RevenueCat shows Free without '
      'throwing', (tester) async {
    await tester.pumpWidget(
      _app(
        SubscriptionScreen(service: _FakeRc(on: false), api: _api(fail: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Free'), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-plan')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('see-plans')));
    await tester.pumpAndSettle();
    expect(find.text('plans-page'), findsOneWidget);
  });

  testWidgets('Change plan opens the plans screen', (tester) async {
    await tester.pumpWidget(
      _app(
        SubscriptionScreen(
          service: _FakeRc(
            sub: const ActiveSubscription(productId: 'ayma_plus_monthly'),
          ),
          api: _api(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('change-plan')));
    await tester.pumpAndSettle();
    expect(find.text('plans-page'), findsOneWidget);
  });

  testWidgets('plans screen marks the current plan and offers the others', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: PlansScreen(
          service: _FakeRc(
            sub: const ActiveSubscription(productId: 'ayma_pro_monthly'),
          ),
          api: _api(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current plan'), findsOneWidget);
    final current = tester.widget<FilledButton>(
      find.byKey(const ValueKey('buy-ayma_pro_monthly')),
    );
    expect(current.onPressed, isNull);
    expect(find.text('Switch to Plus'), findsOneWidget);
    expect(find.text('Switch to Max'), findsOneWidget);
  });
}
