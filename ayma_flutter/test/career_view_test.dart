// Regression test for the dedicated Career view (CareerViewScreen).
//
// Reproduces the founder's exact path: open Career & education → the view lists
// the Career section node's children (the seed nodes, the LinkedIn link node,
// and an emergent career child), dates render ONLY where a node already carries
// one, and editing an entry persists through the generic node-edit path
// (`/profile/graph/node/{id}/visibility`) the Node-Visualiser already uses.
import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/career_view_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Career section tree: the LinkedIn link node, a DATED career node, an
/// UNDATED career node, plus an unrelated section to prove the view filters to
/// career only.
GraphTree _tree() => GraphTree.fromMap({
      'surface': 'story',
      'sections': [
        {
          'page_type': 'identity',
          'title': 'About Me',
          'order': 0,
          'nodes': [
            {
              'id': 'legal_first_name',
              'section': 'identity',
              'label': 'Name',
              'text': 'Sam',
              'answer_type': 'text',
              'visibility': 'public',
              'subtree_visibility': 'public',
            }
          ],
        },
        {
          'page_type': 'career',
          'title': 'Career',
          'order': 3,
          'nodes': [
            {
              'id': 'career.linkedin',
              'section': 'career',
              'label': 'LinkedIn',
              'text': 'LinkedIn',
              'answer_type': 'link',
              'link_url': 'https://www.linkedin.com/in/sam',
              'link_platform': 'linkedin',
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
            {
              'id': 'career_role_narrative',
              'section': 'career',
              'label': 'Role',
              'text': 'Senior engineer at Acme',
              'answer_type': 'narrative',
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': true,
              'dated': '2021-06 — present',
            },
            {
              'id': 'education_level',
              'section': 'career',
              'label': 'Education',
              'text': 'BSc Computer Science',
              'answer_type': 'narrative',
              'visibility': 'private',
              'subtree_visibility': 'private',
              'editable': true,
            },
          ],
        },
      ],
    });

class _FakeApi extends ApiClient {
  _FakeApi({this.tree})
      : super(auth: MockFirebaseAuth(signedIn: true));

  final GraphTree? tree;
  String? lastSurface;
  final List<(String, String)> visibilitySet = [];

  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async {
    lastSurface = surface;
    return tree ?? GraphTree.fromMap({'surface': surface, 'sections': []});
  }

  @override
  Future<int> graphNodeSetVisibility(String nodeId, String visibility) async {
    visibilitySet.add((nodeId, visibility));
    return 1;
  }
}

Widget _app(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: child,
    );

void main() {
  testWidgets(
      'lists the career section children (seed + LinkedIn + emergent), '
      'filtering to career only', (tester) async {
    final api = _FakeApi(tree: _tree());
    await tester.pumpWidget(_app(CareerViewScreen(api: api)));
    await tester.pumpAndSettle();

    // Loaded the owner story surface.
    expect(api.lastSurface, NodeVisualiserSurface.story.name);

    // Every career child is listed (as a real node row).
    expect(find.byKey(const Key('career_entry_career.linkedin')),
        findsOneWidget);
    expect(find.byKey(const Key('career_entry_career_role_narrative')),
        findsOneWidget);
    expect(find.byKey(const Key('career_entry_education_level')),
        findsOneWidget);
    expect(find.text('Senior engineer at Acme'), findsOneWidget);
    expect(find.text('BSc Computer Science'), findsOneWidget);

    // It is the DEDICATED Career view — the unrelated identity node is absent.
    expect(find.text('Sam'), findsNothing);
  });

  testWidgets('renders a date only where the node already carries one',
      (tester) async {
    await tester.pumpWidget(_app(CareerViewScreen(api: _FakeApi(tree: _tree()))));
    await tester.pumpAndSettle();

    // The dated node shows its date; the undated one shows none (never invented).
    expect(find.byKey(const Key('career_date_career_role_narrative')),
        findsOneWidget);
    expect(find.text('2021-06 — present'), findsOneWidget);
    expect(find.byKey(const Key('career_date_education_level')), findsNothing);
    expect(find.byKey(const Key('career_date_career.linkedin')), findsNothing);
  });

  testWidgets('editing an entry persists through the generic node-edit path',
      (tester) async {
    final api = _FakeApi(tree: _tree());
    await tester.pumpWidget(_app(CareerViewScreen(api: api)));
    await tester.pumpAndSettle();

    // Tap the private education entry → its node sheet → Make public, the same
    // /profile/graph/node/{id}/visibility path the Node-Visualiser uses.
    await tester.tap(find.byKey(const Key('node_row_education_level')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bubble_visibility')));
    await tester.pumpAndSettle();

    expect(api.visibilitySet, [('education_level', NodeVis.public)]);
  });

  testWidgets('empty career shows the prompt, not a crash', (tester) async {
    await tester.pumpWidget(_app(CareerViewScreen(
      api: _FakeApi(tree: GraphTree.fromMap({'surface': 'story', 'sections': []})),
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('career_empty')), findsOneWidget);
  });
}
