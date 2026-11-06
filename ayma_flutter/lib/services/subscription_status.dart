import 'api_client.dart';
import 'revenuecat_service.dart';

/// The account's current plan for display: RevenueCat CustomerInfo when it is
/// configured and reports an active entitlement, else the backend `plan`
/// field, else Free. Never throws.
class SubscriptionStatus {
  const SubscriptionStatus({
    required this.planName,
    this.productId,
    this.expiresAt,
    this.willRenew = true,
    this.managementUrl,
    this.isTrial = false,
    this.fromStore = false,
  });

  /// In the store free-trial period; [expiresAt] is then the trial end.
  final bool isTrial;

  static const free = SubscriptionStatus(planName: 'Free');

  /// `Free`, `Plus`, `Pro` or `Max`.
  final String planName;

  /// Store product id of the active plan; null when unknown or Free.
  final String? productId;

  /// True when the plan was resolved from a live store entitlement
  /// (RevenueCat CustomerInfo). False when it fell back to the backend
  /// `plan` field — in that case there may be no live store subscription
  /// at all, so a plan *change* must not be sent to the store: Google Play
  /// rejects a change with no existing subscription to replace
  /// (DEVELOPER_ERROR, "arguments invalid"). A backend-fallback plan buys
  /// fresh instead.
  final bool fromStore;

  /// Renewal date, or the end of access when [willRenew] is false.
  final DateTime? expiresAt;
  final bool willRenew;
  final String? managementUrl;

  bool get isSubscribed => planName != 'Free';

  /// Plain-map form for the Plan page's last-known cache (offline-first):
  /// every field is display state, restored verbatim so a cold start can
  /// paint the page before the store/backend answers land.
  Map<String, dynamic> toMap() => {
        'plan_name': planName,
        'product_id': productId,
        'expires_at': expiresAt?.toIso8601String(),
        'will_renew': willRenew,
        'management_url': managementUrl,
        'is_trial': isTrial,
        'from_store': fromStore,
      };

  factory SubscriptionStatus.fromMap(Map<String, dynamic> m) =>
      SubscriptionStatus(
        planName: m['plan_name'] as String? ?? 'Free',
        productId: m['product_id'] as String?,
        expiresAt: DateTime.tryParse(m['expires_at'] as String? ?? ''),
        willRenew: m['will_renew'] as bool? ?? true,
        managementUrl: m['management_url'] as String?,
        isTrial: m['is_trial'] as bool? ?? false,
        fromStore: m['from_store'] as bool? ?? false,
      );

  static Future<SubscriptionStatus> load(
    RevenueCatService rc,
    ApiClient api,
  ) async {
    final sub = await rc.activeSubscription();
    if (sub != null) {
      final plan = RevenueCatService.fallbackPlans
          .where((p) => p.productId == sub.productId)
          .firstOrNull;
      if (plan != null) {
        return SubscriptionStatus(
          planName: plan.name,
          productId: plan.productId,
          expiresAt: sub.expiresAt,
          willRenew: sub.willRenew,
          managementUrl: sub.managementUrl,
          isTrial: sub.isTrial,
          fromStore: true,
        );
      }
    }
    try {
      final u = await api.usage();
      final plan = RevenueCatService.fallbackPlans
          .where((p) => p.name.toLowerCase() == u.plan.toLowerCase())
          .firstOrNull;
      if (plan == null) return free;
      return SubscriptionStatus(
        planName: plan.name,
        productId: plan.productId,
        expiresAt: u.periodEnd,
        isTrial: u.isTrial,
      );
    } catch (_) {
      return free;
    }
  }
}
