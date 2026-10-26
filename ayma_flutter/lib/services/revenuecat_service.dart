import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../env.dart';

/// One subscription tier on the plans screen.
class PlanOption {
  const PlanOption({
    required this.name,
    required this.productId,
    required this.price,
    required this.blurb,
    required this.credits,
    this.package,
  });

  final String name;
  final String productId;

  /// Store-localised price when the offering loaded, else the static copy.
  final String price;
  final String blurb;

  /// Credits granted each month (mirrors the backend plan pool).
  final int credits;

  /// The purchasable package; null when the offering is unavailable.
  final Package? package;
}

/// The subscriber's active plan as RevenueCat reports it.
class ActiveSubscription {
  const ActiveSubscription({
    required this.productId,
    this.expiresAt,
    this.willRenew = true,
    this.managementUrl,
    this.isTrial = false,
  });

  final String productId;

  /// True while the entitlement is in the store's free-trial period.
  final bool isTrial;

  /// Next renewal, or the end of access once cancelled.
  final DateTime? expiresAt;

  /// False once the user has cancelled; access lasts until [expiresAt].
  final bool willRenew;

  /// The store's manage-subscription page, when RevenueCat knows it.
  final String? managementUrl;
}

/// The Pro free trial the store offers this user: the Pro [plan] plus the
/// trial length read from the store product (never hardcoded).
class TrialOffer {
  const TrialOffer({
    required this.plan,
    required this.unit,
    required this.value,
  });

  final PlanOption plan;
  final PeriodUnit unit;
  final int value;

  /// The day the trial ends if it starts on [start] (calendar arithmetic;
  /// a month-end start clamps to the last day of the target month).
  DateTime endsFrom(DateTime start) {
    switch (unit) {
      case PeriodUnit.day:
        return DateTime(start.year, start.month, start.day + value);
      case PeriodUnit.week:
        return DateTime(start.year, start.month, start.day + 7 * value);
      case PeriodUnit.month:
        return _addMonths(start, value);
      case PeriodUnit.year:
        return _addMonths(start, 12 * value);
      case PeriodUnit.unknown:
        return start;
    }
  }

  static DateTime _addMonths(DateTime d, int months) {
    final total = d.year * 12 + (d.month - 1) + months;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final last = DateTime(y, m + 1, 0).day;
    return DateTime(y, m, d.day > last ? last : d.day);
  }

  /// Whole days between [start] and the trial end.
  int daysFrom(DateTime start) {
    final s = DateTime(start.year, start.month, start.day);
    return endsFrom(s).difference(s).inDays;
  }

  /// "30 days", "1 week", "1 month"...
  String get label {
    final word = switch (unit) {
      PeriodUnit.day => 'day',
      PeriodUnit.week => 'week',
      PeriodUnit.month => 'month',
      PeriodUnit.year => 'year',
      PeriodUnit.unknown => 'day',
    };
    return '$value $word${value == 1 ? '' : 's'}';
  }
}

/// Outcome of a purchase or restore attempt.
enum PurchaseOutcome { success, cancelled, nothingToRestore }

class PurchaseFailure implements Exception {
  const PurchaseFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// RevenueCat wrapper. The public SDK key comes from `--dart-define`
/// (`REVENUECAT_TEST_KEY`, the Test Store, wins over the platform keys); with
/// no key for the platform the service stays disabled and the app runs without
/// purchases. The RevenueCat app user id is the Firebase uid — the id
/// `billing.handle_event` reads as the webhook's `app_user_id`.
class RevenueCatService {
  RevenueCatService();

  static final RevenueCatService instance = RevenueCatService();

  static const offeringId = 'default';

  static const fallbackPlans = <PlanOption>[
    PlanOption(
      name: 'Plus',
      productId: 'ayma_plus_monthly',
      price: '\$10 / month',
      blurb: 'More monthly credits for chat, voice and matching.',
      credits: 700,
    ),
    PlanOption(
      name: 'Pro',
      productId: 'ayma_pro_monthly',
      price: '\$20 / month',
      blurb: 'A larger monthly credit pool for everyday use.',
      credits: 1400,
    ),
    PlanOption(
      name: 'Max',
      productId: 'ayma_max_monthly',
      price: '\$100 / month',
      blurb: 'The biggest monthly credit pool, for heavy use.',
      credits: 8000,
    ),
  ];

  bool _configured = false;

