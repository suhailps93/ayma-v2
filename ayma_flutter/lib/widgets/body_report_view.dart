import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../theme.dart';
import 'face_report_view.dart' show AddToStoryButton;

/// Runs `POST /body-report` and shows the result in a bottom sheet, mirroring
/// [showFaceReportSheet]. [attachmentPath] (a chat upload under
/// `uploads/{you}/`) takes precedence; otherwise [targetUid]'s primary profile
/// photo (empty = your own). Ayma's one-line pointer is also dropped into the
/// chat transcript server-side.
Future<void> showBodyReportSheet(
  BuildContext context, {
  ApiClient? api,
  String attachmentPath = '',
  String targetUid = '',
  String subjectLabel = 'you',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _BodyReportSheet(
      api: api ?? ApiClient(),
      attachmentPath: attachmentPath,
      targetUid: targetUid,
      subjectLabel: subjectLabel,
    ),
  );
}

/// Opens the sheet against a report already stored server-side — used when a
/// chat turn ends with a `[body_report:<id>]` marker. Fetches via
/// [ApiClient.skillReport] then renders [BodyReportView].
Future<void> openStoredBodyReport(
  BuildContext context, {
  ApiClient? api,
  required String reportId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _BodyReportSheet(
      api: api ?? ApiClient(),
      attachmentPath: '',
      targetUid: '',
      subjectLabel: 'you',
      storedReportId: reportId,
    ),
  );
}

class _BodyReportSheet extends StatefulWidget {
  const _BodyReportSheet({
    required this.api,
    required this.attachmentPath,
    required this.targetUid,
    required this.subjectLabel,
    this.storedReportId = '',
  });

  final ApiClient api;
  final String attachmentPath;
  final String targetUid;
  final String subjectLabel;

  /// When set, fetch this stored report instead of running a fresh analysis.
  final String storedReportId;

  @override
  State<_BodyReportSheet> createState() => _BodyReportSheetState();
}

class _BodyReportSheetState extends State<_BodyReportSheet> {
  late Future<BodyReportResult> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.storedReportId.isNotEmpty
        ? widget.api.skillReport('body', widget.storedReportId).then(
              (r) => BodyReportResult(
                usageCapped: false,
                reportId: widget.storedReportId,
                report: r.report.isEmpty ? null : BodyReport.fromMap(r.report),
              ),
            )
        : widget.api.bodyReport(
            attachmentPath: widget.attachmentPath,
            targetUid: widget.targetUid,
          );
  }

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
        child: FutureBuilder<BodyReportResult>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return _busy(ac, 'Analysing the photo…');
            }
            if (snap.hasError) {
              return _msg(ac,
                  "Couldn't analyse that photo. Try again in a bit.");
            }
            final r = snap.data!;
            if (r.usageCapped) {
              return _msg(ac,
                  'Out of credits — reload on your profile to run a body report.');
            }
            final report = r.report;
            if (report == null || !report.usable) {
              return _msg(
                ac,
                'I need a clearer, full-length photo in fitted clothing to do '
                'this properly.',
              );
            }
            return ListView(
              controller: controller,
              children: [BodyReportView(report: report)],
            );
          },
        ),
      ),
    );
  }

  Widget _busy(AymaTokens ac, String label) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label, style: AymaType.sans(size: 13, color: ac.fgMute)),
          const SizedBox(height: 8),
          Text('This takes a few seconds.',
              style: AymaType.sans(size: 11, soft: true, color: ac.fgMute)),
          const SizedBox(height: 24),
        ],
      );

  Widget _msg(AymaTokens ac, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(text,
            textAlign: TextAlign.center,
            style: AymaType.sans(size: 14, color: ac.fgMute)),
      );
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
  const BodyReportView({super.key, required this.report, this.api});

  final BodyReport report;

  /// Injectable for tests; the "Add this to my story" action uses it.
  final ApiClient? api;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('PHYSIQUE REPORT',
            style: AymaType.mono(size: 10, color: ac.fgMute)),
        const SizedBox(height: 12),
        _ScoreHeader(
          score: report.overallScore,
          verdict: report.verdict,
          verdictNote: report.verdictNote,
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
          _ScoreBar(value: score),
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

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final frac = (value / 10).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        children: [
          Container(height: 5, color: ac.lineSoft),
          FractionallySizedBox(
            widthFactor: frac,
            child: Container(height: 5, color: ac.accent),
          ),
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
