import 'package:flutter/foundation.dart';

import 'tour_content.dart';

/// One step of the Ayma-DRIVEN interactive tour (§11.2b), pushed from the
/// backend (`skills/guided_tour.py`) one at a time as a `tour_step` app-command
/// and rendered by the root [TourHost] through the shared [CoachMarkOverlay].
///
/// Unlike the passive tour (a local `List<TourFeature>` the overlay walks on
/// its own), each driven step is a single [feature] plus callbacks that report
/// back to [AppCommandService] so the backend can ack it and wait for the
/// user's real tap before sending the next step:
///  * [onShown]   — the spotlight is up (ack `ok:true`);
///  * [onAbsent]  — the anchor isn't on this build (ack `ok:false` → backend
///                  skips the step honestly);
///  * [onTapped]  — the user tapped the highlighted control (the tour advances);
///  * [onStop]    — the user pressed "Skip tour" (the whole tour ends).
@immutable
class GuidedTourStep {
  const GuidedTourStep({
    required this.token,
    required this.feature,
    required this.index,
    required this.total,
    required this.onShown,
    required this.onAbsent,
    required this.onTapped,
    required this.onStop,
  });

  /// A per-command id; the overlay is keyed by it so every pushed step gets a
  /// fresh measure (and so [onShown] fires once for each one).
  final String token;

  /// The single spotlighted step, built from the backend command.
  final TourFeature feature;

  /// 0-based position and total, for the "N of M" callout counter.
  final int index;
  final int total;

  final VoidCallback onShown;
  final VoidCallback onAbsent;
  final VoidCallback onTapped;
  final VoidCallback onStop;
}

/// App-wide controller for the Ayma-driven tour's current step. A singleton like
/// [TourController] / [TabRequest]: [AppCommandService] drives it from
/// `tour_step` / `tour_end` commands, the root [TourHost] renders it (ABOVE the
/// passive tour, so the two never stack). Holds exactly one step at a time;
/// [show] replaces it, [dismiss] clears it.
class GuidedTourController extends ChangeNotifier {
  GuidedTourController._();

  static final GuidedTourController instance = GuidedTourController._();

  GuidedTourStep? _step;

  /// The step currently being spotlighted, or null when no driven tour step is
  /// up.
  GuidedTourStep? get step => _step;

  /// Whether a driven tour step is currently showing.
  bool get active => _step != null;

  /// Show (or replace) the current driven step.
  void show(GuidedTourStep step) {
    _step = step;
    notifyListeners();
  }

  /// Clear the current step (the backend ended the tour, or the step's anchor
  /// was absent). A no-op when nothing is showing.
  void dismiss() {
    if (_step == null) return;
    _step = null;
    notifyListeners();
  }
}
