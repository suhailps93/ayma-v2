import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/revenuecat_service.dart';
import '../services/subscription_status.dart';
import '../theme.dart';
import '../widgets/ayma_back_button.dart';
import 'plans_screen.dart';

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

/// Subscriber's own view of their plan: name, renewal or end date, and the
/// buttons to change it (Plans screen) or manage/cancel it (the store's page —
/// cancelling cannot be done in-app against Google or Apple).
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key, this.service, this.api, this.openUrl});

  static const path = '/profile/subscription';

  final RevenueCatService? service;
  final ApiClient? api;
  final UrlOpener? openUrl;

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  late final RevenueCatService _rc =
      widget.service ?? RevenueCatService.instance;
  late final ApiClient _api = widget.api ?? ApiClient();
  late Future<SubscriptionStatus> _status = SubscriptionStatus.load(_rc, _api);

  Future<void> _manage(SubscriptionStatus s) async {
    final url = s.managementUrl ?? RevenueCatService.fallbackManagementUrl;
    var opened = false;
    try {
      opened = await (widget.openUrl ?? _openExternally)(Uri.parse(url));
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't open your store's subscription page."),
      ),
    );
  }

  Future<void> _change() async {
    await context.push(PlansScreen.path);
    if (!mounted) return;
    setState(() {
      _status = SubscriptionStatus.load(_rc, _api);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Subscription'),
      ),
      body: FutureBuilder<SubscriptionStatus>(
        future: _status,
        builder: (context, snap) {
          final s = snap.data;
          if (s == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final end = s.expiresAt;
          final detail = end == null
              ? null
              : s.willRenew
              ? 'Renews on ${subscriptionDate(end)}'
              : 'Cancels on ${subscriptionDate(end)}';
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
            children: [
              Text(
                s.planName,
                key: const ValueKey('subscription-plan'),
                style: AymaType.serif(size: 28, color: ac.fg),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail,
                  key: const ValueKey('subscription-detail'),
                  style: AymaType.sans(size: 13, color: ac.fgMute),
                ),
              ],
              const SizedBox(height: 20),
              if (s.isSubscribed) ...[
                FilledButton(
                  key: const ValueKey('change-plan'),
                  onPressed: _change,
                  child: const Text('Change plan'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('manage-plan'),
                  onPressed: () => _manage(s),
                  child: const Text('Manage or cancel plan'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Cancelling keeps your access until the end of the '
                  'current period.',
                  key: const ValueKey('cancel-note'),
                  style: AymaType.sans(size: 12, soft: true, color: ac.fgMute),
                ),
              ] else
                FilledButton(
                  key: const ValueKey('see-plans'),
                  onPressed: _change,
                  child: const Text('See plans'),
                ),
            ],
          );
        },
      ),
    );
  }
}
