import 'dart:convert';

import 'package:ayma_flutter/screens/plan_screen.dart';
import 'package:ayma_flutter/screens/trial_paywall_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:purchases_flutter/purchases_flutter.dart'
    show
        Package,
        PackageType,
        PeriodUnit,
        PresentedOfferingContext,
        StoreProduct;
import 'package:shared_preferences/shared_preferences.dart';

const _pro = PlanOption(
  name: 'Pro',
  productId: 'ayma_pro_monthly',
  price: r'$20 / month',
  blurb: 'b',
  credits: 1400,
);
const _offer = TrialOffer(plan: _pro, unit: PeriodUnit.day, value: 30);

class _FakeRc extends RevenueCatService {
  _FakeRc({
    this.on = true,
    this.offer = _offer,
    this.sub,
    this.hasPackages = true,
  });
  final bool on;
  final TrialOffer? offer;
  final ActiveSubscription? sub;
  final bool hasPackages;
  int purchases = 0;

  @override
  bool get enabled => on;

  @override
  Future<TrialOffer?> proTrialOffer() async => on ? offer : null;

  @override
  Future<ActiveSubscription?> activeSubscription() async => sub;

  @override
  Future<List<PlanOption>> plans() async => hasPackages
      ? [
          for (final p in RevenueCatService.fallbackPlans)
            PlanOption(
              name: p.name,
              productId: p.productId,
              price: p.price,
              blurb: p.blurb,
              credits: p.credits,
              package: _FakePackage.instance,
            ),
        ]
      : RevenueCatService.fallbackPlans;

  @override
  Future<PurchaseOutcome> purchase(
    PlanOption plan, {
    String? replacing,
    bool isUpgrade = true,
  }) async {
    purchases++;
    return PurchaseOutcome.success;
  }
}

class _FakePackage {
  static const instance = Package(
    'pkg',
    PackageType.monthly,
    StoreProduct('ayma_pro_monthly', 'd', 't', 20, r'$20', 'USD'),
    PresentedOfferingContext('default', null, null),
  );
}

