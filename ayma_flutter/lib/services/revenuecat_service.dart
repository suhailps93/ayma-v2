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

  static String get _platformKey {
    if (Env.revenueCatTestKey.isNotEmpty) return Env.revenueCatTestKey;
    if (kIsWeb) return '';
    if (Platform.isAndroid) return Env.revenueCatAndroidKey;
    if (Platform.isIOS) return Env.revenueCatIosKey;
    return '';
  }

  /// Whether purchases are available in this build.
  bool get enabled => _configured;

  /// Configures the SDK. Stays disabled without a key; never throws.
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

  /// The three plans from the `default` offering. Falls back to the static
  /// list when the offering can't be loaded or lacks one of the products.
  Future<List<PlanOption>> plans() async {
    if (!_configured) return fallbackPlans;
    try {
      final offering = (await Purchases.getOfferings()).getOffering(offeringId);
      if (offering == null) return fallbackPlans;
      final out = <PlanOption>[];
      for (final f in fallbackPlans) {
        final pkg = offering.availablePackages
            .where(
              (p) => p.storeProduct.identifier.split(':').first == f.productId,
            )
            .firstOrNull;
        if (pkg == null) return fallbackPlans;
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
      return fallbackPlans;
    }
  }

  /// Buys [plan]. A user-cancelled flow is [PurchaseOutcome.cancelled]; any
  /// other failure throws [PurchaseFailure].
  Future<PurchaseOutcome> purchase(PlanOption plan) async {
    final pkg = plan.package;
    if (!_configured || pkg == null) {
      throw const PurchaseFailure('Purchases are not available right now.');
    }
    try {
      await Purchases.purchase(PurchaseParams.package(pkg));
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
