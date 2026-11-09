import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/share_kit.dart';
import 'ayma_share_sheet.dart';

/// The AppBar Share action the web-research and Match report screens
/// carry. It is a thin adapter onto the ONE reusable share kit
/// (`share_kit.dart` + `ayma_share_sheet.dart`): the button builds the
/// report's [ShareTarget] from the EXACT report this screen opened —
/// [reportType] / [reportId] are the same pair the screen's
/// `LivingReportView` reads, never re-resolved by pair or person — and
/// the kit sheet offers the same two options as every other page:
/// "Send to Ayma" and "Send externally" (the existing `/s/` snapshot).
///
/// The old bespoke sheet (with its own "Share to Ayma" draft-text path
/// and a "Send to a user" DM picker) was removed in the migration; the
/// DM thread still renders report shares it already holds.
class ShareReportButton extends StatelessWidget {
  const ShareReportButton({
    super.key,
    required this.reportType,
    required this.reportId,
    this.subjectUid = '',
    this.subjectName = '',
    this.subjectPhoto = '',
    this.apiClient,
  });

  /// `deep_dive` or `match` — the shareable report types (`share.py`).
  final String reportType;

  /// The exact report id this screen opened.
  final String reportId;

  /// The person the report is about (the dive's subject / the match's
  /// other side), for the Ayma hand-off and the card.
  final String subjectUid;
  final String subjectName;
  final String subjectPhoto;

  final ApiClient? apiClient;

  ShareTarget get _target => reportType == 'match'
      ? ShareTargets.matchReport(
          matchId: reportId,
          otherUid: subjectUid,
          otherName: subjectName,
          otherPhoto: subjectPhoto,
        )
      : ShareTargets.webResearch(
          reportId: reportId,
          subjectUid: subjectUid,
          subjectName: subjectName,
          subjectImage: subjectPhoto,
        );

  @override
  Widget build(BuildContext context) => AymaShareButton(
        target: _target,
        share: AymaShare(api: apiClient),
      );
}
