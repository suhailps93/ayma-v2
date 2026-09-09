import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// App-wide record of which match reports are currently recalculating
/// server-side. The rubric job outlives the screen that kicked it off, so this
/// singleton owns the poll: any screen showing a "% match" chip can listen and
/// show a spinner until a fresh score lands, whether or not the user is still
/// on the report screen.
///
/// Keyed by the same id the match report is opened with (the pair's
/// `threadId` / `matchId`).
class MatchActivity {
  MatchActivity._();
  static final MatchActivity instance = MatchActivity._();

  /// The set of match ids with a recalculation in flight. Rebuilt (not mutated)
  /// on every change so `ValueListenableBuilder` repaints.
  final ValueNotifier<Set<String>> recalculating = ValueNotifier(const {});

  bool isRecalculating(String? matchId) =>
      matchId != null && recalculating.value.contains(matchId);

  /// Mark [matchId] as recalculating and poll `GET /match/{id}` until the score
  /// changes from [previousScore] (or first appears), then clear it. Safe to
  /// call again for the same id — a second call is a no-op while one is live.
  Future<void> start(
    String matchId, {
    double? previousScore,
    ApiClient? api,
    Duration interval = const Duration(seconds: 3),
    int maxPolls = 40,
  }) async {
    if (matchId.isEmpty || recalculating.value.contains(matchId)) return;
    recalculating.value = {...recalculating.value, matchId};
    final client = api ?? ApiClient();
    try {
      for (var i = 0; i < maxPolls; i++) {
        await Future<void>.delayed(interval);
        try {
          final r = await client.matchReport(matchId);
          if (r != null && r.score != null && r.score != previousScore) return;
        } catch (_) {
          // transient — keep polling
        }
      }
    } finally {
      recalculating.value =
          recalculating.value.where((id) => id != matchId).toSet();
    }
  }
}
