import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../widgets/living_report_view.dart';

/// Read-only in-app view of a shared report, opened by the app link
/// `https://justabot.info/s/<token>`. Renders the frozen public snapshot
/// (`GET /s/{token}/data`) through the one shared [LivingReportView]; the
/// snapshot's `viewer_can_edit` is always false, so no correction affordance
/// is offered.
class SharedReportScreen extends StatelessWidget {
  const SharedReportScreen({super.key, required this.token, this.apiClient});

  static const path = '/s/:token';

  final String token;
  final ApiClient? apiClient;

  @override
  Widget build(BuildContext context) {
    final api = apiClient ?? ApiClient();
    return Scaffold(
      appBar: AppBar(title: const Text('Shared report')),
      body: LivingReportView(
        reportType: 'shared',
        reportId: token,
        apiClient: api,
        loader: () => api.sharedReport(token),
        emptyMessage: 'This report is no longer available.',
      ),
    );
  }
}