  /// Picks the SDK key. The Test Store key is honoured only in debug builds:
  /// the RevenueCat SDK kills the app when a Test Store key runs in a
  /// non-debuggable build. Release and profile builds use the production
  /// platform key and fail loudly when only the test key was supplied.
  static String get _platformKey => selectKey(
        isDebug: kDebugMode,
        testKey: Env.revenueCatTestKey,
        platformKey: kIsWeb
            ? ''
            : Platform.isAndroid
                ? Env.revenueCatAndroidKey
                : Platform.isIOS
                    ? Env.revenueCatIosKey
                    : '',
      );

  @visibleForTesting
  static String selectKey({
    required bool isDebug,
    required String testKey,
    required String platformKey,
  }) {
    if (isDebug && testKey.isNotEmpty) return testKey;
    if (!isDebug && testKey.isNotEmpty && platformKey.isEmpty) {
      throw StateError(
        'REVENUECAT_TEST_KEY was supplied to a non-debug build but no '
        'production key (REVENUECAT_ANDROID_KEY / REVENUECAT_IOS_KEY) was. '
        'The Test Store key must never ship in a release or profile build; '
        'build with --debug for test purchases, or pass the production key.',
      );
    }
    return platformKey;
  }

  /// Whether purchases are available in this build.
  bool get enabled => _configured;

  /// Configures the SDK. Stays disabled without a key; throws [StateError] only
  /// for the release misconfiguration described on [_platformKey].
  Future<void> init() async {
    final key = _platformKey;
    if (key.isEmpty || _configured) return;
    try {
      await Purchases.configure(PurchasesConfiguration(key));
      _configured = true;
    } on PlatformException catch (e) {
      debugPrint('RevenueCat configure failed: ${e.message}');
    }
  }

  Future<void> logIn(String uid) async {
    if (!_configured) return;
    try {
      await Purchases.logIn(uid);
    } on PlatformException catch (e) {
      debugPrint('RevenueCat logIn failed: ${e.message}');
    }
  }

  Future<void> logOut() async {
    if (!_configured) return;
    try {
      await Purchases.logOut();
    } on PlatformException catch (e) {
      // logOut throws when the user is already anonymous; nothing to undo.
      debugPrint('RevenueCat logOut failed: ${e.message}');
    }
  }

  String? _plansUnavailableReason;

  /// Why the last [plans] call left at least one plan without a purchasable
  /// package, in words a user can act on; null when every plan loaded or the
  /// SDK is disabled (the caller reports that case itself).
  String? get plansUnavailableReason => _plansUnavailableReason;

  /// The three plans from the `default` offering, each with its store price
  /// and package. A plan the offering lacks keeps its static copy and no
  /// package; when the offering can't be loaded every plan does, and
  /// [plansUnavailableReason] says why.
  Future<List<PlanOption>> plans() async {
    _plansUnavailableReason = null;
    if (!_configured) return fallbackPlans;
    try {
      final offering = (await Purchases.getOfferings()).getOffering(offeringId);
      if (offering == null) {
        _plansUnavailableReason = _notOffered;
        return fallbackPlans;
      }
      final out = <PlanOption>[];
      for (final f in fallbackPlans) {
        final pkg = offering.availablePackages
            .where(
              (p) => p.storeProduct.identifier.split(':').first == f.productId,
            )
            .firstOrNull;
        if (pkg == null) {
          _plansUnavailableReason = _notOffered;
          out.add(f);
          continue;
        }
        out.add(
          PlanOption(
            name: f.name,
            productId: f.productId,
            price: '${pkg.storeProduct.priceString} / month',
            blurb: f.blurb,
            credits: f.credits,
            package: pkg,
          ),
        );
      }
      return out;
    } on PlatformException catch (e) {
      debugPrint('RevenueCat getOfferings failed: ${e.message}');
      _plansUnavailableReason = offeringsErrorReason(
        PurchasesErrorHelper.getErrorCode(e),
      );
      return fallbackPlans;
    }
  }

  static const _notOffered =
      "This plan isn't available from the store right now.";

  /// User-facing reason for a failed offerings fetch.
  @visibleForTesting
  static String offeringsErrorReason(PurchasesErrorCode code) {
    switch (code) {
      case PurchasesErrorCode.networkError:
      case PurchasesErrorCode.offlineConnectionError:
        return "Couldn't reach the store. Check your connection and try again.";
      case PurchasesErrorCode.invalidCredentialsError:
      case PurchasesErrorCode.configurationError:
        return "Purchases aren't set up correctly in this build of the app.";
      default:
        return "Couldn't load plans from the store. Try again.";
    }
  }

