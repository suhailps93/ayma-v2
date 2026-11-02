import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart' show kInteractiveTimeout;

final _log = Logger('meta_integrations');

/// Runtime flag `meta_integrations` (Firestore `app_config/meta_integrations`,
/// `{enabled: bool}`, mirrored from `config/feature_flags` by
/// `scripts/flags.py`). Instagram / Facebook connect, sign-in and photo import
/// are deferred to V2: while this is off every entry point is hidden. A missing
/// doc, missing field or unreadable cache means OFF. The last fetched value is
/// cached on-device and applied at the next launch.
class MetaIntegrations {
  MetaIntegrations._();

  static const collection = 'app_config';
  static const docId = 'meta_integrations';
  static const _kEnabled = 'meta_integrations_enabled';

  /// Current value; widgets read this synchronously. Defaults to OFF.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static Completer<void>? _readyCompleter;

  /// Awaits readiness of the cached meta integrations flag.
  static Future<void> ensureReady() async {
    if (_readyCompleter != null) {
      await _readyCompleter!.future;
      return;
    }
    await loadCached();
  }

  /// Only a literal `enabled: true` turns the integrations on.
  static bool parse(Map<String, dynamic>? data) => data?['enabled'] == true;

  /// Synchronously loads flag from preloaded preferences.
  static void loadFromPrefs(SharedPreferences prefs) {
    try {
      enabled.value = prefs.getBool(_kEnabled) ?? false;
    } catch (e) {
      _log.warning('flag cache unreadable: $e');
      enabled.value = false;
    } finally {
      if (_readyCompleter == null) {
        _readyCompleter = Completer<void>()..complete();
      } else if (!_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
    }
  }

  /// Applies the cached value from the last successful [refresh].
  static Future<void> loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      loadFromPrefs(prefs);
    } catch (e) {
      _log.warning('flag cache unreadable: $e');
      enabled.value = false;
      if (_readyCompleter == null) {
        _readyCompleter = Completer<void>()..complete();
      } else if (!_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
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
      final value = parse(snap.data());
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, value);
    } catch (e) {
      _log.warning('flag refresh failed: $e');
    }
  }
}