ApiClient _api({Map<String, dynamic> extra = const {}}) {
  final mock = MockClient(
    (req) async => http.Response(
      jsonEncode({
        'total': 0,
        'features': {},
        'credits': {'grant': 100, 'added': 0, 'used': 0, 'remaining': 1400},
        'tokens_per_credit': 1000,
        ...extra,
      }),
      200,
    ),
  );
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Widget _app(Widget home) => MaterialApp(theme: AymaTheme.light, home: home);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TrialOffer', () {
    test('end date and label come from the store period', () {
      final start = DateTime(2026, 1, 31);
      const month = TrialOffer(plan: _pro, unit: PeriodUnit.month, value: 1);
      expect(month.endsFrom(start), DateTime(2026, 2, 28));
      expect(month.label, '1 month');
      const week = TrialOffer(plan: _pro, unit: PeriodUnit.week, value: 2);
      expect(week.daysFrom(start), 14);
      expect(_offer.endsFrom(DateTime(2026, 10, 23)), DateTime(2026, 11, 22));
      expect(_offer.label, '30 days');
    });
  });

  group('TrialPaywallScreen', () {
    testWidgets('renders title, timeline and the computed charge date', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          TrialPaywallScreen(
            offer: _offer,
            service: _FakeRc(),
            api: _api(),
            now: DateTime(2026, 10, 23),
          ),
        ),
      );
      expect(
        find.text('Unlock all of Ayma Pro for 30 days, free.'),
        findsOneWidget,
      );
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('In 28 days'), findsOneWidget);
      expect(find.text('In 30 days'), findsOneWidget);
      expect(
        find.text(
          "You won't be charged until Nov 22, 2026. Cancel anytime up to 24 "
          'hrs before your trial ends.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('continue-free')), findsNothing);
    });

    testWidgets('Continue buys the trial product and pops true', (
      tester,
    ) async {
      final rc = _FakeRc();
      bool? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => result = await Navigator.of(ctx).push(
                MaterialPageRoute<bool>(
                  builder: (_) =>
                      TrialPaywallScreen(offer: _offer, service: rc, api: _api()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('trial-continue')));
      await tester.pumpAndSettle();
      expect(rc.purchases, 1);
      expect(result, isTrue);
    });

    testWidgets('close dismisses without buying', (tester) async {
      final rc = _FakeRc();
      bool? result;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () async => result = await Navigator.of(ctx).push(
                MaterialPageRoute<bool>(
                  builder: (_) =>
                      TrialPaywallScreen(offer: _offer, service: rc, api: _api()),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('trial-close')));
      await tester.pumpAndSettle();
      expect(rc.purchases, 0);
      expect(result, isFalse);
    });
  });

  group('out-of-credits flow', () {
    Future<GoRouter> pumpRouter(WidgetTester tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Scaffold()),
          GoRoute(
            path: TrialPaywallScreen.path,
            builder: (_, s) => Scaffold(body: Text('TRIAL ${s.extra != null}')),
          ),
          GoRoute(
            path: PlanScreen.path,
            builder: (_, _) => const Scaffold(body: Text('PLANS')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      return router;
    }

    testWidgets('trial paywall once per day, plans the other times', (
      tester,
    ) async {
      final router = await pumpRouter(tester);
      final rc = _FakeRc();
      final day1 = DateTime(2026, 10, 23, 9);

      openTrialPaywallOrPlans(router, service: rc, now: day1);
      await tester.pumpAndSettle();
      expect(find.text('TRIAL true'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      openTrialPaywallOrPlans(
        router,
        service: rc,
        now: day1.add(const Duration(hours: 5)),
      );
      await tester.pumpAndSettle();
      expect(find.text('PLANS'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      openTrialPaywallOrPlans(
        router,
        service: rc,
        now: day1.add(const Duration(days: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('TRIAL true'), findsOneWidget);
    });

    testWidgets('ineligible, subscribed or disabled users get plans', (
      tester,
    ) async {
      for (final rc in [
        _FakeRc(offer: null),
        _FakeRc(sub: const ActiveSubscription(productId: 'ayma_plus_monthly')),
        _FakeRc(on: false),
      ]) {
        SharedPreferences.setMockInitialValues({});
        final router = await pumpRouter(tester);
        openTrialPaywallOrPlans(router, service: rc, now: DateTime(2026, 10, 23));
        await tester.pumpAndSettle();
        expect(find.text('PLANS'), findsOneWidget);
        expect(find.textContaining('TRIAL'), findsNothing);
      }
    });
  });

  group('onboarding paywall', () {
    Future<void> pumpHost(
      WidgetTester tester,
      _FakeRc rc, {
      void Function()? onDone,
    }) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                await showOnboardingPaywall(
                  ctx,
                  uid: 'u1',
                  service: rc,
                  api: _api(),
                );
                onDone?.call();
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
    }

    testWidgets('shows once, Continue with free plan skips, never re-shows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var done = 0;
      await pumpHost(tester, _FakeRc(), onDone: () => done++);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trial-title')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('continue-free')));
      await tester.pumpAndSettle();
      expect(done, 1);

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trial-title')), findsNothing);
      expect(done, 2);
    });

    testWidgets('ineligible user sees plans with Continue with free plan', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHost(tester, _FakeRc(offer: null));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('continue-free')));
      await tester.pumpAndSettle();
      expect(find.byType(PlanScreen), findsNothing);
    });

    testWidgets('never blocks: disabled SDK or failed offerings skip it', (
      tester,
    ) async {
      var done = 0;
      await pumpHost(tester, _FakeRc(on: false), onDone: () => done++);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(done, 1);
      expect(find.byKey(const ValueKey('trial-title')), findsNothing);

      await pumpHost(
        tester,
        _FakeRc(offer: null, hasPackages: false),
        onDone: () => done++,
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(done, 2);
      expect(find.text('Choose a plan'), findsNothing);
    });

    testWidgets('subscribed users are never shown it', (tester) async {
      await pumpHost(
        tester,
        _FakeRc(sub: const ActiveSubscription(productId: 'ayma_pro_monthly')),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('trial-title')), findsNothing);
    });
  });

  // --- Jobs pass cluster 22: spacing / alignment regressions ---
  group('TrialPaywallScreen jobs pass (cluster 22)', () {
    Future<void> pump(WidgetTester tester, ThemeData theme) async {
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: TrialPaywallScreen(
            offer: _offer,
            service: _FakeRc(),
            api: _api(),
            now: DateTime(2026, 10, 23),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Themes are resolved INSIDE each test body: building AymaTheme.* eagerly
    // touches google_fonts, which must happen under the test binding.
    for (final dark in [false, true]) {
      final tLabel = dark ? 'dark' : 'light';

      testWidgets('title, steps and footer content sit at the 20 edge '
          '($tLabel)', (tester) async {
        await pump(tester, dark ? AymaTheme.dark : AymaTheme.light);
        // V8 — the 24 edge became 20: title, first step icon, Continue.
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('trial-title'))).dx,
          closeTo(20, 0.5),
        );
        expect(
          tester.getTopLeft(find.byIcon(Icons.lock_open_rounded)).dx,
          closeTo(20, 0.5),
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('trial-continue'))).dx,
          closeTo(20, 0.5),
        );
      });

      testWidgets('Continue-to-fine-print gap is 12 and the step title-to-body '
          'gap is 4 ($tLabel)', (tester) async {
        await pump(tester, dark ? AymaTheme.dark : AymaTheme.light);
        // V9 — Continue bottom to fine-print top = 12 (was 10).
        final contBottom = tester
            .getRect(find.byKey(const ValueKey('trial-continue')))
            .bottom;
        final fineTop = tester
            .getRect(find.byKey(const ValueKey('trial-fine-print')))
            .top;
        expect(fineTop - contBottom, closeTo(12, 0.5));
        // V10 — 'Today' step title bottom to its body top = 4 (was 2).
        final titleBottom = tester.getRect(find.text('Today')).bottom;
        final bodyTop = tester
            .getRect(find.textContaining('Unlock Ayma Pro:'))
            .top;
        expect(bodyTop - titleBottom, closeTo(4, 0.5));
      });
    }
  });
}
