import 'package:flutter/foundation.dart';

/// App-wide signal that a report finished (re)generating in the background, so
/// any report view currently on screen re-fetches and shows the fresh result
/// without the user reloading by hand.
///
/// Background runs (e.g. the Appearance analysis fired from the Skills screen
/// or the report screen's Re-run — see `skills_screen.dart`) are not tied to
/// the widget that started them: the user can navigate away, and the open
/// report screen never learned the run landed (founder 2026-10-28: "it didn't
/// create a new report" when the backend actually had). On success the runner
/// calls [completed] with the report type; [LivingReportView] listens and
/// reloads when its own type bumps.
///
/// A per-type monotonically increasing revision lets a listener react exactly
/// once per completion (compare the revision it last handled) instead of
/// reloading on every unrelated notification.
class ReportEvents extends ChangeNotifier {
  ReportEvents._();
  static final ReportEvents instance = ReportEvents._();

  final Map<String, int> _revisions = {};

  /// How many times a report of [reportType] has completed. 0 before the
  /// first completion this session.
  int revisionFor(String reportType) => _revisions[reportType] ?? 0;

  /// Signal that a [reportType] report finished regenerating. Bumps its
  /// revision and notifies listeners.
  void completed(String reportType) {
    _revisions[reportType] = (_revisions[reportType] ?? 0) + 1;
    notifyListeners();
  }
}