  /// The Pro free trial this user can start, or null when the SDK is
  /// disabled, the offering or its trial is missing, or the user is not
  /// eligible (already used a trial, or subscribed). Eligibility: on Android a
  /// free phase on the default option means Google offers it to this user; on
  /// iOS the product needs a free introductory price and
  /// `checkTrialOrIntroductoryPriceEligibility` must say eligible.
  Future<TrialOffer?> proTrialOffer() async {
    if (!_configured) return null;
    try {
      final pro = fallbackPlans.firstWhere((p) => p.name == 'Pro');
      final offering = (await Purchases.getOfferings()).getOffering(offeringId);
      final pkg = offering?.availablePackages
          .where(
            (p) => p.storeProduct.identifier.split(':').first == pro.productId,
          )
          .firstOrNull;
      if (pkg == null) return null;
      final product = pkg.storeProduct;
      var unit = PeriodUnit.unknown;
      var value = 0;
      final free = product.defaultOption?.freePhase?.billingPeriod;
      final intro = product.introductoryPrice;
      if (free != null) {
        unit = free.unit;
        value = free.value;
      } else if (intro != null && intro.price == 0) {
        final e = await Purchases.checkTrialOrIntroductoryPriceEligibility([
          product.identifier,
        ]);
        if (e[product.identifier]?.status !=
            IntroEligibilityStatus.introEligibilityStatusEligible) {
          return null;
        }
        unit = intro.periodUnit;
        value = intro.periodNumberOfUnits * (intro.cycles < 1 ? 1 : intro.cycles);
      }
      if (unit == PeriodUnit.unknown || value < 1) return null;
      return TrialOffer(
        plan: PlanOption(
          name: pro.name,
          productId: pro.productId,
          price: '${product.priceString} / month',
          blurb: pro.blurb,
          credits: pro.credits,
          package: pkg,
        ),
        unit: unit,
        value: value,
      );
    } on PlatformException catch (e) {
      debugPrint('RevenueCat trial lookup failed: ${e.message}');
      return null;
    }
  }

  /// Store page where a user manages or cancels a subscription, used when
  /// RevenueCat has no `managementURL` for the customer.
  static String get fallbackManagementUrl =>
      !kIsWeb && Platform.isIOS
          ? 'https://apps.apple.com/account/subscriptions'
          : 'https://play.google.com/store/account/subscriptions';

  /// The active paid subscription from RevenueCat CustomerInfo, or null when
  /// the SDK is disabled, nothing is active, or the lookup fails.
  Future<ActiveSubscription?> activeSubscription() async {
    if (!_configured) return null;
    try {
      final info = await Purchases.getCustomerInfo();
      final ent = info.entitlements.active.values.firstOrNull;
      if (ent == null) return null;
      return ActiveSubscription(
        productId: ent.productIdentifier.split(':').first,
        expiresAt: DateTime.tryParse(ent.expirationDate ?? ''),
        willRenew: ent.willRenew,
        managementUrl: info.managementURL,
        isTrial: ent.periodType == PeriodType.trial,
      );
    } on PlatformException catch (e) {
      debugPrint('RevenueCat getCustomerInfo failed: ${e.message}');
      return null;
    }
  }

  /// Buys [plan]. With [replacing] (the product id of the active plan) on
  /// Android this is a plan change: upgrades apply now with the unused time
  /// prorated, downgrades take effect at the next renewal. A user-cancelled
  /// flow is [PurchaseOutcome.cancelled]; any other failure throws
  /// [PurchaseFailure].
  Future<PurchaseOutcome> purchase(
    PlanOption plan, {
    String? replacing,
    bool isUpgrade = true,
  }) async {
    final pkg = plan.package;
    if (!_configured || pkg == null) {
      throw const PurchaseFailure('Purchases are not available right now.');
    }
    try {
      final change = replacing == null || kIsWeb || !Platform.isAndroid
          ? null
          : StoreProductChangeInfo(
              replacing,
              replacementMode: isUpgrade
                  ? StoreReplacementMode.withTimeProration
                  : StoreReplacementMode.deferred,
            );
      await Purchases.purchase(
        PurchaseParams.package(pkg, productChangeInfo: change),
      );
      return PurchaseOutcome.success;
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) ==
          PurchasesErrorCode.purchaseCancelledError) {
        return PurchaseOutcome.cancelled;
      }
      throw PurchaseFailure(
        e.message ?? 'The purchase could not be completed.',
      );
    }
  }

  /// Restores prior purchases for this store account.
  Future<PurchaseOutcome> restore() async {
    if (!_configured) {
      throw const PurchaseFailure('Purchases are not available right now.');
    }
    try {
      final info = await Purchases.restorePurchases();
      return info.entitlements.active.isEmpty
          ? PurchaseOutcome.nothingToRestore
          : PurchaseOutcome.success;
    } on PlatformException catch (e) {
      throw PurchaseFailure(e.message ?? 'Could not restore purchases.');
    }
  }
}
