import 'profile_service.dart';

/// Per-user, per-feature seen-state for the feature tour (§11.2).
///
/// The tour is an ordered list of features ([tourFeatures]), each with a stable
/// `feature_id`. This store records WHICH feature ids a user has already been
/// shown, persisted on their own profile document
/// (`users/{uid}/profile/main.seen_tour_features`) so it follows them across
/// devices and reinstalls — not a local flag.
///
/// How the gating reads it:
///  * [loadSeen] empty  → first run: show the full walkthrough, then
///    [markSeen] every current id.
///  * [loadSeen] missing some current ids → those are NEW features shipped
///    since the user last saw the tour: spotlight only them, then mark them.
///  * [loadSeen] covers every current id → show nothing.
///
/// Methods are overridable so tests can supply an in-memory double without
/// Firebase. The seen set is own-profile only — never another user's.
class FeatureTourStore {
  FeatureTourStore({ProfileService? profiles}) : _profilesOverride = profiles;

  final ProfileService? _profilesOverride;

  // Lazy so a test double (or a signed-out context) never constructs a real
  // ProfileService before Firebase is ready.
  ProfileService get _profiles => _profilesOverride ?? ProfileService();

  /// The feature ids this user has already seen. Empty (not seen) on any
  /// storage failure or signed-out state — a broken read shows the tour
  /// rather than hiding it.
  Future<Set<String>> loadSeen() async {
    try {
      return await _profiles.readSeenTourFeatures();
    } catch (_) {
      return <String>{};
    }
  }

  /// Marks [featureIds] seen so they never auto-show again (idempotent).
  Future<void> markSeen(Iterable<String> featureIds) async {
    try {
      await _profiles.markTourFeaturesSeen(featureIds);
    } catch (_) {/* best-effort */}
  }

  /// Developer-only: clears the seen set so the full tour shows again.
  Future<void> reset() async {
    try {
      await _profiles.resetTourFeatures();
    } catch (_) {/* best-effort */}
  }
}

/// App-wide instance — the main-shell gate, the Settings replay entry and the
/// Developer panel all share it.
final featureTourStoreGlobal = FeatureTourStore();
