import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/living_report_view.dart';

/// The caller's unified Appearance report — structured attributes plus an
/// honest face analysis and an honest physique analysis. Re-opened from an
/// `[appearance:<id>]` chat marker, the chat report card, or the Skills
/// screen's "View my report" link.
///
/// Body is the ONE shared [LivingReportView] renderer (§ generic reports) —
/// every finding is tappable at the block/section/report tier the same way
/// every other report type is, via the shared Ask-Ayma chat mechanism.
/// `report_hub.resolve_owner` treats "appearance"'s `{report_id}` as the
/// subject's own uid (there is only ever one current Appearance report per
/// user) — [reportId] (an older, possibly-stale marker id from before that
/// convergence) is kept only as a fallback for the rare case the caller
/// can't be resolved to a signed-in uid.
class AppearanceReportScreen extends StatelessWidget {
  const AppearanceReportScreen({
    super.key,
    required this.reportId,
    this.apiClient,
    this.myUid,
  });

  static const path = '/appearance/:id';

  final String reportId;
  final ApiClient? apiClient;

  /// Injectable for tests; production reads the signed-in Firebase uid.
  final String? myUid;

  String? _liveUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      // No Firebase app configured (shouldn't happen in the real app, but
      // never crash the whole screen over it) — falls through to [reportId].
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolvedMyUid = myUid ?? _liveUid() ?? '';
    final uid = resolvedMyUid.isNotEmpty ? resolvedMyUid : reportId;
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: LivingReportView(
        reportType: 'appearance',
        reportId: uid,
        apiClient: apiClient,
      ),
    );
  }
}
