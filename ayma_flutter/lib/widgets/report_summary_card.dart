/// The pre-open SUMMARY card for a node-backed report (unified visual report
/// framework, founder Nov 17). Every surface that points AT a report before it
/// is opened — the chat report card, a graph node, a "view report" list row —
/// shows this: the report's title, date, headline score and top finding, all
/// distilled from the SAME report node tree the opened page renders
/// ([ApiClient.reportTree] → [ReportSummary.fromTree]). No raw JSON, no separate
/// store, and — because the tree is already viewer-visibility-filtered by
/// `report_tree.py` — a shared/public report's card can only ever summarise the
/// nodes the viewer may see.
///
/// Never-breaking: while the tree loads it shows a compact labelled row; if the
/// fetch fails or the summary is empty it falls back to that same plain labelled
/// row (icon + fallback label + chevron) — never an error dump, never a map,
/// never a blank.
library;

import 'package:flutter/material.dart';

import '../models/report_summary.dart';
import '../models/story_node.dart';
import '../services/api_client.dart';
import '../theme.dart';
import '../util/cold_start_retry.dart';
import 'ayma_photo.dart';

class ReportSummaryCard extends StatefulWidget {
  const ReportSummaryCard({
    super.key,
    required this.reportType,
    required this.reportId,
    required this.icon,
    required this.fallbackLabel,
    required this.onTap,
    this.subjectImage = '',
    this.api,
    this.loader,
  });

  /// The report tree to summarise (`appearance` / `deep_dive` / `match` / …).
  final String reportType;
  final String reportId;

  /// The icon shown when there's no subject photo, and in the fallback row.
  final IconData icon;

  /// The label shown while loading and if the summary can't be built — e.g.
  /// 'Appearance report', 'Web research report', 'Match report'.
  final String fallbackLabel;

  final VoidCallback onTap;
  final String subjectImage;
  final ApiClient? api;

  /// Overrides the tree fetch (tests / a token-scoped shared card). Defaults to
  /// `api.reportTree(reportType, reportId)`.
  final Future<GraphTree> Function()? loader;

  @override
  State<ReportSummaryCard> createState() => _ReportSummaryCardState();
}

class _ReportSummaryCardState extends State<ReportSummaryCard> {
  late final ApiClient _api = widget.api ?? ApiClient();
  ReportSummary? _summary;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tree = await withColdStartRetry(
        () async => widget.loader != null
            ? await widget.loader!()
            : await _api.reportTree(widget.reportType, widget.reportId),
      );
      if (!mounted) return;
      setState(() {
        _summary =
            ReportSummary.fromTree(tree, fallbackTitle: widget.fallbackLabel);
        _done = true;
      });
    } catch (_) {
      // Any failure (404, offline, cold-start exhausted) → the plain labelled
      // fallback row. Never surfaces the error or a map.
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final s = _summary;
    final title = (s != null && s.title.isNotEmpty) ? s.title : widget.fallbackLabel;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        key: Key('report_summary_card_${widget.reportType}_${widget.reportId}'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ac.bgElev,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: ac.lineSoft, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: widget.subjectImage.isNotEmpty
                        ? AymaPhoto(
                            url: widget.subjectImage,
                            displayWidth: 34,
                            error: Icon(widget.icon, size: 16, color: ac.fgMute),
                          )
                        : DecoratedBox(
                            decoration: BoxDecoration(color: ac.accentFaint),
                            child: Icon(widget.icon, size: 16, color: ac.accent),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AymaType.sans(
                            size: 13.5, weight: FontWeight.w600, color: ac.fg),
                      ),
                      if (s != null && s.date.isNotEmpty)
                        Text(
                          s.date,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AymaType.sans(size: 11, color: ac.fgMute),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (s != null && s.hasScore) _ScorePill(summary: s),
                // A chevron so it always reads as "opens the full report".
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.chevron_right, size: 16, color: ac.fgMute),
                ),
              ],
            ),
            // Top finding headline (gist-first), if any. Capped so the card can
            // never grow unbounded or overflow at phone width.
            if (s != null && s.findings.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                s.findings.first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AymaType.sans(size: 12.5, height: 1.3, color: ac.fgMute),
              ),
            ],
            // While loading we show just the title row above; no spinner noise.
            if (!_done)
              const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

/// A compact banded score pill — the numeric score on its 0..10 / 0..100 scale,
/// or a confidence band word.
class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.summary});

  final ReportSummary summary;

  @override
  Widget build(BuildContext context) {
    final ac = context.ac;
    final v = summary.scoreValue;
    final String text;
    Color color;
    if (v != null) {
      final frac = (v / summary.scoreMax).clamp(0.0, 1.0);
      color = frac >= 0.7
          ? ac.success
          : frac >= 0.4
              ? ac.warning
              : ac.error;
      final shown = v == v.roundToDouble()
          ? v.toStringAsFixed(0)
          : v.toStringAsFixed(1);
      text = summary.scoreMax == 100 ? '$shown%' : shown;
    } else {
      final band = summary.scoreText.toLowerCase();
      color = band == 'high'
          ? ac.success
          : band == 'medium'
              ? ac.warning
              : band == 'low'
                  ? ac.error
                  : ac.fgDim;
      text = summary.scoreText;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: AymaType.mono(size: 11, color: color)),
    );
  }
}
