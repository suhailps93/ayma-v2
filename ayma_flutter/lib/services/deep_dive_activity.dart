import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// App-wide record of which web-research reports are being re-searched
/// server-side. A forced deep dive is a background job that outlives the
/// screen that started it and overwrites the same report, so this singleton
/// owns the poll: the report screen can show a spinner until the report's
/// `createdAt` changes, even if the user leaves and comes back.
class DeepDiveActivity {
  DeepDiveActivity._();
  static final DeepDiveActivity instance = DeepDiveActivity._();

  /// Report ids with a re-search in flight. Rebuilt (not mutated) on change.
  final ValueNotifier<Set<String>> searching = ValueNotifier(const {});

  bool isSearching(String reportId) => searching.value.contains(reportId);

  /// Mark [reportId] as searching and poll `GET /deep-dive-report/{id}` until
  /// its `createdAt` differs from [previousCreatedAt], then clear it. A second
  /// call for the same id is a no-op while one is live.
  Future<void> start(
    String reportId, {
    required String? previousCreatedAt,
    required ApiClient api,
    Duration interval = const Duration(seconds: 4),
    int maxPolls = 60,
  }) async {
    if (reportId.isEmpty || isSearching(reportId)) return;
    searching.value = {...searching.value, reportId};
    try {
      for (var i = 0; i < maxPolls; i++) {
        await Future<void>.delayed(interval);
        try {
          final r = await api.deepDiveReport(reportId);
          if (r.createdAt != previousCreatedAt) return;
        } catch (_) {
          // transient — keep polling
        }
      }
    } finally {
      searching.value = searching.value.where((id) => id != reportId).toSet();
    }
  }
}
