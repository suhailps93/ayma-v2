import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single-user persistent store for chat messages marked with thumbs-down feedback (D6).
///
/// Ensures marked state ("noted", filled thumb icon) survives force-stop and app relaunch.
class ThumbsDownStore {
  ThumbsDownStore._();
  static final ThumbsDownStore instance = ThumbsDownStore._();

  static const _keyPrefix = 'ayma_thumbs_down_';
  final Set<String> _flaggedQuotes = {};
  String? _loadedUid;

  @visibleForTesting
  void reset() {
    _flaggedQuotes.clear();
    _loadedUid = null;
  }

  Future<void> load(String uid) async {
    final effectiveUid = uid.isEmpty ? 'default' : uid;
    if (_loadedUid == effectiveUid) return;
    _loadedUid = effectiveUid;
    _flaggedQuotes.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('$_keyPrefix$effectiveUid') ?? const [];
      _flaggedQuotes.addAll(list.map((s) => s.trim()));
    } catch (_) {}
  }

  bool isFlagged(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return _flaggedQuotes.contains(trimmed);
  }

  Future<void> recordThumbsDown(String uid, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _flaggedQuotes.add(trimmed);
    final effectiveUid = uid.isEmpty ? (_loadedUid ?? 'default') : uid;
    _loadedUid = effectiveUid;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('$_keyPrefix$effectiveUid', _flaggedQuotes.toList());
    } catch (_) {}
  }
}
