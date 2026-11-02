import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart' show kInteractiveTimeout;

final _log = Logger('sentry');

/// Sentry DSN, supplied at build time via `--dart-define=SENTRY_DSN=...`.
/// Empty (the default: local dev, tests) disables Sentry entirely.
const String sentryDsn = String.fromEnvironment('SENTRY_DSN');

/// Compile-time kill switch (`--dart-define=SENTRY_ENABLED=false`). When false
/// Sentry never initialises and the Firestore flag is never fetched.
const bool sentryCompiledIn =
    bool.fromEnvironment('SENTRY_ENABLED', defaultValue: true);

/// Release / dist / environment tags, set by codemagic.yaml. Optional.
const String _sentryRelease = String.fromEnvironment('SENTRY_RELEASE');
const String _sentryDist = String.fromEnvironment('SENTRY_DIST');
const String _sentryEnvironment = String.fromEnvironment('SENTRY_ENVIRONMENT');

/// Runtime flag, kept in the Firestore doc `app_config/sentry`:
/// `{enabled: bool, traces_sample_rate: 0..1, error_sample_rate: 0..1}`.
/// A missing doc, missing field or malformed value means ON (the all-features-on
/// default); only a literal `enabled: false` is the kill switch. Rates fall
/// back to the low defaults. The last fetched value is cached on-device and read at the
/// next launch, so startup never waits on the network.
@immutable
class SentryFlag {
  const SentryFlag({
    this.enabled = true,
    this.tracesSampleRate = defaultTracesSampleRate,
    this.errorSampleRate = defaultErrorSampleRate,
  });

  static const defaultTracesSampleRate = 0.05;
  static const defaultErrorSampleRate = 1.0;

  static const collection = 'app_config';
  static const docId = 'sentry';
  static const _kEnabled = 'sentry_flag_enabled';
  static const _kTraces = 'sentry_flag_traces';
  static const _kErrors = 'sentry_flag_errors';

  final bool enabled;
  final double tracesSampleRate;
  final double errorSampleRate;

  /// Parses a flag doc. Only a literal `false` disables; rates outside 0..1 or
  /// of the wrong type fall back to the defaults.
  factory SentryFlag.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const SentryFlag();
    double rate(Object? v, double fallback) =>
        v is num && v >= 0 && v <= 1 ? v.toDouble() : fallback;
    return SentryFlag(
      enabled: data['enabled'] is bool ? data['enabled'] as bool : true,
      tracesSampleRate:
          rate(data['traces_sample_rate'], defaultTracesSampleRate),
      errorSampleRate: rate(data['error_sample_rate'], defaultErrorSampleRate),
    );
  }

  /// In-memory parse from preloaded preferences.
  static SentryFlag loadFromPrefs(SharedPreferences prefs) {
    try {
      return SentryFlag.fromMap({
        'enabled': prefs.getBool(_kEnabled),
        'traces_sample_rate': prefs.getDouble(_kTraces),
        'error_sample_rate': prefs.getDouble(_kErrors),
      });
    } catch (e) {
      _log.warning('flag cache unreadable: $e');
      return const SentryFlag();
    }
  }

  /// The cached flag from the last successful [refresh]; the default (ON) when
  /// there is none or the store is unreadable.
  static Future<SentryFlag> loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return loadFromPrefs(prefs);
    } catch (e) {
      _log.warning('flag cache unreadable: $e');
      return const SentryFlag();
    }
  }

  /// Fetches the Firestore flag and caches it for the next launch. Never
  /// throws; a failure leaves the cached value untouched.
  static Future<void> refresh(FirebaseFirestore db) async {
    try {
      final snap = await db
          .collection(collection)
          .doc(docId)
          .get()
          .timeout(kInteractiveTimeout);
      final flag = SentryFlag.fromMap(snap.data());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, flag.enabled);
      await prefs.setDouble(_kTraces, flag.tracesSampleRate);
      await prefs.setDouble(_kErrors, flag.errorSampleRate);
    } catch (e) {
      _log.warning('flag refresh failed: $e');
    }
  }
}

