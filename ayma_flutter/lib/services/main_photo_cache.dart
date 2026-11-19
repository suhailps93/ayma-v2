import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-user persistent cache of the LAST-KNOWN main-photo thumb URL (the public
/// profile's primary/order-0 photo). Lets the Story cover hero paint its thumb
/// at once on a cold open, instead of a shimmer until the cold-start-retried
/// `publicProfile` GET lands (~12s) — Scout NOTE 272 Leg 3.
///
/// Only the URL is stored: the thumb's bytes already survive a force-stop in
/// `cached_network_image`'s on-disk cache (keyed by URL), so the cached thumb
/// paints from disk with no network. Keyed by uid, so a different signed-in
/// user never sees a previous account's photo. If the stored URL has gone stale
/// (the user changed their primary photo) the fresh GET replaces it within the
/// same open — a brief last-known thumb, never a wrong-account one.
class MainPhotoCache {
  MainPhotoCache._();
  static final MainPhotoCache instance = MainPhotoCache._();

  static const _thumbPrefix = 'ayma_main_photo_thumb_';

  final Map<String, String?> _mem = {};

  @visibleForTesting
  void reset() => _mem.clear();

  String _key(String uid) => uid.isEmpty ? 'default' : uid;

  /// Warms the in-memory copy for [uid] from disk. After this completes,
  /// [thumbFor] returns synchronously. Safe to call repeatedly.
  Future<void> load(String uid) async {
    final key = _key(uid);
    try {
      final prefs = await SharedPreferences.getInstance();
      _mem[key] = prefs.getString('$_thumbPrefix$key');
    } catch (_) {
      // No cache is fine — the hero falls back to its reserved frame.
    }
  }

  /// The last-known thumb URL for [uid], or null if nothing is loaded for them
  /// yet (or they have no cached photo).
  String? thumbFor(String uid) => _mem[_key(uid)];

  /// Persists the freshly-resolved thumb URL for [uid]. A null/empty value
  /// clears the entry (e.g. the user removed their only photo).
  Future<void> save(String uid, String? thumb) async {
    final key = _key(uid);
    _mem[key] = (thumb != null && thumb.isNotEmpty) ? thumb : null;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (thumb == null || thumb.isEmpty) {
        await prefs.remove('$_thumbPrefix$key');
      } else {
        await prefs.setString('$_thumbPrefix$key', thumb);
      }
    } catch (_) {}
  }
}
