import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// App-wide source of truth for Ayma's pending public-profile updates
/// (proposals).
///
/// Both the banner on "My public profile" and the "Public profile updates"
/// row in Notification Centre derive their count from this state so they
/// never diverge (e.g. 38 vs 28).
class ProfileProposalsState {
  ProfileProposalsState({this.api});

  static final ProfileProposalsState instance = ProfileProposalsState();

  final ApiClient? api;
  final ValueNotifier<int?> _pendingCount = ValueNotifier<int?>(null);

  ValueListenable<int?> get listenable => _pendingCount;
  int? get currentCount => _pendingCount.value;

  /// Fetch proposals from the server and update the shared count.
  Future<int> refresh([ApiClient? apiOverride]) async {
    try {
      final client = apiOverride ?? api ?? ApiClient();
      final list = await client.profileProposals();
      final count = list.fold<int>(0, (n, p) => n + p.changes.length);
      _pendingCount.value = count;
      return count;
    } catch (_) {
      return _pendingCount.value ?? 0;
    }
  }

  /// Update the in-memory count directly (e.g. after Apply / Dismiss).
  void setCount(int count) {
    _pendingCount.value = count;
  }

  /// Clear in-memory count (e.g. on sign-out / teardown).
  void clear() {
    _pendingCount.value = null;
  }
}
