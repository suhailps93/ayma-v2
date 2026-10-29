import 'package:flutter/foundation.dart';

import 'feature_tour_store.dart';
import 'tour_content.dart';

/// App-wide controller for the interactive feature tour (§11.2a).
///
/// The tour is a single floating coach-mark that must stay open as the user
/// (or the tour itself) moves between pages. So it is NOT hosted inside any one
/// screen any more — a screen's overlay is torn down the moment a route is
/// pushed on top of it (the founder's "the pop-up goes away when you click to a
/// different page"). Instead a single [TourHost] mounts the overlay at the root
/// of the app, ABOVE the `Navigator` (in `MaterialApp.router`'s `builder`), and
/// watches this controller: when a session is [active] the one overlay renders
/// it and survives every route push.
///
/// The shell still OWNS the decision of when to start (the post-pre-boarding /
/// first-chat gate and the Settings/Dev replay — see `MainShellScreen`), it just
/// delegates the HOSTING here by calling [start] instead of holding overlay
/// state itself. Finishing or skipping writes the per-user seen-state (via
/// [FeatureTourStore]) exactly as before.
class TourController extends ChangeNotifier {
  TourController._();

  /// App-wide instance — the shell's gate starts it, the root [TourHost]
  /// renders it. A singleton (like `TabRequest`/`TourRequest`): never disposed.
  static final TourController instance = TourController._();

  List<TourFeature>? _features;
  bool _spotlight = false;
  FeatureTourStore? _store;

  /// The steps of the running tour, or null when none is running.
  List<TourFeature>? get features => _features;

  /// New-feature spotlight framing vs the full first-run walkthrough.
  bool get spotlight => _spotlight;

  /// Whether a tour is currently running (the overlay is up).
  bool get active => _features != null;

  /// The seen-state store the running tour writes to (a test double when the
  /// shell injected one, otherwise the app-wide store).
  FeatureTourStore get store => _store ?? featureTourStoreGlobal;

  /// Starts a tour. A no-op if one is already running (never stack two) or the
  /// step list is empty. [store] lets the shell pass its test-injected double.
  void start(
    List<TourFeature> features, {
    required bool spotlight,
    FeatureTourStore? store,
  }) {
    if (features.isEmpty || active) return;
    _features = List<TourFeature>.unmodifiable(features);
    _spotlight = spotlight;
    _store = store;
    notifyListeners();
  }

  /// Ends the running tour's hosting. The overlay calls this from its
  /// `onFinish` AFTER it has already written seen-state, so this only clears
  /// the session — it does not touch the store.
  void finish() {
    if (!active) return;
    _features = null;
    _store = null;
    notifyListeners();
  }

  /// Back pressed while the tour is up: skip it, marking every shown feature
  /// seen (the same as completing) so it doesn't nag again, then clear. Mirrors
  /// the old in-shell `_skipTourFromBack`; now driven by the root host's
  /// `BackButtonListener` since the overlay no longer lives in the shell route.
  Future<void> skipFromBack() async {
    final features = _features;
    final store = this.store;
    if (features == null) return;
    _features = null;
    _store = null;
    notifyListeners();
    await store.markSeen(features.map((f) => f.featureId));
  }
}
