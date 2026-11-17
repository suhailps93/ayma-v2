import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/graph_tree_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GraphTree _tree() => GraphTree.fromMap({
      'surface': 'publicProfile',
      'sections': [
        {
          'page_type': 'story',
          'title': 'Story',
          'order': 1,
          'nodes': [
            {
              'id': 'n1',
              'section': 'story',
              'label': 'About',
              'text': 'Climbs on weekends',
              'answer_type': 'text',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
            }
          ],
        }
      ],
    });

class _FakeApi extends ApiClient {
  _FakeApi({this.tree, this.fail = false})
      : super(auth: MockFirebaseAuth(signedIn: true));

  final GraphTree? tree;
  bool fail;
  String? lastSurface;
  String? lastUid;

  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async {
    lastSurface = surface;
    lastUid = uid;
    if (fail) throw Exception('boom');
    return tree ?? GraphTree.fromMap({'surface': surface, 'sections': []});
  }
}

Widget _app(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: ListView(children: [child])),
    );

void main() {
  testWidgets('loads and renders the tree sections, passing the surface',
      (tester) async {
    final api = _FakeApi(tree: _tree());
    await tester.pumpWidget(_app(GraphTreeView(
      uid: 'other',
      surface: NodeVisualiserSurface.publicProfile,
      api: api,
    )));
    await tester.pumpAndSettle();

    expect(api.lastSurface, 'publicProfile');
    expect(api.lastUid, 'other');
    expect(find.text('Climbs on weekends'), findsOneWidget);
  });

  testWidgets('shows the empty message when the tree has no nodes',
      (tester) async {
    await tester.pumpWidget(_app(GraphTreeView(
      surface: NodeVisualiserSurface.publicProfile,
      api: _FakeApi(),
      emptyMessage: 'Nothing public yet.',
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('graph_tree_empty')), findsOneWidget);
    expect(find.text('Nothing public yet.'), findsOneWidget);
  });

  testWidgets('shows a retry on load failure, then recovers', (tester) async {
    final api = _FakeApi(tree: _tree(), fail: true);
    await tester.pumpWidget(_app(GraphTreeView(
      surface: NodeVisualiserSurface.publicProfile,
      api: api,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);

    api.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Climbs on weekends'), findsOneWidget);
  });
}
