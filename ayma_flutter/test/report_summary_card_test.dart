// The PRE-OPEN report card (chat card / graph node / list row) renders a human
// SUMMARY from the report node tree — title, date, headline score, top finding
// — and NEVER raw JSON. On a load failure it degrades to a plain labelled row,
// never an error dump. Unified visual report framework, founder Nov 17.
import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/report_summary_card.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi({this.tree, this.status})
      : super(auth: MockFirebaseAuth(signedIn: true));
  final GraphTree? tree;
  final int? status; // when set, reportTree throws ApiException(status)

  @override
  Future<GraphTree> reportTree(String reportType, String reportId) async {
    if (status != null) throw ApiException('nope', statusCode: status);
    return tree!;
  }
}

GraphTree _matchTree() => GraphTree.fromMap({
      'surface': 'report',
      'title': 'Match report',
      'meta': {'created_at': '2026-11-17'},
      'sections': [
        {
          'page_type': 'overview',
          'title': 'Overview',
          'order': 0,
          'nodes': [
            {
              'id': 'score',
              'section': 'o',
              'label': 'Match score',
              'text': 'Match score',
              'answer_type': 'stat',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
              'stat_value': 72,
              'visual': {
                'type': 'bar_meter',
                'params': {'value': 72, 'min': 0, 'max': 100},
                'v': 1,
              },
            },
            {
              'id': 'f',
              'section': 'o',
              'label': '',
              'text': 'You both value depth',
              'gist': 'You both value depth',
              'answer_type': 'text',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
            },
          ],
        }
      ],
    });

Widget _host(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('renders title, date, score and top finding from the node tree',
      (tester) async {
    await tester.pumpWidget(_host(ReportSummaryCard(
      reportType: 'match',
      reportId: 'm1',
      icon: Icons.favorite_border,
      fallbackLabel: 'Match report',
      api: _FakeApi(tree: _matchTree()),
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Match report'), findsOneWidget);
    expect(find.text('2026-11-17'), findsOneWidget);
    expect(find.text('72%'), findsOneWidget); // banded score pill
    expect(find.text('You both value depth'), findsOneWidget);
    // Never a raw map / JSON.
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('degrades to the fallback label on a 404 — never JSON',
      (tester) async {
    await tester.pumpWidget(_host(ReportSummaryCard(
      reportType: 'appearance',
      reportId: 'me',
      icon: Icons.auto_awesome_outlined,
      fallbackLabel: 'Appearance report',
      api: _FakeApi(status: 404),
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Appearance report'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('{'), findsNothing);
    expect(find.textContaining('ApiException'), findsNothing);
  });

  testWidgets('tapping the card fires onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(ReportSummaryCard(
      reportType: 'match',
      reportId: 'm1',
      icon: Icons.favorite_border,
      fallbackLabel: 'Match report',
      api: _FakeApi(tree: _matchTree()),
      onTap: () => tapped = true,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('report_summary_card_match_m1')));
    expect(tapped, isTrue);
  });
}
