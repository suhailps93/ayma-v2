import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// In-memory cache of opened match / compatibility reports, keyed by
/// `matchId` (BUG F). Opening a report Ayma has already fetched this session
/// shows instantly from here, so re-opening the same report never replays the
/// heavy loading state — the screen only spins when there is genuinely no
/// cached report yet. A forced recompute (the Recalculate button) overwrites
/// the entry with the fresh report, so the cache never serves a stale score
/// after a manual refresh.
///
/// Session-scoped and deliberately simple: a plain [Map], no eviction, no disk
/// — it holds only the handful of reports a user opens in one run and is
/// dropped on app restart (where a fresh GET is wanted anyway).
class MatchReportCache {
  MatchReportCache._();

  static final MatchReportCache instance = MatchReportCache._();

  final Map<String, MatchReport> _byId = {};

  /// The cached report for [matchId], or null when none has been opened yet.
  MatchReport? get(String matchId) => _byId[matchId];

  /// Stores [report] as the latest known version for its match id.
  void put(MatchReport report) {
    if (report.matchId.isNotEmpty) _byId[report.matchId] = report;
  }

  /// Drops the cached report for [matchId] (used by tests).
  void clear(String matchId) => _byId.remove(matchId);

  /// Empties the whole cache — for test isolation between cases that reuse a
  /// match id.
  @visibleForTesting
  void reset() => _byId.clear();
}
