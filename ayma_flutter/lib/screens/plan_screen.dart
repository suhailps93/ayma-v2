import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/credits_balance.dart';
import '../services/dev_panel_session.dart';
import '../services/fresh_data.dart';
import '../services/revenuecat_service.dart';
import '../services/subscription_status.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import '../widgets/ayma_primitives.dart';
import '../widgets/ayma_toast.dart';
import '../widgets/freshness_indicator.dart';
import '../widgets/out_of_credits.dart';
import '../widgets/overflow_guards.dart';
import 'trial_paywall_screen.dart';

typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _openExternally(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String subscriptionDate(DateTime t) {
  final d = t.toLocal();
  return '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Free-plan reset line: the daily allowance resets at 00:00 UTC with no
/// rollover; shown as the user's local clock time plus a countdown, e.g.
/// "Credits reset at 5:00 PM (in 6h 12m)".
String freeCreditsResetLine(DateTime now) {
  final u = now.toUtc();
  final next = DateTime.utc(u.year, u.month, u.day + 1);
  final left = next.difference(u);
  final d = next.toLocal();
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final clock = '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
  final mins = left.inMinutes;
  final eta = mins < 60 ? '${mins}m' : '${mins ~/ 60}h ${mins % 60}m';
  return 'Credits reset at $clock (in $eta)';
}

/// "Oct 25, 6:20 PM" — the local start of a credit-history period.
String periodStart(DateTime t) {
  final d = t.toLocal();
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '${_months[d.month - 1]} ${d.day}, $h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// The periods "Where your credits went" can be filtered by: the server
/// period id and its chip label. The first is the default.
const _creditPeriods = [
  ('since_credit', 'Since last credit update'),
  ('7d', 'Last 7 days'),
  ('30d', 'Last 30 days'),
  ('all', 'All time'),
];

/// A Free-plan balance at or below this shows the "what still works" note
/// before the user actually hits zero.
const _lowFreeCredits = 10;

/// The plan the comparison opens on for a user with no paid plan.
const _recommendedPlan = 'Pro';

/// What every paid plan includes besides its credit pool.
const _planFeatures = [
  'Chat and voice with Ayma',
  'Match scoring and reports',
  'Cancel anytime from your store account',
];

class _PlanData {
  const _PlanData({
    required this.status,
    required this.plans,
    required this.usage,
    required this.trial,
  });

  final SubscriptionStatus status;
  final List<PlanOption> plans;

  /// Null when `/usage` could not be loaded (offline, server error).
  final UsageSummary? usage;

  /// The Pro free trial, only when the user has no paid plan and the store
  /// says they're eligible.
  final TrialOffer? trial;
}

/// The one Plan page: current plan and credit balance, a plan comparison with
/// a single context-aware action, where credits went, and the store links.
/// Users only ever see credits here — never token or dollar figures.
class PlanScreen extends StatefulWidget {
  const PlanScreen({
    super.key,
    this.service,
    this.api,
    this.openUrl,
    this.showContinueFree = false,
  });

  static const path = '/profile/plan';

  final RevenueCatService? service;
  final ApiClient? api;
  final UrlOpener? openUrl;

  /// Onboarding: adds a "Continue with free plan" action that pops `true`.
  final bool showContinueFree;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  late final RevenueCatService _rc =
      widget.service ?? RevenueCatService.instance;
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<_PlanData> _data = _load();
  FreshData<_PlanData> _fresh = const FreshData();
  _PlanData? _lastOk;
  String? _selected; // productId of the plan shown in the detail card
  bool _busy = false;

  Future<UsageSummary?> _usage() async {
    try {
      final u = await _api.usage(period: _creditPeriods.first.$1);
      CreditsBalance.instance.remaining.value = u.creditsRemaining;
      return u;
    } catch (_) {
      return null;
    }
  }

  Future<PeriodUsage?> _periodUsage(String period) async {
    try {
      return (await _api.usage(period: period)).periodUsage;
    } catch (_) {
      return null;
    }
  }

  Future<List<PlanOption>> _plans() async {
    try {
      return await _rc.plans();
    } catch (_) {
      return RevenueCatService.fallbackPlans;
    }
  }

  Future<TrialOffer?> _trialFor(SubscriptionStatus s) async {
    if (s.isSubscribed) return null;
    try {
      return await _rc.proTrialOffer();
    } catch (_) {
      return null;
    }
  }

  Future<_PlanData> _load() async {
    final prior = _lastOk;
    if (mounted) {
      setState(() {
        _fresh = FreshData.fromApi(
          data: prior,
          refreshing: true,
          fromPrior: prior != null,
        );
      });
    }
    try {
      final status = SubscriptionStatus.load(_rc, _api);
      final plans = _plans();
      final usage = _usage();
      final s = await status;
      final loaded = _PlanData(
        status: s,
        plans: await plans,
        usage: await usage,
        trial: await _trialFor(s),
      );
      if (mounted) {
        setState(() {
          _lastOk = loaded;
          _fresh = FreshData.fromApi(data: loaded);
        });
      }
      return loaded;
    } catch (e) {
      if (mounted) {
        setState(() {
          _fresh = FreshData.fromApi(
            data: prior,
            error: e,
            fromPrior: prior != null,
          );
        });
      }
      rethrow;
    }
  }

  void _reload() {
    setState(() {
      _data = _load();
    });
  }

  void _say(String msg, {AymaToastKind kind = AymaToastKind.info}) {
    if (!mounted) return;
    AymaToast.show(context, msg, kind: kind);
  }

  Future<void> _manage(SubscriptionStatus s) async {
    final url = s.managementUrl ?? RevenueCatService.fallbackManagementUrl;
    var opened = false;
    try {
      opened = await (widget.openUrl ?? _openExternally)(Uri.parse(url));
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      _say("Couldn't open your store's subscription page.",
          kind: AymaToastKind.error);
    }
  }

  Future<void> _startTrial(TrialOffer offer) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TrialPaywallScreen(
          offer: offer,
          service: widget.service,
          api: widget.api,
        ),
      ),
    );
    if (done != true || !mounted) return;
    if (widget.showContinueFree) {
      Navigator.of(context).pop(true);
      return;
    }
    _reload();
  }

  Future<void> _run(
    Future<PurchaseOutcome> Function() action, {
    required String success,
    required String empty,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      switch (await action()) {
        case PurchaseOutcome.success:
          // Grant/refresh the plan's monthly credits from the new entitlement
          // (the webhook-less Test Store path; idempotent) before reloading.
          await _rc.syncEntitlement(_api);
          if (mounted) _reload();
          _say(success, kind: AymaToastKind.success);
          if (widget.showContinueFree && mounted) {
            Navigator.of(context).pop(true);
          }
        case PurchaseOutcome.nothingToRestore:
          _say(empty);
        case PurchaseOutcome.cancelled:
          break;
      }
    } on PurchaseFailure catch (e) {
      _say(e.message, kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// True only for a developer testing from this screen: the account is on the
  /// server's dev-view allowlist ([UsageSummary.isDev]) AND the Developer panel
  /// is unlocked this session ([DevPanelSession]). The same gate the dev panel's
  /// Test upgrade uses. For everyone else this is false, so the real purchase
  /// path (and its disabled state when the store is off) is untouched — never a
  /// free-credits backdoor.
  bool _devUpgrade(_PlanData d) =>
      (d.usage?.isDev ?? false) && DevPanelSession.instance.unlocked.value;

  /// DEV/TEST ONLY — grant [p]'s monthly credit pool with no real payment via
  /// `POST /dev/test-upgrade` (the same path as the dev panel's Test upgrade),
  /// then refresh the balance and plan. Only reachable when [_devUpgrade] holds;
  /// the server re-checks the dev-view allowlist and returns 403 otherwise.
  Future<void> _devTestUpgrade(PlanOption p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await _api.testUpgrade(p.name.toLowerCase());
      CreditsBalance.instance.remaining.value = updated.creditsRemaining;
      if (mounted) _reload();
      _say(
        'Test upgrade: ${p.name} — ${updated.creditsRemaining} credits '
        '(no payment).',
        kind: AymaToastKind.success,
      );
    } on ApiException catch (e) {
      _say(
        e.statusCode == 403
            ? 'Test upgrade is for dev-view accounts only.'
            : "Couldn't apply the test upgrade (${e.statusCode}).",
        kind: AymaToastKind.error,
      );
    } catch (e) {
      _say("Couldn't apply the test upgrade ($e).", kind: AymaToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  PlanOption _selectedPlan(_PlanData d) {
    final id =
        _selected ??
        d.status.productId ??
        d.plans.where((p) => p.name == _recommendedPlan).firstOrNull?.productId;
    return d.plans.where((p) => p.productId == id).firstOrNull ?? d.plans.first;
  }

  /// Why [p] can't be bought right now, or null when it can. [retry] is true
  /// when reloading the store's plans might fix it.
  ({String text, bool retry})? _unavailable(PlanOption p) {
    if (!_rc.enabled) {
      return (
        text: 'Subscriptions are not available in this build.',
        retry: false,
      );
    }
    if (p.package != null) return null;
    return (
      text:
          _rc.plansUnavailableReason ??
          "Couldn't load plans from the store. Try again.",
      retry: true,
    );
  }

  /// The single bottom action for the plan currently shown, with the reason
  /// shown under it when it can't be used.
  ({
    String label,
    VoidCallback? onPressed,
    ({String text, bool retry})? unavailable,
  })
  _action(_PlanData d, PlanOption p) {
    final s = d.status;
    if (p.productId == s.productId) {
      return (
        label: 'Manage subscription',
        onPressed: () => _manage(s),
        unavailable: null,
      );
    }
    final trial = d.trial;
    if (trial != null && trial.plan.productId == p.productId) {
      return (
        label: 'Start free trial',
        onPressed: _busy ? null : () => _startTrial(trial),
        unavailable: null,
      );
    }
    final currentCredits = d.plans
        .where((x) => x.productId == s.productId)
        .firstOrNull
        ?.credits;
    final isUpgrade = currentCredits == null || p.credits > currentCredits;
    final label = isUpgrade ? 'Upgrade to ${p.name}' : 'Switch to ${p.name}';
    // Developers test the real upgrade button without a payment (even when the
    // store is off, as in release): route to the dev test-upgrade path. For
    // everyone else the normal purchase path and its disabled state stand.
    if (_devUpgrade(d)) {
      return (
        label: label,
        unavailable: null,
        onPressed: _busy ? null : () => _devTestUpgrade(p),
      );
    }
    final unavailable = _unavailable(p);
    return (
      label: label,
      unavailable: unavailable,
      onPressed: unavailable == null && !_busy
          ? () => _run(
              () =>
                  _rc.purchase(p, replacing: s.productId, isUpgrade: isUpgrade),
              success: '${p.name} is active.',
              empty: '',
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return FutureBuilder<_PlanData>(
      future: _data,
      builder: (context, snap) {
        final shown = snap.data ?? _lastOk;
        final plan = shown == null ? null : _selectedPlan(shown);
        final action =
            shown == null || plan == null ? null : _action(shown, plan);
        return Scaffold(
          appBar: AppBar(
            leading: const AymaBackButton(),
            title: const Text('Plan'),
          ),
          body: Column(
            children: [
              if (_fresh.hasData ||
                  _fresh.state == FreshnessState.stale ||
                  _fresh.state == FreshnessState.refused)
                FreshnessIndicator.fromFresh(_fresh, onRetry: _reload),
              Expanded(
                child: shown == null || plan == null
                    ? snap.hasError
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                "Couldn't load your plan.",
                                style: AymaType.sans(
                                    size: 14, color: ac.error),
                              ),
                            ),
                          )
                        : const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: () async {
                          _reload();
                          await _data;
                        },
                        child: ListView(
                          padding:
                              const EdgeInsets.fromLTRB(24, 20, 24, 32),
                          children: [
                            _Hero(data: shown, onRetry: _reload),
                            const SizedBox(height: 40),
                            const Eyebrow('Plans'),
                            const SizedBox(height: 6),
                            Text(
                              'Each plan adds a monthly pool of credits.',
                              style:
                                  AymaType.sans(size: 13, color: ac.fgMute),
                            ),
                            const SizedBox(height: 16),
                            _PlanSelector(
                              plans: shown.plans,
                              selected: plan.productId,
                              current: shown.status.productId,
                              onSelect: (id) =>
                                  setState(() => _selected = id),
                            ),
                            const SizedBox(height: 12),
                            _PlanDetail(
                              plan: plan,
                              isCurrent:
                                  plan.productId == shown.status.productId,
                              trial: shown.trial?.plan.productId ==
                                      plan.productId
                                  ? shown.trial
                                  : null,
                            ),
                            const SizedBox(height: 40),
                            _CreditHistory(
                              initial: shown.usage?.periodUsage,
                              available: shown.usage != null,
                              load: _periodUsage,
                            ),
                            const SizedBox(height: 32),
                            Divider(height: 0.5, color: ac.lineSoft),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 4,
                              children: [
                                TextButton(
                                  key: const ValueKey('restore-purchases'),
                                  onPressed: _busy || !_rc.enabled
                                      ? null
                                      : () => _run(
                                            _rc.restore,
                                            success: 'Purchases restored.',
                                            empty:
                                                'No purchases to restore.',
                                          ),
                                  child: const Text('Restore purchases'),
                                ),
                                TextButton(
                                  key: const ValueKey('manage-in-store'),
                                  onPressed: () => _manage(shown.status),
                                  child: const Text('Manage in store'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Subscriptions renew automatically each month '
                              'until cancelled. Manage or cancel any time in '
                              'your store account settings (Google Play or '
                              'the App Store).',
                              key: const ValueKey('renewal-note'),
                              style: AymaType.sans(
                                size: 12,
                                soft: true,
                                color: ac.fgMute,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
          bottomNavigationBar: action == null
              ? null
              : _ActionBar(
                  label: action.label,
                  onPressed: action.onPressed,
                  unavailable: action.unavailable?.text,
                  onRetry: action.unavailable?.retry == true ? _reload : null,
                  onContinueFree: widget.showContinueFree
                      ? () => Navigator.of(context).pop(true)
                      : null,
                ),
        );
      },
    );
  }
}

/// Current plan and credits left — the page's primary figure.
class _Hero extends StatelessWidget {
  const _Hero({required this.data, required this.onRetry});

  final _PlanData data;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = data.status;
    final u = data.usage;
    final end = s.expiresAt;
    final status = !s.isSubscribed
        ? freeCreditsResetLine(DateTime.now())
        : end == null
        ? null
        : s.isTrial
        ? 'Free trial ends ${subscriptionDate(end)}'
        : s.willRenew
        ? 'Renews on ${subscriptionDate(end)}'
        : 'Ends on ${subscriptionDate(end)} — access continues until then.';
    final remaining = u?.creditsRemaining;
    final out = remaining == 0;
    final low =
        remaining != null &&
        (out || (!s.isSubscribed && remaining <= _lowFreeCredits));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${s.planName} plan${s.isTrial ? ' · trial' : ''}'.toUpperCase(),
          key: const ValueKey('plan-name'),
          style: AymaType.mono(
            size: 11,
            color: ac.accent,
          ).copyWith(letterSpacing: 2),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              remaining == null ? '—' : '$remaining',
              key: const ValueKey('plan-credits-remaining'),
              style: AymaType.serif(
                size: 64,
                color: out ? ac.error : ac.fg,
              ).copyWith(height: 1),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'credits left',
                style: AymaType.sans(size: 15, color: ac.fgMute),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (u == null)
          Row(
            children: [
              Expanded(
                child: Text(
                  "Couldn't load your credits. Check your connection.",
                  key: const ValueKey('plan-credits-error'),
                  style: AymaType.sans(size: 13, color: ac.fgDim),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          )
        else if (status != null)
          Text(
            status,
            key: const ValueKey('plan-status'),
            style: AymaType.sans(size: 13, color: ac.fgDim),
          ),
        if (low) ...[
          const SizedBox(height: 20),
          Container(
            key: const ValueKey('plan-reassurance'),
            padding: const EdgeInsets.only(left: 14),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: ac.accentSoft, width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  out ? "You're out of credits" : 'Running low on credits',
                  style: AymaType.sans(
                    size: 14,
                    weight: FontWeight.w600,
                    color: ac.fg,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  kOutOfCreditsStillFree,
                  style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.45),
                ),
                const SizedBox(height: 6),
                Text(
                  kOutOfCreditsNeedsCredits,
                  style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Plus / Pro / Max segmented selector; marks the current plan and tags Pro
/// as recommended.
class _PlanSelector extends StatelessWidget {
  const _PlanSelector({
    required this.plans,
    required this.selected,
    required this.current,
    required this.onSelect,
  });

  final List<PlanOption> plans;
  final String selected;
  final String? current;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: ac.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ac.lineSoft, width: 0.5),
      ),
      child: Row(
        children: [
          for (final p in plans)
            Expanded(
              child: Semantics(
                button: true,
                selected: p.productId == selected,
                child: GestureDetector(
                  key: ValueKey('plan-segment-${p.productId}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(p.productId),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: p.productId == selected
                          ? ac.bg
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: p.productId == selected
                            ? ac.line
                            : Colors.transparent,
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          p.name,
                          style: AymaType.sans(
                            size: 15,
                            weight: FontWeight.w600,
                            color: p.productId == selected ? ac.fg : ac.fgDim,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          p.productId == current
                              ? 'CURRENT'
                              : p.name == _recommendedPlan
                              ? 'RECOMMENDED'
                              : ' ',
                          style: AymaType.mono(
                            size: 8.5,
                            color: p.productId == current
                                ? ac.fgDim
                                : ac.accent,
                          ).copyWith(letterSpacing: 1.2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The one detailed card for the selected plan.
class _PlanDetail extends StatelessWidget {
  const _PlanDetail({
    required this.plan,
    required this.isCurrent,
    required this.trial,
  });

  final PlanOption plan;
  final bool isCurrent;
  final TrialOffer? trial;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey('plan-detail-${plan.productId}'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isCurrent ? ac.line : ac.lineSoft,
            width: isCurrent ? 1 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    plan.name,
                    style: AymaType.serif(size: 30, color: ac.fg),
                  ),
                ),
                Text(
                  plan.price,
                  key: ValueKey('price-${plan.productId}'),
                  style: AymaType.mono(
                    size: 12,
                    color: ac.fgDim,
                  ).copyWith(letterSpacing: 0.5),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              plan.blurb,
              style: AymaType.sans(size: 13, color: ac.fgMute, height: 1.4),
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${plan.credits}',
                  key: ValueKey('credits-${plan.productId}'),
                  style: AymaType.serif(size: 40, color: ac.fg),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'credits per month',
                    style: AymaType.sans(size: 13, color: ac.fgMute),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(height: 0.5, color: ac.lineSoft),
            const SizedBox(height: 14),
            for (final f in [
              ?trial == null ? null : 'Includes a ${trial!.label} free trial',
              ..._planFeatures,
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: ac.fgDim,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        f,
                        style: AymaType.sans(size: 14, color: ac.fg),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where credits went, per feature, for a selectable period — a quiet list in
/// credits only. The header total, the rows and the shares all come from the
/// same server-side period aggregate, so they always agree.
class _CreditHistory extends StatefulWidget {
  const _CreditHistory({
    required this.initial,
    required this.available,
    required this.load,
  });

  /// The default period's usage, loaded with the page.
  final PeriodUsage? initial;

  /// False when `/usage` itself could not be loaded.
  final bool available;
  final Future<PeriodUsage?> Function(String period) load;

  @override
  State<_CreditHistory> createState() => _CreditHistoryState();
}

class _CreditHistoryState extends State<_CreditHistory> {
  String _period = _creditPeriods.first.$1;
  PeriodUsage? _usage;
  bool _loading = false;
  bool _failed = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _usage = widget.initial;
    _failed = widget.initial == null;
  }

  Future<void> _select(String period) async {
    if (period == _period) return;
    final request = ++_request;
    setState(() {
      _period = period;
      _loading = true;
    });
    final result = await widget.load(period);
    if (!mounted || request != _request) return;
    setState(() {
      _usage = result;
      _failed = result == null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final u = _usage;
    final quiet = AymaType.sans(size: 14, soft: true, color: ac.fgMute);
    final since = u?.since;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Eyebrow('Where your credits went')),
            if (u != null && !_loading)
              Text(
                '${u.totalCredits} spent',
                key: const ValueKey('plan-credits-used'),
                style: AymaType.mono(
                  size: 11,
                  color: ac.fgMute,
                ).copyWith(letterSpacing: 0.5),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (!widget.available)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('Unavailable right now.', style: quiet),
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (id, label) in _creditPeriods)
                ChoiceChip(
                  key: ValueKey('credit-period-$id'),
                  label: Text(label),
                  selected: _period == id,
                  onSelected: (_) => _select(id),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (since != null && !_loading && !_failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'since ${periodStart(since)}',
                key: const ValueKey('plan-credits-since'),
                style: AymaType.mono(
                  size: 11,
                  color: ac.fgMute,
                ).copyWith(letterSpacing: 0.5),
              ),
            ),
          const SizedBox(height: 4),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_failed || u == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('Unavailable right now.', style: quiet),
            )
          else if (u.features.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No credits used in this period',
                key: const ValueKey('plan-credits-empty'),
                style: quiet,
              ),
            )
          else
            for (var i = 0; i < u.features.length; i++) ...[
              if (i > 0) Divider(height: 0.5, color: ac.lineSoft),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        u.features[i].label,
                        style: AymaType.sans(size: 14, color: ac.fgDim),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        '${u.features[i].credits} cr · '
                        '${(u.features[i].credits * 100 / u.totalCredits).round()}%',
                        style: AymaType.mono(
                          size: 12,
                          color: ac.fgDim,
                        ).copyWith(letterSpacing: 0.5),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ],
        ],
      ],
    );
  }
}

/// The sticky bottom action, labelled for the selected plan's state.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.label,
    required this.onPressed,
    this.unavailable,
    this.onRetry,
    this.onContinueFree,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Why the action is disabled, shown under it; null when it is usable.
  final String? unavailable;

  /// Reloads the store's plans; shown next to [unavailable] when set.
  final VoidCallback? onRetry;
  final VoidCallback? onContinueFree;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: ac.lineSoft, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        // At most ~half a short window (split-screen, large text); past
        // that the bar scrolls instead of overflowing the page.
        child: CappedScroll(
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('plan-primary-action'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                    onPressed: onPressed,
                    child: Text(label),
                  ),
                ),
                if (unavailable != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            unavailable!,
                            key: const ValueKey('plan-action-unavailable'),
                            style: AymaType.sans(size: 12, color: ac.fgMute),
                          ),
                        ),
                        if (onRetry != null)
                          TextButton(
                            key: const ValueKey('plan-action-retry'),
                            onPressed: onRetry,
                            child: const Text('Retry'),
                          ),
                      ],
                    ),
                  ),
                if (onContinueFree != null)
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      key: const ValueKey('continue-free'),
                      style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                      onPressed: onContinueFree,
                      child: const Text('Continue with free plan'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
