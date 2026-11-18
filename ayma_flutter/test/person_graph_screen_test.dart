// Nov 16 2026 founder direction: the person graph must show EVERYTHING in the
// store (reports, photos, skills, assessment, …), neural-network style, each
// tappable node opening its report or photo. These cover the routing logic and
// that the renderer handles every new node kind without breaking.
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/person_graph_layout.dart';
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart' show NodeVisualiser;
import 'package:ayma_flutter/widgets/photo_gallery.dart' show PhotoViewer;
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

PersonGraph _photoAdjacentBulletGraph() => PersonGraph.fromMap({
      'center': {'id': 'me', 'label': 'You'},
      'sections': const [],
      'nodes': [
        {'id': 'me', 'kind': 'person', 'label': 'You'},
        {'id': 'sec:appearance', 'kind': 'section', 'label': 'Appearance'},
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
          },
        },
        {'id': 'b:1', 'kind': 'bullet', 'text': 'Grew up in Lahore.', 'visibility': 'public'},
      ],
      'edges': [
        {'from': 'me', 'to': 'sec:appearance'},
        {'from': 'sec:appearance', 'to': 'emergent.image.p1'},
        {'from': 'sec:appearance', 'to': 'b:1'},
      ],
    });

class _PhotoAdjacentBulletApi extends ApiClient {
  _PhotoAdjacentBulletApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<PersonGraph> profileGraph({String? uid}) async =>
      _photoAdjacentBulletGraph();
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      GraphTree.fromMap({
        'surface': 'graphDetail',
        'sections': [
          {
            'page_type': 'appearance',
            'title': 'Appearance',
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
              {
                'id': '1',
                'label': '',
                'text': 'Grew up in Lahore.',
                'answer_type': 'text',
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
    // A generous, deterministic surface so the single image node has an amply
    // tappable region (the default 600px surface collapses it below the grid
    // step — see the photo-adjacent-bullet test).
    tester.view.physicalSize = const Size(800, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_reducedMotionApp(_ImageOnlyApi()));
    await tester.pump(); // runs the reduced-motion settle + fit
    await tester.pump();

    // Sweep only the graph canvas itself (the _GraphPainter rect), NOT the whole
    // screen — the header filter bar holds controls (Fit, Show all, Hide all)
    // that a blind full-screen sweep would trip, and it holds no graph nodes.
    // Fixed positions (reduced motion), so this resolves on the image node whose
    // panel then shows the "Open" affordance (the only openable node here).
    final canvas = tester.getRect(find.byWidgetPredicate(
        (w) => w is CustomPaint && '${w.painter.runtimeType}' == '_GraphPainter'));
    var selected = false;
    for (var y = canvas.top + 6; y < canvas.bottom - 6 && !selected; y += 8) {
      for (var x = canvas.left + 6; x < canvas.right - 6 && !selected; x += 8) {
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

  group('distanceToGraphNode & hit-test resolution (NOTE 250 Leg 3)', () {
    test('photo node uses square bounds and returns 0.0 inside rect', () {
      final sim = SimNode(id: 'photo', level: 2)
        ..x = 100
        ..y = 100;
      final photo = GraphNode.fromMap({
        'id': 'photo',
        'kind': 'image',
        'open': {'type': 'image', 'url': 'https://cdn/p.jpg', 'read': 'test'},
      });
      // At level 2, radius is 9.5. Half-width is 9.5 * 1.7 / 2 = 8.075.
      // Bounds: [91.925, 108.075] in x and y.
      expect(distanceToGraphNode(sim, photo, const Offset(100, 100)), 0.0);
      expect(distanceToGraphNode(sim, photo, const Offset(108, 100)), 0.0);
      expect(distanceToGraphNode(sim, photo, const Offset(100, 92)), 0.0);

      // Outside to the right by 2.0 units:
      final dRight =
          distanceToGraphNode(sim, photo, const Offset(110.075, 100));
      expect(dRight, closeTo(2.0, 1e-4));
    });

    test(
        'photo node next to bullet resolves to photo node when tap is inside photo bounds',
        () {
      final photoSim = SimNode(id: 'photo', level: 2)
        ..x = 100
        ..y = 100;
      final photoNode = GraphNode.fromMap({
        'id': 'photo',
        'kind': 'image',
        'open': {'type': 'image', 'url': 'https://cdn/p.jpg', 'read': 'photo'},
      });
      // Adjacent bullet at x=123, y=100 with radius 7.5 (level 3).
      final bulletSim = SimNode(id: 'b:1', level: 3)
        ..x = 123
        ..y = 100;
      final bulletNode = GraphNode.fromMap(
          {'id': 'b:1', 'kind': 'bullet', 'text': 'fact'});

      // Tap lands on the right side of the photo node (x=107.5, y=100),
      // which is inside the photo square bounds [91.925, 108.075].
      const tap = Offset(107.5, 100);
      final distPhoto = distanceToGraphNode(photoSim, photoNode, tap);
      final distBullet = distanceToGraphNode(bulletSim, bulletNode, tap);

      expect(distPhoto, 0.0);
      // Distance from tap (107.5) to bullet center (123) is 15.5; minus radius 7.5 = 8.0.
      expect(distBullet, closeTo(8.0, 1e-4));
      expect(distPhoto < distBullet, isTrue);
    });

    test(
        'circular bullet node returns 0.0 inside circle and distance outside',
        () {
      final bulletSim = SimNode(id: 'b:1', level: 3)
        ..x = 120
        ..y = 100;
      final bulletNode = GraphNode.fromMap(
          {'id': 'b:1', 'kind': 'bullet', 'text': 'fact'});
      // Bullet radius at level 3 is 7.5.
      expect(distanceToGraphNode(bulletSim, bulletNode, const Offset(120, 100)),
          0.0);
      expect(distanceToGraphNode(bulletSim, bulletNode, const Offset(125, 100)),
          0.0);
      expect(distanceToGraphNode(bulletSim, bulletNode, const Offset(130, 100)),
          closeTo(2.5, 1e-4));
    });

    testWidgets(
        'photo node adjacent to bullet: tap resolves to photo and second tap opens photo viewer',
        (tester) async {
      // Pin a tall, deterministic surface. The force layout settles in its own
      // coordinate space and is then scaled to fit the (ChromeColumn) graph
      // canvas, so every node's on-screen region scales with the canvas size. A
      // generous canvas gives the photo node an amply tappable target, immune to
      // the ~30px the appBar + visibility-legend row take from the canvas (which
      // on the default 600px surface collapses the photo's region below the grid
      // step).
      tester.view.physicalSize = const Size(800, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_reducedMotionApp(_PhotoAdjacentBulletApi()));
      await tester.pump();
      await tester.pump();

      // Sweep only the graph canvas itself (not the whole screen — its header
      // filter bar and footer detail panel hold no graph nodes) until a tap
      // lands on the photo node (the only openable node — its "Open" affordance
      // marks a hit; the adjacent bullet is inert).
      final canvas = tester.getRect(find.byWidgetPredicate(
          (w) => w is CustomPaint && '${w.painter.runtimeType}' == '_GraphPainter'));
      Offset? photoTapPos;
      for (var y = canvas.top + 6;
          y < canvas.bottom - 6 && photoTapPos == null;
          y += 8) {
        for (var x = canvas.left + 6;
            x < canvas.right - 6 && photoTapPos == null;
            x += 8) {
          await tester.tapAt(Offset(x, y));
          await tester.pump();
          if (find.widgetWithText(TextButton, 'Open').evaluate().isNotEmpty) {
            photoTapPos = Offset(x, y);
          }
        }
      }
      expect(photoTapPos, isNotNull,
          reason:
              'a tap must resolve to the photo node even when a bullet sits adjacent');
      expect(find.byType(NodeVisualiser), findsWidgets);
      expect(find.textContaining('A man smiling outdoors'), findsWidgets);

      // Tapping Open on the selected photo node opens the PhotoViewer dialog.
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await tester.pump();
      expect(find.byType(PhotoViewer), findsOneWidget);
    });
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

    // Part B regression (person-graph-sections): the PAINTER must APPLY the
    // highlight — a tapped node lights its connected set and DIMS the rest. The
    // painter paints every node through `graphNodeLit` and every edge through
    // `graphEdgeLit`, so asserting those pure predicates proves the render dims
    // non-members and lights members (opacity/brightness), not just that the
    // highlight SET is computed.
    test('graphNodeLit: nothing selected lights every node', () {
      expect(graphNodeLit(null, const {}, 'anything'), isTrue);
      expect(graphNodeLit(null, const {'x'}, 'y'), isTrue);
    });

    test('graphNodeLit: a selection lights its set and dims everyone else', () {
      // A section tapped: self + You (ancestor) + its facts (descendants) lit.
      final lit = graphHighlightSet(
        'sec:appearance',
        parentsOf: const {
          'sec:appearance': {'me'}
        },
        childrenOf: const {
          'sec:appearance': {'b:1', 'emergent.image.p1'}
        },
        relatedAdj: const {},
      );
      const selected = 'sec:appearance';
      // Members (self, ancestor, every descendant) render LIT.
      for (final id in lit) {
        expect(graphNodeLit(selected, lit, id), isTrue, reason: '$id lit');
      }
      // A node in a DIFFERENT section renders DIMMED.
      expect(graphNodeLit(selected, lit, 'sec:career'), isFalse);
      expect(graphNodeLit(selected, lit, 'b:other'), isFalse);
    });

    test('graphEdgeLit: only edges with both endpoints in the set glow', () {
      const sel = 'sec:appearance';
      const lit = {'sec:appearance', 'me', 'b:1'};
      // Edge inside the lit set glows.
      expect(graphEdgeLit(sel, lit, 'me', 'sec:appearance'), isTrue);
      expect(graphEdgeLit(sel, lit, 'sec:appearance', 'b:1'), isTrue);
      // An edge leaving the set (to a dimmed node) does not glow.
      expect(graphEdgeLit(sel, lit, 'sec:appearance', 'b:other'), isFalse);
      // With nothing selected no edge is "lit" (the resting-graph pass).
      expect(graphEdgeLit(null, const {}, 'me', 'sec:appearance'), isFalse);
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

  group('master filter controls (Show all / Hide all)', () {
    List<FilterChip> chips(WidgetTester tester) =>
        tester.widgetList<FilterChip>(find.byType(FilterChip)).toList();

    testWidgets('Show all enables every filter; Hide all clears every filter',
        (tester) async {
      await tester.pumpWidget(_reducedMotionApp(_FakeApi()));
      await tester.pump();
      await tester.pump();

      // Every type/level chip starts ON (nothing hidden).
      expect(chips(tester), isNotEmpty);
      expect(chips(tester).every((c) => c.selected), isTrue);

      // Hide all -> every chip OFF, and the empty canvas paints cleanly.
      await tester.tap(find.widgetWithText(TextButton, 'Hide all'));
      await tester.pump();
      expect(chips(tester).every((c) => !c.selected), isTrue);
      expect(tester.takeException(), isNull,
          reason: 'empty state (all filters off) must render without exception');

      // Show all -> every chip ON again.
      await tester.tap(find.widgetWithText(TextButton, 'Show all'));
      await tester.pump();
      expect(chips(tester).every((c) => c.selected), isTrue);
    });

    testWidgets('an individual chip still toggles after a master control',
        (tester) async {
      await tester.pumpWidget(_reducedMotionApp(_FakeApi()));
      await tester.pump();
      await tester.pump();

      // After Hide all every chip is OFF.
      await tester.tap(find.widgetWithText(TextButton, 'Hide all'));
      await tester.pump();
      expect(chips(tester).every((c) => !c.selected), isTrue);

      // Tapping one chip ('You') turns that filter back ON *and actually renders
      // its nodes*. Regression for build 2495: the old filter AND-gated kind AND
      // level, and Hide all hid BOTH, so un-hiding one KIND left every level
      // hidden → the chip lit but the canvas stayed EMPTY. The toggle now
      // releases the vestigial all-levels-hidden block, so nodes come back.
      final you = find.widgetWithText(FilterChip, 'You');
      await tester.ensureVisible(you);
      await tester.tap(you);
      await tester.pump();
      expect(tester.widget<FilterChip>(you).selected, isTrue);

      // The canvas is NOT empty — the person node renders. Count non-background
      // pixels in the graph canvas (the bug left it fully blank).
      Future<int> litPixels() async {
        final canvas = find.byWidgetPredicate((w) =>
            w is CustomPaint && '${w.painter.runtimeType}' == '_GraphPainter');
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.ancestor(of: canvas, matching: find.byType(RepaintBoundary)).first);
        var lit = 0;
        await tester.runAsync(() async {
          final img = await boundary.toImage();
          final data =
              await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          final bytes = data!.buffer.asUint8List();
          for (var i = 0; i < bytes.length; i += 4) {
            // non-near-black pixel = something was drawn
            if (bytes[i] > 40 || bytes[i + 1] > 40 || bytes[i + 2] > 40) lit++;
          }
        });
        return lit;
      }

      expect(await litPixels(), greaterThan(0),
          reason: 'un-hiding a kind after Hide all must render its nodes');

      // Tapping it again hides it — back to the empty canvas, no crash.
      await tester.tap(you);
      await tester.pump();
      expect(tester.widget<FilterChip>(you).selected, isFalse);
      expect(await litPixels(), 0, reason: 'hiding it again empties the canvas');
      expect(tester.takeException(), isNull);
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

  group('related chips in the node visualiser (founder Nov 18)', () {
    test('relatedChipLabel prefers the label, falls back to text, truncates', () {
      const withLabel =
          GraphNode(id: 'a', kind: 'fact', label: 'The dog Rocky', text: 'body');
      expect(relatedChipLabel(withLabel), 'The dog Rocky');
      const noLabel = GraphNode(id: 'b', kind: 'fact', text: 'Rocky again');
      expect(relatedChipLabel(noLabel), 'Rocky again');
      const empty = GraphNode(id: 'c', kind: 'fact');
      expect(relatedChipLabel(empty), 'Related note');
      final long = GraphNode(
          id: 'd', kind: 'fact', label: 'x' * 60);
      expect(relatedChipLabel(long).endsWith('…'), isTrue);
      expect(relatedChipLabel(long).length, lessThanOrEqualTo(40));
    });
  });
}
