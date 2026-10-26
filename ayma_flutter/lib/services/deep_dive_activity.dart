import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'chat_inbox.dart';

/// App-wide record of which web-research reports have a search running
/// server-side. A queued deep dive is a background job that outlives the
/// screen that started it, so this singleton owns the poll: the report screen
/// shows its "Searching the web…" state only while the server's
/// `run_status` for that report is `running`, even if the user leaves and
/// comes back.
///
/// The poll ends on the server's word (`done` / `failed` / no run), or after
/// [timeout]; a run that ends in anything but `done` lands in [failed] so
/// the screen can offer "Try again" instead of a spinner.
class DeepDiveActivity {
  DeepDiveActivity._();
  static final DeepDiveActivity instance = DeepDiveActivity._();

  /// Matches the server's stale-run cutoff (`deep_dive.RUN_STALE_MINUTES`).
  static const timeout = Duration(minutes: 10);

  /// Report ids with a search in flight. Rebuilt (not mutated) on change.
  final ValueNotifier<Set<String>> searching = ValueNotifier(const {});

  /// Report ids whose last search didn't finish. Rebuilt on change.
  final ValueNotifier<Set<String>> failed = ValueNotifier(const {});

  bool isSearching(String reportId) => searching.value.contains(reportId);

  bool hasFailed(String reportId) => failed.value.contains(reportId);

  /// Mark [reportId] as searching and poll `GET /deep-dive-report/{id}` until
  /// its `run_status` is no longer `running` (or [timeout] passes), then
  /// clear it. A second call for the same id is a no-op while one is live.
  /// A 404 (a first search with no report yet) keeps polling.
  Future<void> start(
    String reportId, {
    required ApiClient api,
    Duration interval = const Duration(seconds: 4),
  }) async {
    if (reportId.isEmpty || isSearching(reportId)) return;
    searching.value = {...searching.value, reportId};
    _setFailed(reportId, false);
    // Bounded by both a poll count and the wall clock: timers don't run
    // while Android freezes the app, so the count alone could outlive the
    // server's cutoff by hours.
    final deadline = DateTime.now().add(timeout);
    final maxPolls = timeout.inMilliseconds ~/ interval.inMilliseconds;
    var succeeded = false;
    try {
      for (var i = 0;
          i < maxPolls && DateTime.now().isBefore(deadline);
          i++) {
        await Future<void>.delayed(interval);
        final DeepDiveReport r;
        try {
          r = await api.deepDiveReport(reportId);
        } catch (_) {
          continue;
        }
        if (r.runStatus == 'running') continue;
        succeeded = r.runStatus != 'failed';
        if (succeeded) ChatInbox.instance.resultLanded();
        return;
      }
    } finally {
      searching.value = searching.value.where((id) => id != reportId).toSet();
      _setFailed(reportId, !succeeded);
    }
  }

  void _setFailed(String reportId, bool value) {
    if (hasFailed(reportId) == value) return;
    failed.value = value
        ? {...failed.value, reportId}
        : failed.value.where((id) => id != reportId).toSet();
  }
}
