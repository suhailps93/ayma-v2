// Screenshot evidence: a report rendered through the ONE unified visual report
// framework (GraphTreeView on the report surface) from founder-shaped nodes —
// a score gauge, interest chips, a finding card, a small comparison table and
// attribute fields, each drawn by the node's own palette visual, assembled as
// designed section cards. Run with `flutter test --update-goldens` to (re)write
// test/golden/goldens/unified_report.png.
import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/graph_tree_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.tree) : super(auth: MockFirebaseAuth(signedIn: true));
  final GraphTree tree;
  @override
  Future<GraphTree> reportTree(String t, String i) async => tree;
}

Map<String, dynamic> _n(Map<String, dynamic> o) => {
      'section': 's',
      'label': '',
      'text': '',
      'answer_type': 'text',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      ...o,
    };

GraphTree _founderReport() => GraphTree.fromMap({
      'surface': 'report',
      'title': 'Match report',
      'meta': {'created_at': '17 Nov 2026', 'viewer_can_edit': false},
      'sections': [
        {
          'page_type': 'overview',
          'title': 'Overview',
          'order': 0,
          'nodes': [
            _n({
              'id': 'score',
              'label': 'Match score',
              'text': 'Match score',
              'answer_type': 'stat',
              'stat_value': 78,
              'stat_basis': 'Strong across values and lifestyle',
              'visual': {
                'type': 'gauge',
                'params': {'value': 78, 'min': 0, 'max': 100, 'label': 'Match score'},
                'v': 1,
              },
            }),
            _n({
              'id': 'card1',
              'visual': {
                'type': 'card',
                'params': {
                  'title': 'You both value depth over small talk',
                  'body': 'Each of you named honest, unhurried conversation as what you look for.',
                },
                'v': 1,
              },
            }),
          ],
        },
        {
          'page_type': 'shared',
          'title': 'What lines up',
          'order': 1,
          'nodes': [
            _n({
              'id': 'c1',
              'text': 'Hiking',
              'gist': 'Hiking',
              'visual': {'type': 'chip_set', 'params': {'items': ['Hiking', 'Film photography', 'Cooking']}, 'v': 1},
            }),
            _n({
              'id': 'tbl',
              'visual': {
                'type': 'small_table',
                'params': {
                  'columns': ['Dimension', 'You', 'Them'],
                  'rows': [
                    ['Values', 'High', 'High'],
                    ['Lifestyle', 'Active', 'Active'],
                    ['Social', 'Small circle', 'Small circle'],
                  ],
                },
                'v': 1,
              },
            }),
          ],
        },
        {
          'page_type': 'attributes',
          'title': 'At a glance',
          'order': 2,
          'nodes': [
            _n({
              'id': 'a1',
              'standard': true,
              'standard_label': 'Age',
              'label': 'Age',
              'text': '29',
              'gist': '29',
            }),
            _n({
              'id': 'a2',
              'standard': true,
              'standard_label': 'City',
              'label': 'City',
              'text': 'Lisbon',
              'gist': 'Lisbon',
            }),
          ],
        },
      ],
    });

void main() {
  testWidgets('unified report framework renders founder-shaped nodes',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: GraphTreeView(
            surface: NodeVisualiserSurface.report,
            reportType: 'match',
            reportId: 'demo',
            api: _FakeApi(_founderReport()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/unified_report.png'),
    );
  });
}
