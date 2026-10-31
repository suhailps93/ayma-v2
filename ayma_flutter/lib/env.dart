/// Client environment config (ARCHITECTURE.md §1.7 step 1).
///
/// Only backend / LiveKit connection config lives here. Overridable at build
/// time with `--dart-define=AYMA_API_BASE_URL=...`.
class Env {
  const Env._();

  /// RevenueCat public SDK keys (`--dart-define=REVENUECAT_ANDROID_KEY=...` /
  /// `REVENUECAT_IOS_KEY=...`). Empty disables in-app purchases; the app
  /// still runs.
  static const String revenueCatAndroidKey =
      String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  static const String revenueCatIosKey =
      String.fromEnvironment('REVENUECAT_IOS_KEY');

  /// RevenueCat Test Store public SDK key (`--dart-define=REVENUECAT_TEST_KEY=...`).
  /// When set it overrides the platform keys so purchases are simulated (no
  /// real money). Never use it in a store release build.
  static const String revenueCatTestKey =
      String.fromEnvironment('REVENUECAT_TEST_KEY');

  static const String apiBaseUrl = String.fromEnvironment(
    'AYMA_API_BASE_URL',
    defaultValue: 'https://ayma-api-235381544962.us-central1.run.app',
  );
}
