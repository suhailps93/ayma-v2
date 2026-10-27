import 'package:shared_preferences/shared_preferences.dart';

/// Whether the first-launch feature tour (`FeatureTourScreen`) has already
/// been shown, persisted locally — same best-effort `SharedPreferences`
/// pattern as [OrbAnimationSettings]/`ThemeController`: [load] reads the flag
/// once at startup so [seen] is available synchronously when splash decides
/// where to route (§11.2), setters write through.
///
/// A single global instance ([featureTourStoreGlobal]) so the splash gate and
/// the Developer-panel reset read and write the same flag. The tour is a pure
/// client-side pre-screen: it never touches auth, the server-derived
/// `session_mode`, or the age/consent gates — it only precedes the anonymous
/// landing on the very first launch, then hands off to the normal flow.
class FeatureTourStore {
  FeatureTourStore();

  static const _key = 'feature_tour_seen';

  bool _seen = false;

  /// Whether the tour has been dismissed (last page CTA or Skip) before.
  /// Defaults to `false` (never seen) until [load] says otherwise, and on any
  /// storage failure — so a broken read shows the tour rather than hiding it.
  bool get seen => _seen;

  /// Reads the saved flag. Defaults (not seen) survive a missing key or
  /// missing storage (tests / restricted context).
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen = prefs.getBool(_key) ?? false;
    } catch (_) {
      // No storage — keep the default (not seen).
    }
  }

  /// Marks the tour dismissed so it never shows again on launch.
  Future<void> markSeen() async {
    _seen = true;
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (_) {/* best-effort */}
  }

  /// Developer-only: clears the flag so the tour shows again next launch.
  Future<void> reset() async {
    _seen = false;
    try {
      await (await SharedPreferences.getInstance()).remove(_key);
    } catch (_) {/* best-effort */}
  }
}

/// App-wide instance — the splash gate, the tour screen and the Developer
/// panel all share it.
final featureTourStoreGlobal = FeatureTourStore();
