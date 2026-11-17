// Nov 16 2026 founder direction: the person graph must show EVERYTHING in the
// store (reports, photos, skills, assessment, …), neural-network style, each
// tappable node opening its report or photo. These cover the routing logic and
// that the renderer handles every new node kind without breaking.
import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart' show NodeVisualiser;
import 'package:ayma_flutter/widgets/photo_gallery.dart' show PhotoViewer;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PersonGraph _graph() => PersonGraph.fromMap({
      'center': {'id': 'me', 'label': 'You'},
      'sections': const [],
      'nodes': [
        {'id': 'me', 'kind': 'person', 'label': 'You'},
        {'id': 'sec:appearance', 'kind': 'section', 'label': 'Appearance'},
        {
          'id': 'emergent.appearance.report',
          'kind': 'report',
          'label': 'Appearance report',
          'text': 'Face 7.0',
          'visibility': 'private',
          'open': {'type': 'appearance_report', 'id': 'current'},
        },
        {
          'id': 'emergent.webfind.report.RID123',
          'kind': 'report',
          'label': 'Web findings',
          'visibility': 'private',
          'open': {'type': 'webfind_report', 'id': 'RID123'},
        },
        {
          'id': 'emergent.image.p1',
          'kind': 'image',
          'label': 'Photo',
          'text': 'A man smiling',
          'image_url': 'https://cdn/p1.jpg',
          'visibility': 'public',
          'open': {'type': 'image', 'url': 'https://cdn/p1.jpg', 'read': 'A man smiling'},
        },
        {
          'id': 'emergent.skill.physical',
          'kind': 'skill',
          'label': 'Physical profile',
          'visibility': 'private',
        },
        {'id': 'b:1', 'kind': 'bullet', 'text': 'I grew up in Lahore.', 'visibility': 'public'},
      ],
      'edges': [
        {'from': 'me', 'to': 'sec:appearance'},
        {'from': 'sec:appearance', 'to': 'emergent.appearance.report'},
        {'from': 'sec:appearance', 'to': 'emergent.webfind.report.RID123'},
        {'from': 'sec:appearance', 'to': 'emergent.image.p1'},
        {'from': 'sec:appearance', 'to': 'emergent.skill.physical'},
        {'from': 'sec:appearance', 'to': 'b:1'},
      ],
    });

GraphTree _tree() => GraphTree.fromMap({
      'surface': 'graphDetail',
      'sections': [
        {
          'page_type': 'appearance',
          'title': 'Appearance',
          'order': 1,
          'nodes': [
            {
              'id': 'emergent.appearance.report',
              'label': 'Appearance report',
              'text': 'Face 7.0',
              'answer_type': 'text',
              'visibility': 'private',
            },
            // Flat bullet id is `b:1`; the tree indexes the raw id `1`.
            {
              'id': '1',
              'label': '',
              'text': 'I grew up in Lahore.',
              'answer_type': 'text',
              'visibility': 'public',
            },
          ],
        },
      ],
    });

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<PersonGraph> profileGraph({String? uid}) async => _graph();
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      _tree();
}

/// A graph with ONLY an image node under one hub — so a grid of taps can only
/// ever land on the person / section / image node (no report node that would
/// need a router), isolating the image-node → viewer hit path.
PersonGraph _imageOnlyGraph() => PersonGraph.fromMap({
      'center': {'id': 'me', 'label': 'You'},
      'sections': const [],
      'nodes': [
        {'id': 'me', 'kind': 'person', 'label': 'You'},
        {'id': 'sec:identity', 'kind': 'section', 'label': 'Identity'},
        {
          'id': 'emergent.image.p1',
          'kind': 'image',
          'label': 'Photo',
          'text': 'A man smiling outdoors',
          'image_url': 'https://cdn/p1.jpg',
          'visibility': 'public',
          'open': {
            'type': 'image',
            'url': 'https://cdn/p1.jpg',
            'read': 'A man smiling outdoors',
            'is_you': 'yes',
            'source_kind': 'chat',
            'source_ref': 'sess-7',
          },
        },
      ],
      'edges': [
        {'from': 'me', 'to': 'sec:identity'},
        {'from': 'sec:identity', 'to': 'emergent.image.p1'},
      ],
    });

