import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../widgets/graph_tree_view.dart';
import '../widgets/ayma_back_button.dart';

/// Read-only in-app view of a shared report, opened by the app link
/// `https://justabot.info/s/<token>`. Renders the frozen public snapshot
/// through the ONE shared [GraphTreeView] Node-Visualiser (2o P5), fetched by
/// the token-scoped `GET /s/{token}/tree` — the SAME public, unauthenticated
/// path as `/s/{token}/data`, never the owner-checked `/report/.../tree`. So a
/// token holder who isn't the owner still sees the report, and nobody without
/// the token can; a revoked / unknown token 404s into the "no longer
/// available" empty state.
///
/// The snapshot's `meta.viewer_can_edit` is always false and the view is
/// mounted [isOwner]`: false`, so every node's chat window is read-only — no
/// correction / edit / chat affordance is offered, matching the old
/// LivingReportView body this replaces.
class SharedReportScreen extends StatelessWidget {
  const SharedReportScreen({super.key, required this.token, this.apiClient});

  static const path = '/s/:token';

  final String token;
  final ApiClient? apiClient;

  @override
  Widget build(BuildContext context) {
    final api = apiClient ?? ApiClient();
    return Scaffold(
      appBar: AppBar(
        leading: const AymaBackButton(),
        title: const Text('Shared report')),
      // GraphTreeView returns a non-scrolling Column (mainAxisSize.min), so it
      // drops into this screen's own scroll — the scrolling host the embedded
      // report screens (appearance / deep-dive) provide via their outer lists.
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: GraphTreeView(
          surface: NodeVisualiserSurface.report,
          isOwner: false,
          api: api,
          loader: () => api.sharedReportTree(token),
          emptyMessage: 'This report is no longer available.',
        ),
      ),
    );
  }
}
