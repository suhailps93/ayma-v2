import 'package:flutter/material.dart';

import '../models/story_node.dart';
import '../services/api_client.dart';
import '../services/auto_retry.dart';
import '../theme.dart';
import 'ayma_wing_loader.dart';
import 'face_report_view.dart' show ScoredReadView, resolvePhotoUrl;

/// A stored body report as its display sections plus a resolved URL for the
/// photo it was run on.
class StoredBodyReport {
  const StoredBodyReport({this.sections = const [], this.imageUrl});
  final List<GraphTreeSection> sections;
  final String? imageUrl;
}

/// Fetch a stored body report by id and resolve its photo URL.
Future<StoredBodyReport> fetchStoredBodyReport(
  String reportId, {
  ApiClient? api,
}) async {
  final r = await (api ?? ApiClient()).skillReport('body', reportId);
  return StoredBodyReport(
    sections: r.sections,
    imageUrl: await resolvePhotoUrl(r.imagePath),
  );
}

/// Open a report already stored server-side in a bottom sheet — from the
/// Skills-screen history or a chat `[body_report:<id>]` marker. Display-only.
Future<void> openStoredBodyReport(
  BuildContext context, {
  ApiClient? api,
  required String reportId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _StoredBodyReportSheet(
      api: api ?? ApiClient(),
      reportId: reportId,
    ),
  );
}

class _StoredBodyReportSheet extends StatefulWidget {
  const _StoredBodyReportSheet({required this.api, required this.reportId});

  final ApiClient api;
  final String reportId;

  @override
  State<_StoredBodyReportSheet> createState() => _StoredBodyReportSheetState();
}

class _StoredBodyReportSheetState extends State<_StoredBodyReportSheet> {
  // Auto-retry a transient load failure before showing the error (founder
  // 2026-11-01). The GET is idempotent; worst case stays bounded.
  late final Future<StoredBodyReport> _future = withAutoRetry(
      () => fetchStoredBodyReport(widget.reportId, api: widget.api));

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: FutureBuilder<StoredBodyReport>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              // GET /skills/report/body/{id} (+ photo URL) still in flight.
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: AymaWingLoader(lines: AymaLoaderLines.bodyReport),
                ),
              );
            }
            final sections = snap.data?.sections ?? const [];
            if (snap.hasError || sections.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  "Couldn't load that report.",
                  textAlign: TextAlign.center,
                  style: AymaType.sans(size: 14, color: ac.fgMute),
                ),
              );
            }
            return ListView(
              controller: controller,
              children: [
                BodyReportView(
                  sections: sections,
                  imageUrl: snap.data?.imageUrl,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A stored Body report — the score as text ("Body 6.4/10" with its band),
/// every element labelled, "What to do next" last — through the shared
/// [ScoredReadView] (the same section renderer as the Appearance screen).
class BodyReportView extends StatelessWidget {
  const BodyReportView({
    super.key,
    required this.sections,
    this.imageUrl,
    this.api,
  });

  final List<GraphTreeSection> sections;

  /// The analysed photo, embedded at the top of the card.
  final String? imageUrl;

  /// Injectable for tests; the "Add this to my story" action uses it.
  final ApiClient? api;

  @override
  Widget build(BuildContext context) => ScoredReadView(
        title: 'PHYSIQUE REPORT',
        sections: sections,
        imageUrl: imageUrl,
        storyPageType: 'body_analysis',
        api: api,
      );
}
