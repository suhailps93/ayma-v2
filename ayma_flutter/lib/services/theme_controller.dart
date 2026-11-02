import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide light/dark/system preference (§14.1), persisted locally. The root
/// [MaterialApp] listens to this; the Settings screen writes it.
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initial = ThemeMode.dark}) : _mode = initial;

  static const _key = 'theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Hydrate from preloaded preferences (synchronous fast path).
  void loadFromPrefs(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_key);
      _mode = _parse(raw) ?? _mode;
      notifyListeners();
    } catch (_) {
      // Keep current mode on read error
    }
  }

  /// Load the saved preference. Defaults to dark (founder 2026-09-22: dark
  /// mode is the app default for anyone who hasn't explicitly chosen
  /// otherwise) — a user can still pick light or system from Settings, and
  /// once they have, [_parse] below reads that saved value back and
  /// overrides this default; it's only ever what a fresh install/unset user
  /// sees.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      loadFromPrefs(prefs);
    } catch (_) {
      // No storage (tests / restricted context) — keep the default.
    }
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, mode.name);
    } catch (_) {/* best-effort */}
  }

  static ThemeMode? _parse(String? raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => null,
      };
}

/// App-wide instance — the root [MaterialApp] and the Settings screen share it.
final themeControllerGlobal = ThemeController();
