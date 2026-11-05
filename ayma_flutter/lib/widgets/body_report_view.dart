import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auto_retry.dart';
import '../theme.dart';
import 'ayma_wing_loader.dart';
import 'face_report_view.dart' show AddToStoryButton, resolvePhotoUrl;
import 'score_bar.dart';

/// A stored body report ([BodyReport]) plus a resolved URL for the photo it was
/// run on.
class StoredBodyReport {
  const StoredBodyReport({this.report, this.imageUrl});
  final BodyReport? report;
  final String? imageUrl;
}

/// Fetch a stored body report by id and resolve its photo URL.
Future<StoredBodyReport> fetchStoredBodyReport(
  String reportId, {
  ApiClient? api,
}) async {
  final r = await (api ?? ApiClient()).skillReport('body', reportId);
  return StoredBodyReport(
    report: r.report.isEmpty ? null : BodyReport.fromMap(r.report),
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
            final report = snap.data?.report;
            if (snap.hasError || report == null) {
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
                BodyReportView(report: report, imageUrl: snap.data?.imageUrl),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The analysed photo shown at the top of a report card.
class _ReportPhoto extends StatelessWidget {
  const _ReportPhoto({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          loadingBuilder: (c, w, p) => p == null
              ? w
              : Container(
                  height: 220,
                  color: ac.bgCard,
                  child: const Center(
                    child: AymaWingLoader(
                      size: 40,
                      lines: AymaLoaderLines.photo,
                    ),
                  ),
                ),
          errorBuilder: (c, e, s) => Container(
            height: 120,
            color: ac.bgCard,
            child: Icon(Icons.broken_image_outlined, color: ac.fgMute),
          ),
        ),
      ),
    );
  }
}

String _humanise(String raw) {
  final parts = raw.split(RegExp(r'[_\s]+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return raw;
  return parts
      .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
      .join(' ');
}

/// A clean card for a [BodyReport] — same treatment as [FaceReportView], with
/// physique-specific feature and quick-fact labels.
class BodyReportView extends StatelessWidget {
  const BodyReportView({
    super.key,
    required this.report,
    this.imageUrl,
    this.api,
    this.onCorrect,
  });

  final BodyReport report;

  /// The analysed photo, embedded at the top of the card.
  final String? imageUrl;

  /// Injectable for tests; the "Add this to my story" action uses it.
  final ApiClient? api;

  /// When given, the score/verdict header becomes tappable — opens the
  /// tap-a-claim conversational correction flow for this section. Other
  /// callers of this widget leave it null and get the plain header as before.
  final VoidCallback? onCorrect;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final scoreHeader = _ScoreHeader(
      score: report.overallScore,
      verdict: report.verdict,
      verdictNote: report.verdictNote,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('PHYSIQUE REPORT',
            style: AymaType.mono(size: 10, color: ac.fgMute)),
        const SizedBox(height: 12),
        if (imageUrl != null) ...[
          _ReportPhoto(url: imageUrl!),
          const SizedBox(height: 16),
        ],
        onCorrect == null
            ? scoreHeader
            : InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onCorrect,
                child: scoreHeader,
              ),
        if (onCorrect != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Tap to correct',
                style: AymaType.mono(size: 9.5, color: ac.fgMute)
                    .copyWith(letterSpacing: 0.8)),
          ),
        if (report.features.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('PHYSIQUE ANALYSIS'),
          const SizedBox(height: 4),
          for (final f in report.features)
            _FeatureRow(
                name: _humanise(f.name), score: f.score, note: f.note),
        ],
        if (report.quickFacts.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('QUICK FACTS'),
          const SizedBox(height: 8),
          _QuickFacts(facts: report.quickFacts),
        ],
        if (report.strengths.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('STRENGTHS'),
          const SizedBox(height: 8),
          for (final s in report.strengths)
            _Bullet(text: s, icon: Icons.check, color: ac.success),
        ],
        if (report.improvements.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('AREAS FOR IMPROVEMENT'),
          const SizedBox(height: 8),
          for (final s in report.improvements)
            _Bullet(text: s, icon: Icons.circle, color: ac.fgMute, dot: true),
        ],
        if (report.recommendations.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionLabel('RECOMMENDATIONS'),
          const SizedBox(height: 8),
          for (final r in report.recommendations)
            _RecoRow(category: _humanise(r.category), text: r.text),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: AddToStoryButton(pageType: 'body_analysis', api: api),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _ScoreHeader extends StatelessWidget {
  const _ScoreHeader({
    required this.score,
    required this.verdict,
    required this.verdictNote,
  });

  final double score;
  final String verdict;
  final String verdictNote;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ac.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ac.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(score.toStringAsFixed(1),
                  style: AymaType.serif(size: 44, color: ac.fg)),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('/10',
                    style: AymaType.sans(size: 15, color: ac.fgMute)),
              ),
              const Spacer(),
              if (verdict.isNotEmpty)
                Flexible(
                  child: Text(
                    verdict,
                    textAlign: TextAlign.right,
                    style: AymaType.sans(
                        size: 14, weight: FontWeight.w600, color: ac.fg),
                  ),
                ),
            ],
          ),
          if (verdictNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(verdictNote,
                style: AymaType.sans(size: 13, color: ac.fgDim, height: 1.4)),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text, style: AymaType.mono(size: 10, color: ac.fgMute)),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow(
      {required this.name, required this.score, required this.note});

  final String name;
  final double score;
  final String note;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(name,
                    style: AymaType.sans(
                        size: 14, weight: FontWeight.w600, color: ac.fg)),
              ),
              Text('${score.toStringAsFixed(1)}/10',
                  style: AymaType.mono(size: 11, color: ac.fgDim)),
            ],
          ),
          const SizedBox(height: 6),
          ScoreBar(value: score, max: 10),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(note,
                style: AymaType.sans(size: 12, color: ac.fgDim, height: 1.4)),
          ],
          const SizedBox(height: 6),
          Divider(height: 1, thickness: 1, color: ac.lineSoft),
        ],
      ),
    );
  }
}

class _QuickFacts extends StatelessWidget {
  const _QuickFacts({required this.facts});
  final Map<String, String> facts;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final entries = facts.entries.toList();
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(_humanise(e.key),
                      style: AymaType.sans(size: 12, color: ac.fgMute)),
                ),
                Expanded(
                  child: Text(e.value,
                      style: AymaType.sans(
                          size: 12, weight: FontWeight.w600, color: ac.fg)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.text,
    required this.icon,
    required this.color,
    this.dot = false,
  });

  final String text;
  final IconData icon;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: dot ? 6 : 2, right: 8),
            child: Icon(icon, size: dot ? 6 : 14, color: color),
          ),
          Expanded(
            child: Text(text,
                style: AymaType.sans(size: 13, color: ac.fg, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _RecoRow extends StatelessWidget {
  const _RecoRow({required this.category, required this.text});
  final String category;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(category.toUpperCase(),
              style: AymaType.mono(size: 9, color: ac.accent)),
          const SizedBox(height: 3),
          Text(text,
              style: AymaType.sans(size: 13, color: ac.fg, height: 1.4)),
        ],
      ),
    );
  }
}
