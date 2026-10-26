import 'dart:convert';

import 'package:ayma_flutter/screens/plan_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/credits_balance.dart';
import 'package:ayma_flutter/services/revenuecat_service.dart';
import 'package:ayma_flutter/services/screen_capture.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/out_of_credits.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:purchases_flutter/purchases_flutter.dart'
    show
        Package,
        PackageType,
        PurchasesErrorCode,
        PeriodUnit,
        PresentedOfferingContext,
        StoreProduct;
import 'package:shared_preferences/shared_preferences.dart';

const _pkg = Package(
  'pkg',
  PackageType.monthly,
  StoreProduct('ayma_pro_monthly', 'd', 't', 20, r'$20', 'USD'),
  PresentedOfferingContext('default', null, null),
);

class _FakeRc extends RevenueCatService {
  _FakeRc({
    this.on = true,
    this.sub,
    this.trial = false,
    this.restoreOutcome = PurchaseOutcome.success,
    this.offeringFails = 0,
  });
  final bool on;

  /// How many [plans] calls fail to load the offering before one succeeds.
  int offeringFails;
  int planLoads = 0;
  String? _reason;

  @override
  String? get plansUnavailableReason => _reason;
  final ActiveSubscription? sub;
  final bool trial;
  final PurchaseOutcome restoreOutcome;
  int restores = 0;
  final List<String> bought = [];

  @override
  bool get enabled => on;

  @override
  Future<List<PlanOption>> plans() async {
    planLoads++;
    _reason = null;
    if (on && offeringFails > 0) {
      offeringFails--;
      _reason = RevenueCatService.offeringsErrorReason(
        PurchasesErrorCode.invalidCredentialsError,
      );
      return RevenueCatService.fallbackPlans;
    }
    return _loaded();
  }

  List<PlanOption> _loaded() => [
    for (final p in RevenueCatService.fallbackPlans)
      PlanOption(
        name: p.name,
        productId: p.productId,
        // Store-formatted price, as an offering would give it.
        price: on ? '€${p.credits ~/ 70},00 / month' : p.price,
        blurb: p.blurb,
        credits: p.credits,
        package: on ? _pkg : null,
      ),
  ];

  @override
  Future<TrialOffer?> proTrialOffer() async => trial && on
      ? TrialOffer(
          plan: _loaded().firstWhere((p) => p.name == 'Pro'),
          unit: PeriodUnit.day,
          value: 30,
        )
      : null;

  @override
  Future<ActiveSubscription?> activeSubscription() async => sub;

  @override
  Future<PurchaseOutcome> purchase(
    PlanOption plan, {
    String? replacing,
    bool isUpgrade = true,
  }) async {
    bought.add(plan.productId);
    return PurchaseOutcome.success;
  }

  @override
  Future<PurchaseOutcome> restore() async {
    restores++;
    return restoreOutcome;
  }

  int syncs = 0;

  @override
  Future<int?> syncEntitlement(ApiClient api) async {
    syncs++;
    return null;
  }
}

ApiClient _api({
  int remaining = 58,
  String plan = 'free',
  String? periodEnd,
  Map<String, int> rows = const {'Text chat with Ayma': 30, 'Match scoring': 3},
  Set<String> emptyPeriods = const {},
  List<String>? periodsAsked,
  bool fail = false,
  void Function()? onUsage,
}) {
  final mock = MockClient((req) async {
    expect(req.url.path, '/usage');
    onUsage?.call();
    if (fail) return http.Response('down', 503);
    final period = req.url.queryParameters['period'];
    if (period != null) periodsAsked?.add(period);
    final shown = period != null && emptyPeriods.contains(period)
        ? const <String, int>{}
        : rows;
    return http.Response(
      jsonEncode({
        'total': 33000,
        'features': {'chat': 30000},
        if (period != null)
          'period_usage': {
            'period': period,
            'since': period == 'all' ? null : '2026-10-25T18:20:00',
            'features': [
              for (final e in shown.entries)
                {'key': 'k', 'label': e.key, 'credits': e.value},
            ],
            'total_credits': shown.values.fold<int>(0, (a, b) => a + b),
          },
        'credits': {
          'grant': 100,
          'added': 0,
          'used': 42,
          'remaining': remaining,
        },
        'plan': plan,
        'period_end': periodEnd,
        'tokens_per_credit': 1000,
      }),
      200,
    );
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AymaTheme.light, home: page));
  await tester.pumpAndSettle();
}

String _actionLabel(WidgetTester tester) {
  final b = tester.widget<FilledButton>(
    find.byKey(const ValueKey('plan-primary-action')),
  );
  return (b.child! as Text).data!;
}