class _ImageOnlyApi extends ApiClient {
  _ImageOnlyApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<PersonGraph> profileGraph({String? uid}) async => _imageOnlyGraph();
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      GraphTree.fromMap({
        'surface': 'graphDetail',
        'sections': [
          {
            'page_type': 'identity',
            'title': 'Identity',
            'order': 1,
            'nodes': [
              {
                'id': 'emergent.image.p1',
                'label': 'Photo',
                'text': 'A man smiling outdoors',
                'answer_type': 'image',
                'image_url': 'https://cdn/p1.jpg',
                'image_read': 'A man smiling outdoors',
                'visibility': 'public',
              },
            ],
          },
        ],
      });
}

GraphNode _node(Map<String, dynamic> open) =>
    GraphNode.fromMap({'id': 'x', 'kind': 'report', 'open': open});

/// Pumps the screen with reduced motion so the force layout settles to a fixed
/// frame synchronously — deterministic node positions for the tap/scrub sweeps.
Widget _reducedMotionApp(ApiClient api) => MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: PersonGraphScreen(api: api),
        ),
      ),
    );

void main() {
  group('graphOpenRoute', () {
    test('an appearance report node pushes /appearance/<id>', () {
      expect(graphOpenRoute(_node({'type': 'appearance_report', 'id': 'current'})),
          '/appearance/current');
      // Missing id falls back to the current report.
      expect(graphOpenRoute(_node({'type': 'appearance_report'})),
          '/appearance/current');
    });

    test('a web-findings node pushes /deep-dive/<id>', () {
      expect(graphOpenRoute(_node({'type': 'webfind_report', 'id': 'RID123'})),
          '/deep-dive/RID123');
    });

    test('an image node has no push route (it opens the photo viewer)', () {
      final img = GraphNode.fromMap({
        'id': 'i',
        'kind': 'image',
        'image_url': 'https://cdn/p.jpg',
        'open': {'type': 'image', 'url': 'https://cdn/p.jpg', 'read': 'read'},
      });
      expect(graphOpenRoute(img), isNull);
      expect(img.openType, 'image');
      expect(img.imageUrl, 'https://cdn/p.jpg');
      expect(img.isOpenable, isTrue);
    });

    test('a plain fact node is not openable', () {
      final b = GraphNode.fromMap({'id': 'b', 'kind': 'bullet', 'text': 'x'});
      expect(graphOpenRoute(b), isNull);
      expect(b.isOpenable, isFalse);
    });
  });

  testWidgets('renders every node kind and opens the legend without overflow',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PersonGraphScreen(api: _FakeApi()),
    ));
    // The graph loads (don't pumpAndSettle — the neural pulse never settles).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The neural canvas painted (CustomPaint present), with no layout overflow
    // (an overflow would have thrown during pump).
    expect(find.byType(CustomPaint), findsWidgets);

    // The legend lists the new node kinds.
    await tester.tap(find.byTooltip('What the colours mean'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text("Ayma's read"), findsOneWidget);
  });

  // Scout NOTE 248 (hit-test), updated for the Nov-17 gesture model: a tap no
  // longer opens the photo directly — it resolves the node and opens it in the
  // visualiser below; the panel's "Open" affordance then opens the full photo.
  // This still proves the hit-test maps a viewport tap into scene coordinates
  // (a dead hit-test, the NOTE 248 bug, would never select the image node).
  testWidgets('a tap resolves to the image node and Open shows the photo',
      (tester) async {
    await tester.pumpWidget(_reducedMotionApp(_ImageOnlyApi()));
    await tester.pump(); // runs the reduced-motion settle + fit
    await tester.pump();

    final canvas = tester.getRect(find.byType(PersonGraphScreen));
    // Sweep a 22px grid (finger tolerance ~22px) until a tap lands on the image
    // node — then the panel shows its "Open" affordance (the only openable node
    // here). Positions are fixed (reduced motion), so this resolves.
    var selected = false;
    for (var y = canvas.top + 60; y < canvas.bottom - 8 && !selected; y += 22) {
      for (var x = canvas.left + 8; x < canvas.right - 8 && !selected; x += 22) {
        await tester.tapAt(Offset(x, y));
        await tester.pump();
        if (find.widgetWithText(TextButton, 'Open').evaluate().isNotEmpty) {
          selected = true;
        }
      }
    }
    expect(selected, isTrue,
        reason: 'a tap must resolve to the image node (scene-space hit-test)');
    // B's real NodeVisualiser renders the selected node below the graph.
    expect(find.byType(NodeVisualiser), findsWidgets);

    await tester.tap(find.widgetWithText(TextButton, 'Open'));
    await tester.pump();
    expect(find.byType(PhotoViewer), findsOneWidget);
    // The read shows (in the viewer caption and in the panel below).
    expect(find.textContaining('A man smiling'), findsWidgets);
  });

  testWidgets("scrubbing the canvas opens nodes in Track B's NodeVisualiser",
      (tester) async {
    await tester.pumpWidget(_reducedMotionApp(_FakeApi()));
    await tester.pump();
    await tester.pump();

    // Nothing selected yet — the panel shows its hint, not the visualiser.
    expect(find.byType(NodeVisualiser), findsNothing);

    // A single-finger drag (scrub) across the canvas must select the node under
    // the finger (never pan). Sweep a grid so the finger passes over a node.
    final canvas = tester.getRect(find.byType(PersonGraphScreen));
    final g = await tester.startGesture(canvas.center);
    for (var y = canvas.top + 60; y < canvas.bottom - 8; y += 26) {
      for (var x = canvas.left + 8; x < canvas.right - 8; x += 26) {
        await g.moveTo(Offset(x, y));
      }
    }
    await g.up();
    await tester.pump();

    // The visualiser is now mounted with a node (scrub resolved to a node).
    expect(find.byType(NodeVisualiser), findsWidgets);
  });

  group('related-link highlight (Contract 4)', () {
    test('a related link lights the related node, both directions', () {
      final nodes = [
        GraphNode.fromMap({
          'id': 'emergent.skill.x',
          'kind': 'skill',
          'links': [
            {'target': 'emergent.report.y', 'type': 'related'},
            {'target': 'bulletraw', 'type': 'related'}, // bullet -> b:bulletraw
            {'target': 'nope', 'type': 'related'}, // no such node, dropped
            {'target': 'emergent.report.y', 'type': 'elaborates'}, // not related
          ],
        }),
        GraphNode.fromMap({'id': 'emergent.report.y', 'kind': 'report'}),
        GraphNode.fromMap({'id': 'b:bulletraw', 'kind': 'bullet'}),
      ];
      final ids = {for (final n in nodes) n.id};
      final adj = buildRelatedAdjacency(nodes, ids);

      expect(adj['emergent.skill.x'], {'emergent.report.y', 'b:bulletraw'});
      // Symmetric: the targets point back at the source.
      expect(adj['emergent.report.y'], {'emergent.skill.x'});
      expect(adj['b:bulletraw'], {'emergent.skill.x'});

      final lit = graphHighlightSet(
        'emergent.skill.x',
        parentsOf: const {},
        childrenOf: const {},
        relatedAdj: adj,
      );
      expect(lit.containsAll(const {
        'emergent.skill.x',
        'emergent.report.y',
        'b:bulletraw',
      }), isTrue);
    });

    test('highlight set is ancestors + descendants + related', () {
      final lit = graphHighlightSet(
        'sec:appearance',
        parentsOf: const {
          'sec:appearance': {'me'}
        },
        childrenOf: const {
          'sec:appearance': {'b:1', 'emergent.image.p1'}
        },
        relatedAdj: const {
          'sec:appearance': {'emergent.report.z'}
        },
      );
      expect(
          lit,
          {
            'sec:appearance', // self
            'me', // ancestor
            'b:1', 'emergent.image.p1', // descendants
            'emergent.report.z', // related
          });
    });
  });

  group('tree node resolution (Contract 3)', () {
    test('indexedStoryFor resolves a bullet flat id via the b: prefix', () {
      final story = StoryNode.fromMap(
          {'id': 'raw1', 'label': 'Fact', 'text': 'hi', 'answer_type': 'text'});
      final idx = {'raw1': story};
      expect(indexedStoryFor('raw1', idx), same(story)); // emergent/raw id
      expect(indexedStoryFor('b:raw1', idx), same(story)); // bullet flat id
      expect(indexedStoryFor('b:missing', idx), isNull);
      expect(indexedStoryFor('sec:appearance', idx), isNull); // a hub: synthesized
    });
  });
}
