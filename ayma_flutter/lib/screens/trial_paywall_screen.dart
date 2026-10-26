import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/api_client.dart';
import '../services/credits_balance.dart';
import '../services/revenuecat_service.dart';
import '../services/trial_paywall_gate.dart';
import '../theme.dart';
import '../widgets/overflow_guards.dart';
import 'plan_screen.dart';


/// Days before the trial ends that the reminder step is shown at.
const _reminderLeadDays = 2;

/// Full-screen Pro free-trial paywall. The trial length and the "won't be
/// charged until" date come from [offer] (the store product), never a
/// constant. Pops `true` after a successful purchase and `false` when
/// dismissed. With [onboarding] a clear "Continue with free plan" button skips
/// it.
class TrialPaywallScreen extends StatefulWidget {
  const TrialPaywallScreen({
    super.key,
    required this.offer,
    this.service,
    this.api,
    this.onboarding = false,
    this.now,
  });

  static const path = '/profile/usage/trial';

  final TrialOffer offer;
  final RevenueCatService? service;
  final ApiClient? api;
  final bool onboarding;

  /// Clock override for tests.
  final DateTime? now;

  @override
  State<TrialPaywallScreen> createState() => _TrialPaywallScreenState();
}

class _TrialPaywallScreenState extends State<TrialPaywallScreen> {
  late final RevenueCatService _rc =
      widget.service ?? RevenueCatService.instance;
  late final ApiClient _api = widget.api ?? ApiClient();
  bool _busy = false;

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await _rc.purchase(widget.offer.plan);
      if (outcome != PurchaseOutcome.success) return;
      try {
        CreditsBalance.instance.remaining.value =
            (await _api.usage()).creditsRemaining;
      } catch (_) {/* the Credits screen refreshes on its next load */}
      if (mounted) Navigator.of(context).pop(true);
    } on PurchaseFailure catch (e) {
      _say(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _seeAllPlans() async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PlanScreen(
          service: widget.service,
          api: widget.api,
          showContinueFree: widget.onboarding,
        ),
      ),
    );
    if (done == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final offer = widget.offer;
    final today = widget.now ?? DateTime.now();
    final total = offer.daysFrom(today);
    final chargeDate = subscriptionDate(offer.endsFrom(today));
    final steps = <(IconData, String, String)>[
      (
        Icons.lock_open_rounded,
        'Today',
        'Unlock Ayma Pro: ${offer.plan.credits} credits a month for chat, '
            'voice and matching.',
      ),
      if (total > _reminderLeadDays)
        (
          Icons.notifications_none_rounded,
          'In ${total - _reminderLeadDays} days',
          "We'll send a reminder about when your trial will end.",
        ),
      (
        Icons.event_available_rounded,
        'In $total days',
        "You'll be charged the subscription amount (${offer.plan.price}). "
            'Cancel anytime before.',
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: ChromeColumn(
          header: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: const ValueKey('trial-close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ),
          ],
          body: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            children: [
              Text(
                'Unlock all of Ayma Pro for ${offer.label}, free.',
                key: const ValueKey('trial-title'),
                style: AymaType.serif(size: 30, color: ac.fg),
              ),
              const SizedBox(height: 28),
              for (var i = 0; i < steps.length; i++)
                _Step(
                  icon: steps[i].$1,
                  title: steps[i].$2,
                  body: steps[i].$3,
                  last: i == steps.length - 1,
                ),
            ],
          ),
          footer: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('trial-continue'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: _busy ? null : _continue,
                      child: const Text('Continue'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    "You won't be charged until $chargeDate. Cancel anytime "
                    'up to 24 hrs before your trial ends.',
                    key: const ValueKey('trial-fine-print'),
                    textAlign: TextAlign.center,
                    style: AymaType.sans(
                      size: 12,
                      soft: true,
                      color: ac.fgMute,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('trial-see-plans'),
                    onPressed: _busy ? null : _seeAllPlans,
                    child: const Text('See all plans'),
                  ),
                  if (widget.onboarding)
                    OutlinedButton(
                      key: const ValueKey('continue-free'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('Continue with free plan'),
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

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    required this.last,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Icon(icon, size: 26, color: ac.fg),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: ac.lineSoft,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AymaType.sans(
                      size: 16,
                      weight: FontWeight.w600,
                      color: ac.fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(body, style: AymaType.sans(size: 14, color: ac.fgMute)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Out-of-credits entry point: shows the trial paywall for an eligible,
/// unsubscribed user at most once per day per device; every other case (or
/// any failure) opens [PlanScreen].
Future<void> openTrialPaywallOrPlans(
  GoRouter router, {
  RevenueCatService? service,
  TrialPaywallGate gate = const TrialPaywallGate(),
  DateTime? now,
}) async {
  final rc = service ?? RevenueCatService.instance;
  final clock = now ?? DateTime.now();
  try {
    if (rc.enabled && await gate.dailyDue(clock)) {
      final offer = await rc.proTrialOffer();
      if (offer != null && await rc.activeSubscription() == null) {
        await gate.markDailyShown(clock);
        await router.push(TrialPaywallScreen.path, extra: offer);
        return;
      }
    }
  } catch (_) {/* fall through to the plain plans list */}
  await router.push(PlanScreen.path);
}

/// Shown once per account right before the first chat. Never blocks: with no
/// RevenueCat, no loadable offerings or any error it returns without showing
/// anything. Not re-shown after the user subscribed or chose the free plan.
Future<void> showOnboardingPaywall(
  BuildContext context, {
  String? uid,
  RevenueCatService? service,
  ApiClient? api,
  TrialPaywallGate gate = const TrialPaywallGate(),
}) async {
  final id = uid ?? FirebaseAuth.instance.currentUser?.uid;
  final rc = service ?? RevenueCatService.instance;
  if (id == null || !rc.enabled || !await gate.onboardingDue(id)) return;
  Widget? page;
  try {
    if (await rc.activeSubscription() != null) {
      await gate.markOnboardingShown(id);
      return;
    }
    final offer = await rc.proTrialOffer();
    if (offer != null) {
      page = TrialPaywallScreen(
        offer: offer,
        service: rc,
        api: api,
        onboarding: true,
      );
    } else if ((await rc.plans()).any((p) => p.package != null)) {
      page = PlanScreen(service: rc, api: api, showContinueFree: true);
    }
  } catch (_) {
    return;
  }
  if (page == null || !context.mounted) return;
  await gate.markOnboardingShown(id);
  if (!context.mounted) return;
  final shown = page;
  await Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => shown),
  );
}
