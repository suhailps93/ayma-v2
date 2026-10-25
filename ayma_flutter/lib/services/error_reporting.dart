import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sends a *handled* (non-fatal) error to Sentry and Crashlytics, with tags
/// that say where it happened. Used where a failure is caught and shown to
/// the user (e.g. a voice call that could not start), so it is still visible
/// on the dashboards instead of only in `adb logcat`.
///
/// PII: tags must hold ids and categories only (session id, provider, screen
/// route, stage), never user text, names, emails or tokens. Sentry events are
/// additionally scrubbed by `scrubSentryEvent` (sentry_config.dart). Both
/// sinks are no-ops when not set up: Sentry without a DSN / with its flag
/// off, Crashlytics before `Firebase.initializeApp` (unit tests) or with
/// collection disabled (debug builds).
class ErrorReporter {
  const ErrorReporter();

  static const ErrorReporter instance = ErrorReporter();

  Future<void> report(
    Object error,
    StackTrace? stack, {
    required String reason,
    Map<String, String> tags = const {},
  }) async {
    final all = {'handled': 'true', 'reason': reason, ...tags};
    try {
      if (Sentry.isEnabled) {
        await Sentry.captureException(
          error,
          stackTrace: stack,
          withScope: (scope) async {
            scope.level = SentryLevel.error;
            for (final e in all.entries) {
              await scope.setTag(e.key, e.value);
            }
          },
        );
      }
    } catch (e) {
      debugPrint('[error-report] sentry capture failed: $e');
    }
    try {
      final crashlytics = FirebaseCrashlytics.instance;
      for (final e in all.entries) {
        await crashlytics.setCustomKey(e.key, e.value);
      }
      await crashlytics.recordError(
        error,
        stack,
        reason: reason,
        information: [for (final e in all.entries) '${e.key}=${e.value}'],
        fatal: false,
      );
    } catch (e) {
      debugPrint('[error-report] crashlytics record failed: $e');
    }
  }
}
