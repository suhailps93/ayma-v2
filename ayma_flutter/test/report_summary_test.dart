// Unit tests for ReportSummary.fromTree — the distillation behind every
// PRE-OPEN report card (chat card / graph node / list row). Proves the summary:
//  - pulls title/date/headline score/top findings from the report NODE tree;
//  - degrades cleanly on missing / partial / odd-shaped nodes (never throws);
//  - only ever sees the nodes the tree carries, so a viewer-filtered (shared /
//    public) tree can't aggregate a private node into the card (founder P0).
// Unified visual report framework, founder Nov 17.
import 'package:ayma_flutter/models/report_summary.dart';
import 'package:ayma_flutter/models/story_node.dart';
import 'package:flutter_test/flutter_test.dart';

GraphTree _tree(List<Map<String, dynamic>> nodes,
        {String title = '', Map<String, dynamic> meta = const {}}) =>
    GraphTree.fromMap({
      'surface': 'report',
      'title': title,
      'meta': meta,
      'sections': [
        {'page_type': 's', 'title': 'Section', 'order': 0, 'nodes': nodes},
      ],
    });

Map<String, dynamic> _stat(String id, String label, num? value,
        {String text = '', String basis = ''}) =>
    {
      'id': id,
      'section': 's',
      'label': label,
      'text': label,
      'answer_type': 'stat',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      if (value != null) 'stat_value': value,
      'stat_text': text,
      'stat_basis': basis,
      if (value != null)
        'visual': {
          'type': 'bar_meter',
          'params': {'value': value, 'min': 0, 'max': value > 10 ? 100 : 10},
          'v': 1,
        },
    };

Map<String, dynamic> _text(String id, String text,
        {String visibility = 'public'}) =>
    {
      'id': id,
      'section': 's',
      'label': '',
      'text': text,
      'gist': text,
      'answer_type': 'text',
      'level': 1,
      'visibility': visibility,
      'subtree_visibility': visibility,
    };

void main() {
  test('pulls title + date from the tree', () {
    final s = ReportSummary.fromTree(
      _tree([_text('n1', 'Climbs on weekends')],
          title: 'Match report', meta: {'created_at': '2026-11-17'}),
    );
    expect(s.title, 'Match report');
    expect(s.date, '2026-11-17');
  });

  test('falls back to the given title when the tree carries none', () {
    final s = ReportSummary.fromTree(_tree([_text('n1', 'Hi')]),
        fallbackTitle: 'Appearance report');
    expect(s.title, 'Appearance report');
  });

  test('numeric headline score wins over a confidence band', () {
    final s = ReportSummary.fromTree(_tree([
      _stat('c', 'Confidence', null, text: 'Low'),
      _stat('score', 'Match score', 72),
    ]));
    expect(s.scoreValue, 72);
    expect(s.scoreMax, 100);
    expect(s.scoreLabel, 'Match score');
    // The band is dropped once a numeric score is present.
    expect(s.scoreText, '');
    expect(s.hasScore, isTrue);
  });

  test('a non-numeric confidence stat renders as a band when no number exists',
      () {
    final s = ReportSummary.fromTree(
        _tree([_stat('c', 'Confidence', null, text: 'High')]));
    expect(s.scoreValue, isNull);
    expect(s.scoreText, 'High');
    expect(s.hasScore, isTrue);
  });

  test('collects the top finding gists, capped at three', () {
    final s = ReportSummary.fromTree(_tree([
      _text('n1', 'Warm and curious'),
      _text('n2', 'Loves the outdoors'),
      _text('n3', 'Strong values'),
      _text('n4', 'A fourth finding'),
    ]));
    expect(s.findings.length, 3);
    expect(s.findings.first, 'Warm and curious');
  });

  test('card nodes contribute their title as a finding', () {
    final s = ReportSummary.fromTree(_tree([
      {
        'id': 'card',
        'section': 's',
        'label': '',
        'text': '',
        'answer_type': 'text',
        'level': 1,
        'visibility': 'public',
        'subtree_visibility': 'public',
        'visual': {
          'type': 'card',
          'params': {'title': 'Shared sense of humour', 'body': 'Details'},
          'v': 1,
        },
      }
    ]));
    expect(s.findings.first, 'Shared sense of humour');
  });

  group('never breaks on malformed / partial trees', () {
    test('an empty tree yields an empty summary, not a throw', () {
      final s = ReportSummary.fromTree(_tree(const []));
      expect(s.isEmpty, isTrue);
      expect(s.hasScore, isFalse);
      expect(s.findings, isEmpty);
    });

    test('a bar node with no value contributes no score', () {
      final s = ReportSummary.fromTree(_tree([
        {
          'id': 'bad',
          'section': 's',
          'label': 'Broken bar',
          'text': 'Broken bar',
          'answer_type': 'text',
          'level': 1,
          'visibility': 'public',
          'subtree_visibility': 'public',
          'visual': {'type': 'gauge', 'params': {}, 'v': 1},
        }
      ]));
      expect(s.scoreValue, isNull);
      // It still reads as a plain finding (its gist), never a crash.
      expect(s.findings, contains('Broken bar'));
    });

    test('an unknown visual type degrades to a gist finding', () {
      final s = ReportSummary.fromTree(_tree([
        {
          'id': 'u',
          'section': 's',
          'label': '',
          'text': 'Mystery node',
          'gist': 'Mystery node',
          'answer_type': 'text',
          'level': 1,
          'visibility': 'public',
          'subtree_visibility': 'public',
          'visual': {'type': 'totally_unknown', 'params': {}, 'v': 9},
        }
      ]));
      expect(s.findings, contains('Mystery node'));
    });
  });

  test('privacy: a viewer-filtered tree cannot aggregate a hidden node', () {
    // The report tree a shared/public viewer receives carries ONLY the nodes
    // report_tree.py let through; a private finding simply is not in it. The
    // summary therefore cannot surface it — proven by building from a tree that
    // excludes it (the server contract) vs one that includes it.
    final filtered =
        ReportSummary.fromTree(_tree([_text('pub', 'Public strength')]));
    final unfiltered = ReportSummary.fromTree(_tree([
      _text('pub', 'Public strength'),
      _text('priv', 'Secret private note'),
    ]));
    expect(filtered.findings, ['Public strength']);
    expect(filtered.findings, isNot(contains('Secret private note')));
    expect(unfiltered.findings, contains('Secret private note'));
  });
}
