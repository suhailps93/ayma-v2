/// A human SUMMARY of a report, distilled from its node tree (unified visual
/// report framework, founder Nov 17). This is what every PRE-OPEN surface shows
/// — the chat report card, a graph node that points at a report, a "view report"
/// list row — in place of the raw JSON that used to leak there. Same tree the
/// opened report page renders (`GraphTree`), no separate store, so it is already
/// viewer-visibility-filtered by `report_tree.py`: a shared/public report's
/// summary can only ever aggregate the nodes the viewer may see.
///
/// Purely derived and total: [fromTree] never throws on a missing, partial or
/// odd-shaped tree — a field it can't fill stays empty and the card degrades,
/// never crashes and never prints a map.
library;

import 'story_node.dart';

class ReportSummary {
  const ReportSummary({
    required this.title,
    required this.date,
    required this.scoreLabel,
    required this.scoreValue,
    required this.scoreMax,
    required this.scoreText,
    required this.findings,
  });

  /// The report title (the tree's own title, else a caller fallback).
  final String title;

  /// A human date line, or '' when the tree carries none (never invented).
  final String date;

  /// The headline score's label ("Match score", "Face"), or ''.
  final String scoreLabel;

  /// The headline numeric score, or null when the report has no numeric score.
  final double? scoreValue;

  /// The scale the score is on (10 or 100), for a "/ max" read.
  final double scoreMax;

  /// The headline score's raw text (a confidence band like "Low", or the number
  /// as text) when there is no numeric value — else ''.
  final String scoreText;

  /// The top finding headlines (gist-first), at most [_maxFindings].
  final List<String> findings;

  bool get hasScore => scoreValue != null || scoreText.isNotEmpty;
  bool get isEmpty =>
      title.isEmpty && !hasScore && findings.isEmpty;

  static const int _maxFindings = 3;

  /// Distil a report tree into a summary. Walks every section's nodes (and their
  /// children) in order; the FIRST numeric score node is the headline, and the
  /// first few finding/card/text gists are the highlights. Degrades cleanly on
  /// any malformed node.
  factory ReportSummary.fromTree(GraphTree tree, {String fallbackTitle = ''}) {
    String scoreLabel = '';
    double? scoreValue;
    double scoreMax = 10;
    String scoreText = '';
    final findings = <String>[];

    void visit(StoryNode n) {
      // Headline score: the first numeric stat / gauge / bar node wins.
      if (scoreValue == null) {
        final num = _numericScore(n);
        if (num != null) {
          scoreValue = num;
          scoreMax = num > 10 ? 100 : 10;
          scoreLabel = _scoreLabelOf(n);
        } else if (scoreText.isEmpty && n.isStat && n.statText.isNotEmpty) {
          // A non-numeric confidence stat ("Low") — kept only if no numeric
          // score shows up later; a numeric one always wins (set above).
          scoreText = n.statText;
          scoreLabel = _scoreLabelOf(n);
        }
      }
      // Findings: card bodies/titles and plain narrative gists, not fields,
      // images, links or the score itself.
      if (findings.length < _maxFindings) {
        final f = _findingOf(n);
        if (f.isNotEmpty) findings.add(f);
      }
      for (final c in n.children) {
        visit(c);
      }
    }

    for (final s in tree.sections) {
      for (final n in s.nodes) {
        visit(n);
      }
    }

    // A numeric score always supersedes a stray confidence band captured first.
    if (scoreValue != null) scoreText = '';

    final title = tree.title.trim().isNotEmpty ? tree.title.trim() : fallbackTitle;
    return ReportSummary(
      title: title,
      date: tree.reportDate,
      scoreLabel: scoreLabel,
      scoreValue: scoreValue,
      scoreMax: scoreMax,
      scoreText: scoreText,
      findings: findings,
    );
  }

  /// The numeric headline value of a node, from a `stat` node or a gauge/bar
  /// visual's `params.value`. Null when the node carries no number.
  static double? _numericScore(StoryNode n) {
    if (n.isStat && n.statValue != null) return n.statValue;
    final t = n.visualType;
    if (t == NodeVisualType.gauge || t == NodeVisualType.barMeter) {
      final v = n.visual?.params['value'];
      if (v is num) return v.toDouble();
    }
    return null;
  }

  static String _scoreLabelOf(StoryNode n) {
    if (n.label.trim().isNotEmpty) return n.label.trim();
    final l = n.visual?.params['label'];
    if (l is String && l.trim().isNotEmpty) return l.trim();
    return n.displayGist;
  }

  /// A finding headline for a node, or '' when the node isn't a finding (an
  /// image, link, standard field, stat, or an empty node contributes none).
  static String _findingOf(StoryNode n) {
    if (n.isImage || n.isLink || n.isCandidate || n.isStat) return '';
    if (n.standard) return '';
    if (n.visualType == NodeVisualType.card) {
      final p = n.visual?.params ?? const {};
      final title = (p['title'] as Object?)?.toString().trim() ?? '';
      final body = (p['body'] as Object?)?.toString().trim() ?? '';
      if (title.isNotEmpty) return title;
      if (body.isNotEmpty) return body;
    }
    final g = n.displayGist.trim();
    return g;
  }
}
