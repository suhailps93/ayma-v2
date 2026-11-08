// ignore_for_file: avoid_print

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart' show kStartupFlagRefreshTimeout;

final _log = Logger('debug_capture_isolation');

/// Debug-only flag that turns OFF client-side capture isolation for voice
/// sessions (bench A/B test for the NOTE 126 bench-deaf cause, ledger 2bx).
///
/// Firestore doc `app_config/debug_capture_isolation`, `{enabled: bool}`.
/// Only a literal `enabled: true` disables isolation. A missing doc, missing
/// field, or unreadable cache means OFF — isolation stays ON, which is the
/// founder rule (isolation ON by default wherever covered). The flag doc
/// exists only in the ayma-staging project, and this code lives only on the
/// staging branch, so prod can never see it on.
///
/// When the flag is ON, the voice transport publishes the mic with
/// `AudioCaptureOptions(noiseSuppression: false)`. In livekit_client 2.6.4
/// that one switch drives the emitted getUserMedia constraints for BOTH
/// `voiceIsolation` and `googNoiseSuppression` (the constraints map keys
/// `voiceIsolation` off `noiseSuppression`, not off the `voiceIsolation`
/// field). Echo cancellation and auto-gain control stay at their defaults:
/// the A/B test is about noise suppression / voice isolation only.
///
/// Wiring: loaded from prefs at startup (N5) and refreshed from Firestore
/// at startup (N19), same pattern as [MetaIntegrations]. Unlike
/// MetaIntegrations, [refresh] also updates the in-memory value at once, so
/// a flip takes effect on the next app launch (one relaunch), not two:
/// Scout flips the doc in the Firebase console, force-stops the app,
/// relaunches, and the next voice session runs with isolation off.
class DebugCaptureIsolation {
  DebugCaptureIsolation._();

  static const collection = 'app_config';
  static const docId = 'debug_capture_isolation';
  static const _kDisabled = 'debug_capture_isolation_disabled';

  /// Current value; the voice transport reads this synchronously at
  /// session start. Defaults to OFF (isolation on).
  static final ValueNotifier<bool> disabled = ValueNotifier<bool>(false);

  static Completer<void>? _readyCompleter;
  static Future<void>? _refreshFuture;

  /// Converts various primitive representations of boolean to bool?
  static bool? _asBool(Object? val) {
    if (val is bool) return val;
    if (val is String) {
      final s = val.trim().toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    if (val is num) {
      if (val == 1) return true;
      if (val == 0) return false;
    }
    return null;
  }

  /// Awaits readiness of the cached flag.
  static Future<void> ensureReady({FirebaseFirestore? db}) async {
    await loadCached();
    if (db != null) {
      try {
        await refresh(
          db,
          timeout: const Duration(seconds: 2),
          maxRetries: 0,
        ).timeout(const Duration(seconds: 2));
      } catch (_) {}
    } else if (_refreshFuture != null) {
      try {
        await _refreshFuture!.timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    disabled.value = false;
    _readyCompleter = null;
    _refreshFuture = null;
  }

  /// Synchronously or asynchronously reads the flag value at session connect,
  /// ensuring any cached or disk-seeded preference has been loaded. If no [db]
  /// is passed, attempts to use [FirebaseFirestore.instance] if available.
  static Future<bool> readAtConnect({FirebaseFirestore? db}) async {
    FirebaseFirestore? firestore = db;
    if (firestore == null) {
      try {
        firestore = FirebaseFirestore.instance;
      } catch (_) {
        // Leave null in unit test environments without Firebase initialized.
      }
    }
    await ensureReady(db: firestore);
    return disabled.value;
  }

  /// Only a literal `enabled: true` disables capture isolation.
  static bool parse(Map<String, dynamic>? data) => data?['enabled'] == true;

  /// Synchronously loads the flag from preloaded preferences.
  static void loadFromPrefs(SharedPreferences prefs) {
    try {
      final raw = prefs.get(_kDisabled) ?? prefs.get('flutter.$_kDisabled');
      final val = _asBool(raw);
      if (val != null) {
        disabled.value = val;
      }
      final msg = '[debug_capture_isolation] loadFromPrefs: '
          'disabled.value=${disabled.value} (raw=$raw)';
      _log.info(msg);
      debugPrint(msg);
      print(msg);
    } catch (e) {
      final err = '[debug_capture_isolation] flag cache unreadable: $e';
      _log.warning(err);
      debugPrint(err);
      print(err);
      disabled.value = false;
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
      try {
        await prefs.reload();
      } catch (e) {
        debugPrint('[debug_capture_isolation] prefs.reload non-fatal: $e');
      }
      loadFromPrefs(prefs);
    } catch (e) {
      final err = '[debug_capture_isolation] loadCached error: $e';
      debugPrint(err);
      print(err);
      disabled.value = false;
      if (_readyCompleter == null) {
        _readyCompleter = Completer<void>()..complete();
      } else if (!_readyCompleter!.isCompleted) {
        _readyCompleter!.complete();
      }
    }
  }

  /// Fetches the Firestore flag, caches it for the next launch, and applies
  /// it in memory at once. Never throws; a failure leaves the cached value
  /// untouched. Concurrent calls share the in-flight future.
  static Future<void> refresh(
    FirebaseFirestore db, {
    Duration timeout = kStartupFlagRefreshTimeout,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 1),
  }) {
    if (_refreshFuture != null) {
      return _refreshFuture!;
    }
    final fut = _doRefresh(
      db,
      timeout: timeout,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
    );
    _refreshFuture = fut;
    fut.whenComplete(() {
      if (identical(_refreshFuture, fut)) {
        _refreshFuture = null;
      }
    });
    return fut;
  }

  static Future<void> _doRefresh(
    FirebaseFirestore db, {
    Duration timeout = kStartupFlagRefreshTimeout,
    int maxRetries = 2,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final snap = await db
            .collection(collection)
            .doc(docId)
            .get()
            .timeout(timeout);
        if (snap.exists) {
          final value = parse(snap.data());
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_kDisabled, value);
          disabled.value = value;
          final msg = '[debug_capture_isolation] flag refreshed: '
              'capture isolation disabled=$value';
          _log.info(msg);
          debugPrint(msg);
          print(msg);
        } else {
          final msg = '[debug_capture_isolation] flag doc $collection/$docId '
              'does not exist; keeping cached value';
          _log.info(msg);
          debugPrint(msg);
          print(msg);
        }
        return;
      } catch (e) {
        final isLast = attempt >= maxRetries;
        if (isLast) {
          final err = '[debug_capture_isolation] flag refresh failed: $e';
          _log.warning(err);
          debugPrint(err);
          print(err);
        } else {
          final err = '[debug_capture_isolation] flag refresh attempt '
              '${attempt + 1} failed: $e; retrying in ${retryDelay.inSeconds}s';
          _log.info(err);
          debugPrint(err);
          print(err);
          await Future<void>.delayed(retryDelay);
        }
      }
    }
  }
}
