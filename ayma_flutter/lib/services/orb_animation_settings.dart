import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-facing orb animation preferences (Settings › Animation), persisted
/// locally — same shape as `ThemeController`: a `ChangeNotifier` holding the
/// state, `load()` reads `SharedPreferences` at startup (best-effort,
/// defaults on failure), setters write through and notify. A single global
/// instance ([orbAnimationSettingsGlobal]) that every `AymaOrb` listens to,
/// so flipping a toggle updates every visible orb immediately — no restart.
///
/// Two flags, both default ON (the shipped behavior):
///
///  * [flutterEnabled] — the master switch. OFF stops the continuous
///    petal/wing flutter+pulse motion on EVERY orb instance (chat header,
///    voice screens, nav bar). The orb still renders, still does state
///    transitions and the voice-live glow; only the continuous wing motion
///    stops (petals rest at the reduced-motion calm pose), and a settled
///    orb's animation ticker stops outright — so this is a perf lever, not
///    just a cosmetic one.
///  * [navBarFlutterEnabled] — scoped switch. OFF stops the wing motion only
///    for the nav-bar orbs (`AymaTabBar`), leaving big orbs animating.
///    Ignored while [flutterEnabled] is off (everywhere-off wins) — the
///    Settings UI shows it disabled then.
class OrbAnimationSettings extends ChangeNotifier {
  OrbAnimationSettings({
    this._flutterEnabled = true,
    this._navBarFlutterEnabled = true,
  });

  static const _flutterKey = 'orb_wing_flutter_enabled';
  static const _navBarKey = 'orb_wing_flutter_nav_bar_enabled';

  bool _flutterEnabled;
  bool _navBarFlutterEnabled;

  // (Constructed with `flutterEnabled:` / `navBarFlutterEnabled:` — the
  // private named formals above bind to the underscore-stripped names.)

  /// "Wing flutter animation" — the everywhere master switch.
  bool get flutterEnabled => _flutterEnabled;

  /// "Wing flutter in nav bar" — the nav-bar-only scope. The stored value is
  /// kept even while [flutterEnabled] is off (so turning the master back on
  /// restores the user's nav-bar choice); use [flutterEnabledFor] for the
  /// effective answer.
  bool get navBarFlutterEnabled => _navBarFlutterEnabled;

  /// Whether an orb at the given placement should run its continuous wing
  /// flutter/pulse motion: everywhere-off wins, then the nav-bar scope.
  bool flutterEnabledFor({required bool navBar}) =>
      _flutterEnabled && (!navBar || _navBarFlutterEnabled);

  /// Load the saved preferences. Defaults (both ON) survive a missing key or
  /// missing storage (tests / restricted context).
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _flutterEnabled = prefs.getBool(_flutterKey) ?? _flutterEnabled;
      _navBarFlutterEnabled = prefs.getBool(_navBarKey) ?? _navBarFlutterEnabled;
      notifyListeners();
    } catch (_) {
      // No storage — keep the defaults.
    }
  }

  Future<void> setFlutterEnabled(bool value) =>
      _set(_flutterKey, value, () => _flutterEnabled = value,
          unchanged: _flutterEnabled == value);

  Future<void> setNavBarFlutterEnabled(bool value) =>
      _set(_navBarKey, value, () => _navBarFlutterEnabled = value,
          unchanged: _navBarFlutterEnabled == value);

  Future<void> _set(
    String key,
    bool value,
    void Function() apply, {
    required bool unchanged,
  }) async {
    if (unchanged) return;
    apply();
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(key, value);
    } catch (_) {/* best-effort */}
  }
}

/// App-wide instance — every `AymaOrb` and the Settings screen share it.
final orbAnimationSettingsGlobal = OrbAnimationSettings();
