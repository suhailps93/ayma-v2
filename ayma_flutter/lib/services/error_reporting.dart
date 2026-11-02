import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Debug builds only: makes a layout error (a RenderFlex overflow — the
/// yellow-and-black stripes — or an unbounded constraint) impossible to miss
/// in `adb logcat`, so it is reported instead of shrugged off. Release builds
/// never raise these (they are debug assertions), paint no stripes and do
/// not crash; `test/layout_matrix_test.dart` is what keeps them out.
void logLayoutErrorLoudly(FlutterErrorDetails details) {
  if (!kDebugMode) return;
  final text = details.exceptionAsString();
  if (!text.contains('overflowed') &&
      !text.contains('unbounded') &&
      !text.contains('infinite size')) {
    return;
  }
  debugPrint(
    '!!!!!!!! AYMA LAYOUT ERROR !!!!!!!! ${text.split('\n').first} '
    '(${details.context ?? ''}). Reproduce it in test/layout_matrix_test.dart '
    'and fix the layout.',
  );
}

/// Debug/profile builds only: dumps the FULL [FlutterErrorDetails] — exception,
/// the widget/library that threw, its context, and the stack — to the console
/// so it is capturable in `adb logcat`.
///
/// The app overrides both [FlutterError.onError] and [ErrorWidget.builder]
/// (startup_nodes N3 + graceful_error.dart). Overriding `FlutterError.onError`
/// without calling [FlutterError.dumpErrorToConsole] SUPPRESSES Flutter's
/// default console dump — so a non-layout build-throw (J1: the self web-search
/// `/deep-dive` render) reached only Crashlytics and never appeared in
/// `adb logcat`, leaving QA with no stack. This restores the console dump on
/// debug/profile builds only; release behaviour (silent + Crashlytics) is
/// unchanged. Uses `forceReport: true` so the dump is never abbreviated by
/// `dumpErrorToConsole`'s consecutive-error de-duplication (the same throw can
/// reach this via both the onError and the ErrorWidget.builder paths).
void dumpBuildErrorToConsole(
  FlutterErrorDetails details, {
  required String source,
}) {
  if (kReleaseMode) return;
  debugPrint('======== AYMA BUILD ERROR [$source] ========');
  debugPrint('exception: ${details.exceptionAsString().split('\n').first}');
  debugPrint('library: ${details.library ?? 'unknown'}');
  final ctx = details.context?.toDescription();
  if (ctx != null && ctx.isNotEmpty) debugPrint('context: $ctx');
  debugPrint('stack:\n${details.stack}');
  FlutterError.dumpErrorToConsole(details, forceReport: true);
}

/// Debug/profile builds only: dumps an uncaught ASYNC error (the
/// `PlatformDispatcher.instance.onError` / zone-guard path) to the console so
/// it is capturable in `adb logcat`. Release behaviour is unchanged.
void dumpAsyncErrorToConsole(
  Object error,
  StackTrace stack, {
  required String source,
}) {
  if (kReleaseMode) return;
  debugPrint('======== AYMA ASYNC ERROR [$source] ========');
  debugPrint('error: $error');
  debugPrint('stack:\n$stack');
}

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