/// Whether Sentry may start: a DSN, the compile-time switch and the runtime
/// flag must all agree. Anything else means no SDK, no events, no network.
bool sentryShouldRun(
  SentryFlag flag, {
  String dsn = sentryDsn,
  bool compiledIn = sentryCompiledIn,
}) {
  return dsn.isNotEmpty && compiledIn && flag.enabled;
}

/// Configures Sentry from [flag]. No PII, screenshots, view hierarchy,
/// interaction breadcrumbs or failed-request capture; request bodies, user
/// identity and any email / phone number in text are removed by
/// [scrubSentryEvent] so user messages, transcripts, photos and audio never
/// leave the device.
void configureSentryOptions(SentryFlutterOptions options, SentryFlag flag) {
  options.dsn = sentryDsn;
  options.environment = _sentryEnvironment.isNotEmpty
      ? _sentryEnvironment
      : (kReleaseMode ? 'production' : 'development');
  if (_sentryRelease.isNotEmpty) options.release = _sentryRelease;
  if (_sentryDist.isNotEmpty) options.dist = _sentryDist;
  options.sendDefaultPii = false;
  options.attachScreenshot = false;
  options.attachViewHierarchy = false;
  options.enableUserInteractionBreadcrumbs = false;
  options.enableUserInteractionTracing = false;
  options.captureFailedRequests = false;
  options.maxRequestBodySize = MaxRequestBodySize.never;
  options.sampleRate = flag.errorSampleRate;
  options.tracesSampleRate = flag.tracesSampleRate;
  options.beforeSend = (event, hint) => scrubSentryEvent(event);
  options.beforeSendTransaction =
      (transaction, hint) => scrubSentryTransaction(transaction);
  options.beforeBreadcrumb = (crumb, hint) => scrubSentryBreadcrumb(crumb);
}

final _emailRe = RegExp(r'[\w.+\-]+@[\w\-]+(\.[\w\-]+)+');
final _phoneRe = RegExp(r'\+?\d[\d\s().\-]{7,}\d');

/// Replaces emails and phone-number-like runs in [text] with placeholders.
@visibleForTesting
String redactText(String text) =>
    text.replaceAll(_emailRe, '[email]').replaceAll(_phoneRe, '[phone]');

/// Strips request payloads, user identity, extra data and breadcrumb payloads
/// from [event], and redacts emails / phone numbers from every text field.
@visibleForTesting
SentryEvent scrubSentryEvent(SentryEvent event) {
  event.request = null;
  event.user = null;
  // Deprecated, but still sent if a plugin sets it: clear it defensively.
  // ignore: deprecated_member_use
  event.extra = null;
  final message = event.message;
  if (message != null) {
    message.formatted = redactText(message.formatted);
    message.params = null;
  }
  for (final e in event.exceptions ?? const <SentryException>[]) {
    final v = e.value;
    if (v != null) e.value = redactText(v);
  }
  final crumbs = event.breadcrumbs;
  if (crumbs != null) {
    event.breadcrumbs = [
      for (final c in crumbs) scrubSentryBreadcrumb(c)!,
    ];
  }
  return event;
}

/// Same scrubbing for performance transactions.
@visibleForTesting
SentryTransaction scrubSentryTransaction(SentryTransaction transaction) {
  scrubSentryEvent(transaction);
  final name = transaction.transaction;
  if (name != null) transaction.transaction = redactText(name);
  return transaction;
}

/// Drops a breadcrumb's payload and redacts its message.
@visibleForTesting
Breadcrumb? scrubSentryBreadcrumb(Breadcrumb? crumb) {
  if (crumb == null) return null;
  crumb.data = null;
  final m = crumb.message;
  if (m != null) crumb.message = redactText(m);
  return crumb;
}
