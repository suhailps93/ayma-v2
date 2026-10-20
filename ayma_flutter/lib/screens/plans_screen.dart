import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/credits_balance.dart';
import '../services/revenuecat_service.dart';
import '../theme.dart';

/// Subscription plans (Plus / Pro / Max) from the RevenueCat `default`
/// offering, with the static plan copy as fallback. After a purchase or
/// restore the credit balance is refreshed from the backend.
class PlansScreen extends StatefulWidget {
  const PlansScreen({super.key, this.service, this.api});

  static const path = '/profile/usage/plans';

  final RevenueCatService? service;
  final ApiClient? api;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  late final RevenueCatService _rc =
      widget.service ?? RevenueCatService.instance;
  late final ApiClient _api = widget.api ?? ApiClient();
  late final Future<List<PlanOption>> _plans = _rc.plans();
  bool _busy = false;

  void _say(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _refreshCredits() async {
    try {
      final u = await _api.usage();
      CreditsBalance.instance.remaining.value = u.creditsRemaining;
    } catch (e) {
      _say(
        "Done, but couldn't refresh your credits ($e). "
        'Pull down on the Credits screen to retry.',
      );
    }
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
          await _refreshCredits();
          _say(success);
        case PurchaseOutcome.nothingToRestore:
          _say(empty);
        case PurchaseOutcome.cancelled:
          break;
      }
    } on PurchaseFailure catch (e) {
      _say(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(title: const Text('Plans')),
      body: FutureBuilder<List<PlanOption>>(
        future: _plans,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final buyable = _rc.enabled;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
            children: [
              Text(
                'Choose a plan',
                style: AymaType.serif(size: 28, color: ac.fg),
              ),
              const SizedBox(height: 6),
              Text(
                'Each plan adds a monthly pool of credits.',
                style: AymaType.sans(size: 13, color: ac.fgMute),
              ),
              const SizedBox(height: 18),
              for (final p in snap.data!)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: ac.bgElev,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ac.lineSoft, width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              p.name,
                              style: AymaType.serif(size: 22, color: ac.fg),
                            ),
                          ),
                          Text(
                            p.price,
                            style: AymaType.mono(size: 13, color: ac.fgDim),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p.blurb,
                        style: AymaType.sans(size: 13, color: ac.fgMute),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          key: ValueKey('buy-${p.productId}'),
                          onPressed: _busy || !buyable || p.package == null
                              ? null
                              : () => _run(
                                  () => _rc.purchase(p),
                                  success: '${p.name} is active.',
                                  empty: '',
                                ),
                          child: Text('Subscribe to ${p.name}'),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!buyable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Subscriptions are not available in this build.',
                    style: AymaType.sans(size: 12, color: ac.fgMute),
                  ),
                ),
              TextButton(
                key: const ValueKey('restore-purchases'),
                onPressed: _busy || !buyable
                    ? null
                    : () => _run(
                        _rc.restore,
                        success: 'Purchases restored.',
                        empty: 'No purchases to restore.',
                      ),
                child: const Text('Restore purchases'),
              ),
              const SizedBox(height: 8),
              Text(
                'Subscriptions renew automatically each month until cancelled. '
                'Manage or cancel any time in your store account settings '
                '(Google Play or the App Store).',
                key: const ValueKey('renewal-note'),
                style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
              ),
            ],
          );
        },
      ),
    );
  }
}
