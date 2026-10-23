import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sentry DSN, supplied at build time via `--dart-define=SENTRY_DSN=...`.
/// Empty (the default: local dev, tests) disables Sentry entirely.
const String sentryDsn = String.fromEnvironment('SENTRY_DSN');

/// Configures Sentry. The release defaults to `<package>@<version>+<build>`
/// from the app's pubspec version. No PII, screenshots or widget-label
/// breadcrumbs are collected, and request bodies are dropped (see
/// [scrubSentryEvent]) so user messages, transcripts and profile text never
/// leave the device.
void configureSentryOptions(SentryFlutterOptions options) {
  options.dsn = sentryDsn;
  options.environment = kReleaseMode ? 'production' : 'development';
  options.sendDefaultPii = false;
  options.attachScreenshot = false;
  options.attachViewHierarchy = false;
  options.enableUserInteractionBreadcrumbs = false;
  options.tracesSampleRate = 0.1;
  options.beforeSend = (event, hint) => scrubSentryEvent(event);
}

/// Strips request payloads and user identity from [event].
@visibleForTesting
SentryEvent scrubSentryEvent(SentryEvent event) {
  event.request = null;
  event.user = null;
  return event;
}
