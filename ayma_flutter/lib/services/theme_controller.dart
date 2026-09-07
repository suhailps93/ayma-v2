import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide light/dark/system preference (§14.1), persisted locally. The root
/// [MaterialApp] listens to this; the Settings screen writes it.
class ThemeController extends ChangeNotifier {
  ThemeController({ThemeMode initial = ThemeMode.light}) : _mode = initial;

  static const _key = 'theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Load the saved preference. Defaults to light; a user can still pick dark or
  /// system from Settings and that choice is what persists.
  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      _mode = _parse(raw) ?? _mode;
      notifyListeners();
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
