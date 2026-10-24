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
  });

  /// In the store free-trial period; [expiresAt] is then the trial end.
  final bool isTrial;

  static const free = SubscriptionStatus(planName: 'Free');

  /// `Free`, `Plus`, `Pro` or `Max`.
  final String planName;

  /// Store product id of the active plan; null when unknown or Free.
  final String? productId;

  /// Renewal date, or the end of access when [willRenew] is false.
  final DateTime? expiresAt;
  final bool willRenew;
  final String? managementUrl;

  bool get isSubscribed => planName != 'Free';

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
