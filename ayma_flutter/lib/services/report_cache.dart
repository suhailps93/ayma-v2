import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/boot_config.dart';

/// Lightweight, per-device, stale-while-revalidate cache for the heavy report
/// pages and the cold-start boot state.
///
/// Why: the appearance / body / deep-dive report pages refetch from scratch on
/// every open and take a visible beat to load (founder: "body and [others]
/// take time to load, should we cache them? — yes"). This stores the last
/// successful payload locally so the page can paint instantly on open, then
/// fetch fresh in the background and swap the result in when it lands. Cold
/// start reuses the exact same pattern for the resolved entry route so the app
/// can show its last-known UI immediately instead of blocking the splash on
/// the full bootstrap (founder: "show the cached page and bootstrap in the
/// backend").
///
/// PRIVACY: every entry is the signed-in user's OWN data, stored only on this
/// device via [SharedPreferences]; nothing is shared across users. Keys are
/// scoped by uid so a different account on the same device never reads another
/// account's cache, and [clearForSignOut] wipes every cached report and boot
/// route on sign-out / account deletion so nothing of the previous user
/// survives. Every read/write is best-effort and swallows storage errors — a
/// missing or broken cache simply falls back to a normal network fetch.
class ReportCache {
  ReportCache._();
  static final ReportCache instance = ReportCache._();

  /// All keys this cache owns start with one of these, so [clearForSignOut]
  /// can wipe them without touching unrelated preferences (theme, accent, …).
  static const _reportPrefix = 'report_cache:';
  static const _bootPrefix = 'boot_route:';
  static const _bootConfigPrefix = 'boot_config:';

  static String _reportKey(String uid, String reportType, String reportId) =>
      '$_reportPrefix$uid:$reportType:$reportId';

  static String _bootKey(String uid) => '$_bootPrefix$uid';
  static String _bootConfigKey(String uid) => '$_bootConfigPrefix$uid';

  Completer<void>? _readyCompleter;
  SharedPreferences? _preloadedPrefs;

  /// Signals that the report cache has access to hydrated preferences.
  void hydrateFromPrefs(SharedPreferences prefs) {
    _preloadedPrefs = prefs;
    if (_readyCompleter == null) {
      _readyCompleter = Completer<void>()..complete();
    } else if (!_readyCompleter!.isCompleted) {
      _readyCompleter!.complete();
    }
  }

  /// Ensures that ReportCache preferences are loaded.
  Future<void> ensureReady() async {
    if (_readyCompleter != null) {
      await _readyCompleter!.future;
      return;
    }
    _preloadedPrefs ??= await SharedPreferences.getInstance();
    _readyCompleter = Completer<void>()..complete();
  }

  Future<SharedPreferences> _getPrefs() async {
    if (_preloadedPrefs != null) return _preloadedPrefs!;
    return await SharedPreferences.getInstance();
  }

  /// Reset internal state for test isolation.
  @visibleForTesting
  void resetForTest() {
    _readyCompleter = null;
    _preloadedPrefs = null;
  }

  /// The cached JSON payload for a report, or null when nothing is cached (or
  /// on any storage error). [uid] empty (signed-out / tests) never caches.
  Future<String?> readReport(
      String uid, String reportType, String reportId) async {
    if (uid.isEmpty) return null;
    try {
      final prefs = await _getPrefs();
      return prefs.getString(_reportKey(uid, reportType, reportId));
    } catch (e) {
      debugPrint('report cache read failed: $e');
      return null;
    }
  }

  /// Store the fresh JSON [payload] for a report. Best-effort.
  Future<void> writeReport(
      String uid, String reportType, String reportId, String payload) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await _getPrefs();
      await prefs.setString(_reportKey(uid, reportType, reportId), payload);
    } catch (e) {
      debugPrint('report cache write failed: $e');
    }
  }

  /// Reads the structured [BootConfig] for [uid] from storage.
  /// If stale (> 7 days), returns null (treating as cache miss per M17).
  /// Falls back to legacy `boot_route:$uid` during migration if no boot_config exists.
  Future<BootConfig?> readBootConfig(String uid) async {
    if (uid.isEmpty) return null;
    try {
      final prefs = await _getPrefs();
      final raw = prefs.getString(_bootConfigKey(uid));
      if (raw != null) {
        final config = BootConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (!config.isStale) {
          return config;
        }
        return null;
      }
      // Migration bridge: fall back to legacy boot_route if present
      final legacy = prefs.getString(_bootKey(uid));
      if (legacy != null && legacy.isNotEmpty) {
        return BootConfig(
          uid: uid,
          sessionMode: 'active',
          entryRoute: legacy,
          cachedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      return null;
    } catch (e) {
      debugPrint('boot config read failed: $e');
      return null;
    }
  }

  /// Writes [BootConfig] to storage. Also mirrors [BootConfig.entryRoute] to
  /// the legacy `boot_route:$uid` key during transition.
  Future<void> writeBootConfig(String uid, BootConfig config) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await _getPrefs();
      await prefs.setString(_bootConfigKey(uid), jsonEncode(config.toJson()));
      await prefs.setString(_bootKey(uid), config.entryRoute);
    } catch (e) {
      debugPrint('boot config write failed: $e');
    }
  }

  /// The cached entry route for [uid]'s last successful bootstrap, or null.
  /// Used to render the last-known UI immediately on cold start.
  Future<String?> readBootRoute(String uid) async {
    final config = await readBootConfig(uid);
    if (config != null) return config.entryRoute;
    if (uid.isEmpty) return null;
    try {
      final prefs = await _getPrefs();
      return prefs.getString(_bootKey(uid));
    } catch (e) {
      debugPrint('boot route read failed: $e');
      return null;
    }
  }

  /// Remember the route a successful bootstrap resolved to for [uid].
  Future<void> writeBootRoute(String uid, String route) async {
    if (uid.isEmpty || route.isEmpty) return;
    final config = BootConfig(
      uid: uid,
      sessionMode: 'active',
      entryRoute: route,
      cachedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    await writeBootConfig(uid, config);
  }

  /// Wipe every cached report and boot route (sign-out / account deletion), so
  /// none of the previous user's data survives on the device.
  Future<void> clearForSignOut() async {
    try {
      final prefs = await _getPrefs();
      final keys = prefs
          .getKeys()
          .where((k) =>
              k.startsWith(_reportPrefix) ||
              k.startsWith(_bootPrefix) ||
              k.startsWith(_bootConfigPrefix))
          .toList();
      for (final k in keys) {
        await prefs.remove(k);
      }
    } catch (e) {
      debugPrint('report cache clear failed: $e');
    }
  }
}
