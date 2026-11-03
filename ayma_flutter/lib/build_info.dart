import 'package:flutter/foundation.dart';

import 'env.dart';

/// A human-readable build stamp shown at the bottom of Settings so it's obvious
/// whether a device is running the latest build.
///
/// Set at build time with `--dart-define=APP_BUILD="1.0.0 · abc1234 · date"`.
/// Falls back to "dev build" for a plain `flutter run`.
const String appBuildTag =
    String.fromEnvironment('APP_BUILD', defaultValue: 'dev build');

/// The runtime/build environment name (e.g. 'staging', 'production', 'development').
///
/// Sourced from compile-time defines (`ENVIRONMENT`, `SENTRY_ENVIRONMENT`, `APP_ENV`),
/// the backend endpoint (`AYMA_API_BASE_URL`), or the Firebase project (`FB_PROJECT_ID`).
/// In test environments, [debugAppEnvironmentOverride] can be set to simulate different
/// environments without restarting the runtime.
String? get appEnvironment {
  if (debugAppEnvironmentOverride != null) return debugAppEnvironmentOverride;
  const env = String.fromEnvironment('ENVIRONMENT');
  if (env.isNotEmpty) return env;
  const sentryEnv = String.fromEnvironment('SENTRY_ENVIRONMENT');
  if (sentryEnv.isNotEmpty) return sentryEnv;
  const appEnv = String.fromEnvironment('APP_ENV');
  if (appEnv.isNotEmpty) return appEnv;
  if (Env.apiBaseUrl.contains('staging')) return 'staging';
  const fbProject = String.fromEnvironment('FB_PROJECT_ID');
  if (fbProject.contains('staging')) return 'staging';
  return null;
}

/// Test-only override for [appEnvironment]; `null` falls back to the compiled /
/// discovered environment. Reset to `null` in `tearDown`.
@visibleForTesting
String? debugAppEnvironmentOverride;

/// Whether the build environment is production.
bool get isProductionEnvironment {
  final env = appEnvironment;
  if (env == null || env.isEmpty) return true;
  return env == 'production' || env == 'prod' || env == 'phone-release';
}

/// Formats the Settings footer version string.
///
/// Non-production builds include their environment tag (e.g. ` · staging`),
/// while production builds omit the tag (`"1.30.0+2264"`).
///
/// Examples:
/// - Staging build: `"1.30.0+2264 · staging"`
/// - Production build: `"1.30.0+2264"`
/// - Missing build number: `"1.30.0 · staging"` or `"1.30.0"`
/// - Empty version: `""`
String formatVersionString({
  required String version,
  String buildNumber = '',
  String? environment,
}) {
  if (version.isEmpty) return '';
  String ver = version.trim();
  String build = buildNumber.trim();
  if (ver.contains('+')) {
    final parts = ver.split('+');
    ver = parts[0];
    if (build.isEmpty && parts.length > 1) {
      build = parts[1];
    }
  }

  final buffer = StringBuffer(ver);
  if (build.isNotEmpty) {
    buffer.write('+$build');
  }

  final env = (environment ?? appEnvironment)?.trim();
  if (env != null &&
      env.isNotEmpty &&
      env != 'production' &&
      env != 'prod' &&
      env != 'phone-release') {
    buffer.write(' · $env');
  }

  return buffer.toString();
}