bool _actionEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(find.byKey(const ValueKey('plan-primary-action')))
        .onPressed !=
    null;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CreditsBalance.instance.remaining.value = null;
  });

  testWidgets('free user: hero shows plan and credits only, Pro is '
      'recommended and selected, credit history in credits', (tester) async {
    await _pump(tester, PlanScreen(service: _FakeRc(on: false), api: _api()));

    expect(find.text('FREE PLAN'), findsOneWidget);
    expect(find.text('58'), findsOneWidget);
    expect(find.text('credits left'), findsOneWidget);
    expect(find.text('Daily credits refresh every day.'), findsOneWidget);
    expect(CreditsBalance.instance.remaining.value, 58);

    expect(find.text('RECOMMENDED'), findsOneWidget);
    expect(find.text('CURRENT'), findsNothing);
    expect(
      find.byKey(const ValueKey('plan-detail-ayma_pro_monthly')),
      findsOneWidget,
    );
    expect(find.text('1400'), findsOneWidget);
    expect(find.text('\$20 / month'), findsOneWidget);
    expect(_actionLabel(tester), 'Upgrade to Pro');
    expect(_actionEnabled(tester), isFalse);
    expect(
      find.text('Subscriptions are not available in this build.'),
      findsOneWidget,
    );

    expect(find.text('Text chat with Ayma'), findsOneWidget);
    expect(find.text('30 cr · 91%'), findsOneWidget);
    expect(find.text('3 cr · 9%'), findsOneWidget);
    expect(find.text('33 spent'), findsOneWidget);
    expect(find.text('since Oct 25, 6:20 PM'), findsOneWidget);
    expect(find.textContaining('tok'), findsNothing);
    expect(find.byKey(const ValueKey('renewal-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-reassurance')), findsNothing);
  });

  testWidgets('selector switches the one detail card and the action', (
    tester,
  ) async {
    await _pump(tester, PlanScreen(service: _FakeRc(), api: _api()));
    expect(_actionLabel(tester), 'Upgrade to Pro');
    expect(find.text('€20,00 / month'), findsOneWidget); // offering price

    await tester.tap(
      find.byKey(const ValueKey('plan-segment-ayma_max_monthly')),
    );
    await tester.pumpAndSettle();
    expect(find.text('8000'), findsOneWidget);
    expect(find.text('1400'), findsNothing);
    expect(_actionLabel(tester), 'Upgrade to Max');
    expect(_actionEnabled(tester), isTrue);
  });

  testWidgets('trial-eligible free user gets Start free trial on Pro', (
    tester,
  ) async {
    await _pump(tester, PlanScreen(service: _FakeRc(trial: true), api: _api()));
    expect(_actionLabel(tester), 'Start free trial');
    expect(find.text('Includes a 30 days free trial'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('plan-primary-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('trial-title')), findsOneWidget);
  });

  testWidgets('subscriber: current plan marked, Manage subscription opens '
      'the store page, others switch or upgrade', (tester) async {
    Uri? opened;
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(
          sub: ActiveSubscription(
            productId: 'ayma_pro_monthly',
            expiresAt: DateTime(2026, 11, 5, 12),
            willRenew: false,
            managementUrl: 'https://store.example/manage',
          ),
          trial: true,
        ),
        api: _api(),
        openUrl: (u) async {
          opened = u;
          return true;
        },
      ),
    );

    expect(find.text('PRO PLAN'), findsOneWidget);
    expect(find.textContaining('Ends on Nov 5, 2026'), findsOneWidget);
    expect(find.text('CURRENT'), findsOneWidget);
    expect(find.text('RECOMMENDED'), findsNothing);
    expect(_actionLabel(tester), 'Manage subscription');
    await tester.tap(find.byKey(const ValueKey('plan-primary-action')));
    await tester.pumpAndSettle();
    expect(opened.toString(), 'https://store.example/manage');

    await tester.tap(
      find.byKey(const ValueKey('plan-segment-ayma_plus_monthly')),
    );
    await tester.pumpAndSettle();
    expect(_actionLabel(tester), 'Switch to Plus');
    await tester.tap(
      find.byKey(const ValueKey('plan-segment-ayma_max_monthly')),
    );
    await tester.pumpAndSettle();
    expect(_actionLabel(tester), 'Upgrade to Max');
  });

  testWidgets('trial subscriber sees when the trial ends', (tester) async {
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(
          sub: ActiveSubscription(
            productId: 'ayma_pro_monthly',
            expiresAt: DateTime(2026, 11, 22, 12),
            isTrial: true,
          ),
        ),
        api: _api(),
      ),
    );
    expect(find.text('PRO PLAN · TRIAL'), findsOneWidget);
    expect(find.text('Free trial ends Nov 22, 2026'), findsOneWidget);
  });

  testWidgets('without RevenueCat the backend plan and renewal date show', (
    tester,
  ) async {
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(on: false),
        api: _api(plan: 'max', periodEnd: '2026-12-01T12:00:00+00:00'),
      ),
    );
    expect(find.text('MAX PLAN'), findsOneWidget);
    expect(find.textContaining('Renews on Dec'), findsOneWidget);
  });

  testWidgets('offline: credits show a dash and a retry, the page still '
      'works', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(on: false),
        api: _api(fail: true, onUsage: () => calls++),
      ),
    );
    expect(find.text('FREE PLAN'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-credits-error')), findsOneWidget);
    expect(find.text('Unavailable right now.'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-primary-action')), findsOneWidget);

    final before = calls;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, greaterThan(before));
  });

  testWidgets('out of credits shows the out-of-credits reassurance', (
    tester,
  ) async {
    await _pump(
      tester,
      PlanScreen(service: _FakeRc(on: false), api: _api(remaining: 0)),
    );
    expect(find.byKey(const ValueKey('plan-reassurance')), findsOneWidget);
    expect(find.text("You're out of credits"), findsOneWidget);
    expect(find.text(kOutOfCreditsStillFree), findsOneWidget);
    expect(find.text(kOutOfCreditsNeedsCredits), findsOneWidget);
  });

  testWidgets('low credits on Free shows it; a subscriber with few left '
      'does not', (tester) async {
    await _pump(
      tester,
      PlanScreen(service: _FakeRc(on: false), api: _api(remaining: 5)),
    );
    expect(find.text('Running low on credits'), findsOneWidget);

    await _pump(
      tester,
      PlanScreen(
        key: UniqueKey(),
        service: _FakeRc(
          sub: const ActiveSubscription(productId: 'ayma_plus_monthly'),
        ),
        api: _api(remaining: 5),
      ),
    );
    expect(find.byKey(const ValueKey('plan-reassurance')), findsNothing);
  });

  testWidgets('restore refreshes plan and credits', (tester) async {
    final rc = _FakeRc();
    var calls = 0;
    await _pump(
      tester,
      PlanScreen(
        service: rc,
        api: _api(remaining: 77, onUsage: () => calls++),
      ),
    );
    calls = 0;
    CreditsBalance.instance.remaining.value = null;
    await tester.ensureVisible(find.byKey(const ValueKey('restore-purchases')));
    await tester.tap(find.byKey(const ValueKey('restore-purchases')));
    await tester.pumpAndSettle();
    expect(rc.restores, 1);
    expect(calls, greaterThan(0));
    expect(CreditsBalance.instance.remaining.value, 77);
    expect(find.text('Purchases restored.'), findsOneWidget);
  });

  testWidgets('nothing to restore says so', (tester) async {
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(restoreOutcome: PurchaseOutcome.nothingToRestore),
        api: _api(),
      ),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('restore-purchases')));
    await tester.tap(find.byKey(const ValueKey('restore-purchases')));
    await tester.pumpAndSettle();
    expect(find.text('No purchases to restore.'), findsOneWidget);
  });

  testWidgets('Manage in store falls back to the store page', (tester) async {
    Uri? opened;
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(on: false),
        api: _api(),
        openUrl: (u) async {
          opened = u;
          return true;
        },
      ),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('manage-in-store')));
    await tester.tap(find.byKey(const ValueKey('manage-in-store')));
    await tester.pumpAndSettle();
    expect(opened.toString(), RevenueCatService.fallbackManagementUrl);
  });

  testWidgets('a purchase goes through RevenueCat for the selected plan', (
    tester,
  ) async {
    final rc = _FakeRc();
    await _pump(tester, PlanScreen(service: rc, api: _api()));
    await tester.tap(find.byKey(const ValueKey('plan-primary-action')));
    await tester.pumpAndSettle();
    expect(rc.bought, ['ayma_pro_monthly']);
    expect(find.text('Pro is active.'), findsOneWidget);
  });

  testWidgets('a successful purchase syncs the backend credits', (
    tester,
  ) async {
    final rc = _FakeRc();
    await _pump(tester, PlanScreen(service: rc, api: _api()));
    await tester.tap(find.byKey(const ValueKey('plan-primary-action')));
    await tester.pumpAndSettle();
    // The Test Store sends no server webhook, so the app must tell the backend
    // to grant the plan pool on a successful purchase.
    expect(rc.bought, ['ayma_pro_monthly']);
    expect(rc.syncs, 1);
  });

  testWidgets('a successful restore syncs the backend credits', (
    tester,
  ) async {
    final rc = _FakeRc();
    await _pump(tester, PlanScreen(service: rc, api: _api(remaining: 77)));
    await tester.ensureVisible(find.byKey(const ValueKey('restore-purchases')));
    await tester.tap(find.byKey(const ValueKey('restore-purchases')));
    await tester.pumpAndSettle();
    expect(rc.restores, 1);
    expect(rc.syncs, 1);
  });

  testWidgets('CTA is enabled with no reason when the plan has a package', (
    tester,
  ) async {
    await _pump(tester, PlanScreen(service: _FakeRc(), api: _api()));
    expect(_actionLabel(tester), 'Upgrade to Pro');
    expect(_actionEnabled(tester), isTrue);
    expect(find.byKey(const ValueKey('plan-action-unavailable')), findsNothing);
    expect(find.byKey(const ValueKey('plan-action-retry')), findsNothing);
  });

  testWidgets('CTA disabled in a build without purchases says why, no retry', (
    tester,
  ) async {
    await _pump(tester, PlanScreen(service: _FakeRc(on: false), api: _api()));
    expect(_actionEnabled(tester), isFalse);
    final reason = tester.widget<Text>(
      find.byKey(const ValueKey('plan-action-unavailable')),
    );
    expect(reason.data, 'Subscriptions are not available in this build.');
    expect(find.byKey(const ValueKey('plan-action-retry')), findsNothing);
  });

  testWidgets('offering failure: CTA disabled with the store reason, and '
      'Retry reloads and enables it', (tester) async {
    final rc = _FakeRc(offeringFails: 1);
    await _pump(tester, PlanScreen(service: rc, api: _api()));
    expect(_actionLabel(tester), 'Upgrade to Pro');
    expect(_actionEnabled(tester), isFalse);
    expect(
      find.text("Purchases aren't set up correctly in this build of the app."),
      findsOneWidget,
    );

    final loads = rc.planLoads;
    await tester.tap(find.byKey(const ValueKey('plan-action-retry')));
    await tester.pumpAndSettle();
    expect(rc.planLoads, loads + 1);
    expect(_actionEnabled(tester), isTrue);
    expect(find.text('€20,00 / month'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-action-unavailable')), findsNothing);
  });

  testWidgets('onboarding offers Continue with free plan', (tester) async {
    bool? result;
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AymaTheme.light,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => PlanScreen(
                    service: _FakeRc(),
                    api: _api(),
                    showContinueFree: true,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('continue-free')));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('Ayma can switch the plan selector by voice/text but never '
      'subscribe or upgrade', (tester) async {
    final handle = tester.ensureSemantics();
    final rc = _FakeRc();
    await _pump(tester, PlanScreen(service: rc, api: _api()));
    final cap = ScreenCapture(
      routeOf: () => '/profile/plan',
      popupOpen: () => false,
      settle: () => tester.pumpAndSettle(),
    );
    var s = cap.capture();
    final max = s.controls.firstWhere(
      (c) => c.label.contains('Max') && !c.label.contains('Upgrade'),
    );
    final picked = await cap.perform(
      control: max.id,
      label: max.label,
      op: 'tap',
    );
    expect(picked.ok, isTrue, reason: picked.reason);
    expect(_actionLabel(tester), 'Upgrade to Max');

    s = cap.capture();
    final upgrade = s.controls.firstWhere((c) => c.label == 'Upgrade to Max');
    expect(upgrade.line, contains('(user only)'));
    final refused = await cap.perform(
      control: upgrade.id,
      label: upgrade.label,
      op: 'tap',
    );
    expect(refused.ok, isFalse);
    expect(refused.reason, contains('Plan page'));
    expect(rc.bought, isEmpty);
    handle.dispose();
  });

  testWidgets('credit history: filter chips re-query the server and the '
      'header, rows and since line follow the selected period', (tester) async {
    final asked = <String>[];
    await _pump(
      tester,
      PlanScreen(
        service: _FakeRc(on: false),
        api: _api(emptyPeriods: {'7d'}, periodsAsked: asked),
      ),
    );
    expect(asked, ['since_credit']);
    expect(find.text('Since last credit update'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('credit-period-7d')));
    await tester.pumpAndSettle();
    expect(asked.last, '7d');
    expect(find.text('No credits used in this period'), findsOneWidget);
    expect(find.text('0 spent'), findsOneWidget);
    expect(find.text('Text chat with Ayma'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('credit-period-all')));
    await tester.pumpAndSettle();
    expect(asked.last, 'all');
    expect(find.text('33 spent'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-credits-since')), findsNothing);
    expect(find.textContaining('_'), findsNothing); // no raw feature keys
  });

  for (final dark in [false, true]) {
    testWidgets('credit history does not overflow on a small phone with '
        'large text (${dark ? 'dark' : 'light'})', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final errors = <String>[];
      final prior = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.toString());
      addTearDown(() => FlutterError.onError = prior);
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? AymaTheme.dark : AymaTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: PlanScreen(
            service: _FakeRc(on: false),
            api: _api(
              rows: {'Profile completeness and a very long label here': 19000},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('plan-credits-used')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // The page's other sections are laid out by their own tests; the
      // credit history must never be among the overflowing widgets.
      expect(errors.where((e) => e.contains('_CreditHistory')), isEmpty);
    });
  }
}
