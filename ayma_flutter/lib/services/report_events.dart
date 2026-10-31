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

  /// How many background runs of a [reportType] are in flight right now. A
  /// count (not a bool) so overlapping runs each hold the "running" state until
  /// the last one lands. An open report view watches this to show a loading
  /// state (a spinning Re-run control + an "Updating…" banner) while a run is
  /// in progress, so the user sees it IS running rather than a silently-stale
  /// report (founder 2026-10-29: "doesn't look like it's running").
  final Map<String, int> _running = {};

  /// How many times a report of [reportType] has completed. 0 before the
  /// first completion this session.
  int revisionFor(String reportType) => _revisions[reportType] ?? 0;

  /// Whether a background run of [reportType] is in progress right now.
  bool isRunning(String reportType) => (_running[reportType] ?? 0) > 0;

  /// Signal that a background run of [reportType] has STARTED. Flips the type
  /// to "running" and notifies listeners.
  void started(String reportType) {
    _running[reportType] = (_running[reportType] ?? 0) + 1;
    notifyListeners();
  }

  /// Signal that a background run of [reportType] has STOPPED (succeeded or
  /// failed). Clears the "running" state when the last in-flight run lands.
  /// Does NOT bump the revision — success additionally calls [completed] so a
  /// listener refetches; a failure only clears the spinner.
  void stopped(String reportType) {
    final n = (_running[reportType] ?? 0) - 1;
    _running[reportType] = n > 0 ? n : 0;
    notifyListeners();
  }

  /// Signal that a [reportType] report finished regenerating. Bumps its
  /// revision and notifies listeners.
  void completed(String reportType) {
    _revisions[reportType] = (_revisions[reportType] ?? 0) + 1;
    notifyListeners();
  }
}

/// The report types the Story page renders through [LivingReportView] — the
/// owner's private story, Ayma's notes, and the public view.
const _storyReportTypes = ['story_private', 'story_ai_notes', 'story_public'];

/// Persistent (past-tense) labels of the main chat/voice story-edit tools
/// `edit_story_entry` / `remove_story_entry` (see `functions/bootstrap/
/// tool_labels.py` `TOOL_LABELS`). When a finished turn reports one of these,
/// the user's story changed out from under any open Story page.
const _storyEditToolLabels = {
  'Updated your story',
  'Removed that from your story',
};

/// Called at the chat/voice tool-completion seam ([TranscriptStore]) with the
/// finished turn's tool labels. When Ayma edited the story this turn, bump the
/// Story report types so an open Story page live-refreshes instead of showing
/// stale text until the user reopens it (founder fast-follow 2026-10-28).
void signalStoryEditFromTools(Iterable<String> toolLabels) {
  if (!toolLabels.any(_storyEditToolLabels.contains)) return;
  for (final t in _storyReportTypes) {
    ReportEvents.instance.completed(t);
  }
}
