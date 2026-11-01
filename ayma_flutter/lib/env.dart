/// Client environment config (ARCHITECTURE.md §1.7 step 1).
///
/// Only backend / LiveKit connection config lives here. Overridable at build
/// time with `--dart-define=AYMA_API_BASE_URL=...`.
class Env {
  const Env._();

  /// Meta/Facebook App ID Instagram requires as `source_application` when
  /// handing a share to Stories (`--dart-define=FACEBOOK_APP_ID=...`). Empty
  /// disables the Instagram Story option (the sheet falls back to the system
  /// share sheet).
  static const String facebookAppId =
      String.fromEnvironment('FACEBOOK_APP_ID');

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

  /// Production Cloud Run API base URL (ARCHITECTURE.md §12.1).
  static const String prodApiBaseUrl =
      'https://ayma-api-235381544962.us-central1.run.app';

  /// Staging API base URL placeholder (ARCHITECTURE.md §12.1).
  ///
  /// Intentionally non-routable placeholder (.invalid TLD) used when
  /// building with `--dart-define=ENV=staging` until a dedicated staging
  /// Cloud Run service is provisioned.
  static const String stagingApiBaseUrl =
      'https://ayma-api-staging.invalid';

  /// Environment selector (`--dart-define=ENV=...`).
  ///
  /// Set to `staging` for staging builds (`--dart-define=ENV=staging`).
  /// When unset (or set to `production`), production is the default.
  static const String env =
      String.fromEnvironment('ENV', defaultValue: 'production');

  /// Whether the app is running in the staging environment (`ENV=staging`).
  static const bool isStaging = env == 'staging';

  /// Active API base URL.
  ///
  /// Switched to [stagingApiBaseUrl] when `--dart-define=ENV=staging`.
  /// Can also be overridden explicitly with `--dart-define=AYMA_API_BASE_URL=...`.
  /// Production remains the default and nothing about production behavior
  /// changes when [ENV] is unset.
  static const String apiBaseUrl = String.fromEnvironment(
    'AYMA_API_BASE_URL',
    defaultValue: isStaging ? stagingApiBaseUrl : prodApiBaseUrl,
  );
}
