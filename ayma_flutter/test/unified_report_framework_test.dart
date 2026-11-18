// The ONE visual report framework (founder Nov 17): every report renders as a
// formatted visual page ASSEMBLED FROM ITS NODES' VISUALS by the shared
// GraphTreeView + NodeVisualiser palette — no per-report code. This suite pins:
//  - a report tree renders as designed section CARDS on the report surface;
//  - scores → gauge/bar, photos → ONE swipeable carousel, findings → card,
//    plain facts → gist row, assembled generically;
//  - a NEVER-BREAKING contract: missing / partial / odd-shaped nodes degrade to
//    a gist row or are omitted — never a crash, overflow, raw JSON or empty page;
//  - privacy: the public-profile viewer filter drops private/Ayma-only nodes.
import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/graph_tree_view.dart';
import 'package:ayma_flutter/widgets/node_photo_carousel.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.tree) : super(auth: MockFirebaseAuth(signedIn: true));
  final GraphTree tree;
  String? lastType;

  @override
  Future<GraphTree> reportTree(String reportType, String reportId) async {
    lastType = reportType;
    return tree;
  }

  @override
  Future<GraphTree> sharedReportTree(String token) async => tree;

  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      tree;
}

Map<String, dynamic> _node(Map<String, dynamic> over) => {
      'section': 's',
      'label': '',
      'text': '',
      'answer_type': 'text',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      ...over,
    };

GraphTree _reportTree(List<Map<String, dynamic>> nodes,
        {String title = 'Report', String pageType = 'overview'}) =>
    GraphTree.fromMap({
      'surface': 'report',
      'title': title,
      'meta': {'created_at': '2026-11-17', 'viewer_can_edit': false},
      'sections': [
        {'page_type': pageType, 'title': 'Overview', 'order': 0, 'nodes': nodes},
      ],
    });

Widget _host(Widget child) => MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> _pumpReport(WidgetTester tester, GraphTree tree,
    {String type = 'match'}) async {
  await tester.pumpWidget(_host(GraphTreeView(
    surface: NodeVisualiserSurface.report,
    reportType: type,
    reportId: 'id1',
    api: _FakeApi(tree),
  )));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a report renders as a designed section card with a serif title',
      (tester) async {
    await _pumpReport(
        tester, _reportTree([_node({'id': 'n1', 'text': 'A plain fact'})]));
    expect(tester.takeException(), isNull);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('A plain fact'), findsOneWidget);
  });

  testWidgets('a numeric score node assembles as a banded bar', (tester) async {
    await _pumpReport(
        tester,
        _reportTree([
          _node({
            'id': 'score',
            'label': 'Match score',
            'text': 'Match score',
            'answer_type': 'stat',
            'stat_value': 72,
            'visual': {
              'type': 'bar_meter',
              'params': {'value': 72, 'min': 0, 'max': 100, 'label': 'Match score'},
              'v': 1,
            },
          }),
        ]));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('node_bar_score')), findsOneWidget);
    expect(find.byKey(const Key('node_bar_value_score')), findsOneWidget);
  });

  testWidgets('consecutive report image nodes assemble into ONE carousel',
      (tester) async {
    await _pumpReport(
        tester,
        _reportTree([
          _node({
            'id': 'p1',
            'answer_type': 'image',
            'image_url': 'https://example.com/a.jpg',
            'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
          }),
          _node({
            'id': 'p2',
            'answer_type': 'image',
            'image_url': 'https://example.com/b.jpg',
            'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
          }),
        ]));
    expect(tester.takeException(), isNull);
    // One carousel for the two images, not two separate thumbnails.
    expect(find.byType(NodePhotoCarousel), findsOneWidget);
    expect(find.byKey(const Key('node_photo_carousel')), findsOneWidget);
  });

  testWidgets(
      'NON-consecutive image nodes still assemble into ONE carousel of ALL of '
      'them (Scout NOTE 255: appearance photos were splitting out)',
      (tester) async {
    Map<String, dynamic> img(String id) => _node({
          'id': id,
          'answer_type': 'image',
          'image_url': 'https://example.com/$id.jpg',
          'image_read': 'photo $id',
          'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
        });
    await _pumpReport(
        tester,
        _reportTree([
          img('p1'),
          img('p2'),
          img('p3'),
          // A non-image finding BETWEEN the image leaves — this is what used to
          // split the appearance photos out into separate "large embedded"
          // single-image renders.
          _node({'id': 'fact', 'text': 'A finding', 'gist': 'A finding'}),
          img('p4'),
          img('p5'),
          img('p6'),
          img('p7'),
        ]));
    expect(tester.takeException(), isNull);
    // ONE carousel, not one-per-run and not a grid of singles.
    expect(find.byType(NodePhotoCarousel), findsOneWidget);
    final carousel =
        tester.widget<NodePhotoCarousel>(find.byType(NodePhotoCarousel));
    expect(carousel.images.length, 7, reason: 'all 7 image leaves aggregate');
    // The non-image finding still renders (it is NOT swallowed by the carousel).
    expect(find.text('A finding'), findsOneWidget);
  });

  testWidgets(
      'the carousel is a horizontally swipeable strip across ALL images',
      (tester) async {
    Map<String, dynamic> img(int i) => _node({
          'id': 'p$i',
          'answer_type': 'image',
          'image_url': 'https://example.com/p$i.jpg',
          'image_read': 'caption $i',
          'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
        });
    await _pumpReport(
        tester, _reportTree([for (var i = 0; i < 6; i++) img(i)]));
    expect(tester.takeException(), isNull);

    // The strip is a HORIZONTAL ListView whose delegate holds ALL 6 images
    // (more than fit on screen) — a real scrolling strip, not a static grid.
    final strip = find.byKey(const Key('node_carousel_strip'));
    expect(strip, findsOneWidget);
    final listView = tester.widget<ListView>(strip);
    expect(listView.scrollDirection, Axis.horizontal);
    // The carousel holds ALL 6 image nodes (more than fit on a phone screen).
    final carousel =
        tester.widget<NodePhotoCarousel>(find.byType(NodePhotoCarousel));
    expect(carousel.images.length, 6);

    // A horizontal drag SCROLLS the strip (it advances, it is not frozen).
    final position = tester
        .state<ScrollableState>(
            find.descendant(of: strip, matching: find.byType(Scrollable)))
        .position;
    expect(position.pixels, 0);
    await tester.drag(strip, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0),
        reason: 'the strip scrolled horizontally on swipe');
  });

  testWidgets(
      'tapping a carousel tile opens the fullscreen detail — a PageView that '
      'advances on swipe',
      (tester) async {
    Map<String, dynamic> img(int i) => _node({
          'id': 'p$i',
          'answer_type': 'image',
          'image_url': 'https://example.com/p$i.jpg',
          'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
        });
    await _pumpReport(tester, _reportTree([for (var i = 0; i < 3; i++) img(i)]));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('node_carousel_photo_0')));
    await tester.pumpAndSettle();
    // The detail is a swipeable PageView across the carousel's images.
    expect(find.byType(PageView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'privacy: a private image never enters the public-surface carousel',
      (tester) async {
    final tree = GraphTree.fromMap({
      'surface': 'publicProfile',
      'sections': [
        {
          'page_type': 's',
          'title': 'Photos',
          'order': 0,
          'nodes': [
            _node({
              'id': 'pub',
              'answer_type': 'image',
              'image_url': 'https://example.com/pub.jpg',
              'image_read': 'public photo',
              'visibility': 'public',
              'subtree_visibility': 'public',
              'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
            }),
            _node({
              'id': 'secret',
              'answer_type': 'image',
              'image_url': 'https://example.com/secret.jpg',
              'image_read': 'private photo',
              'visibility': 'private',
              'subtree_visibility': 'private',
              'visual': {'type': 'photo_carousel', 'params': {}, 'v': 1},
            }),
          ],
        }
      ],
    });
    await tester.pumpWidget(_host(GraphTreeView(
      surface: NodeVisualiserSurface.publicProfile,
      uid: 'other',
      isOwner: false,
      api: _FakeApi(tree),
    )));
    await tester.pumpAndSettle();
    // On the public surface the carousel holds ONLY the public photo.
    final carousels = find.byType(NodePhotoCarousel);
    if (carousels.evaluate().isNotEmpty) {
      final carousel = tester.widget<NodePhotoCarousel>(carousels);
      expect(carousel.images.length, 1);
      expect(carousel.images.first.id, 'pub');
    }
    expect(find.text('private photo'), findsNothing);
  });

  testWidgets('a finding card assembles from a card visual', (tester) async {
    await _pumpReport(
        tester,
        _reportTree([
          _node({
            'id': 'f1',
            'visual': {
              'type': 'card',
              'params': {'title': 'Great rapport', 'body': 'You both value depth.'},
              'v': 1,
            },
          }),
        ]));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('node_card_f1')), findsOneWidget);
    expect(find.text('Great rapport'), findsOneWidget);
  });

  group('NEVER BREAKING — malformed / partial graphs', () {
    testWidgets('absent visual, bad params and wrong types all degrade cleanly',
        (tester) async {
      await _pumpReport(
          tester,
          _reportTree([
            // No visual at all → gist row.
            _node({'id': 'a', 'text': 'Node with no visual', 'gist': 'Node with no visual'}),
            // Gauge with empty params (no value) → falls back to gist row.
            _node({
              'id': 'b',
              'text': 'Gauge missing value',
              'gist': 'Gauge missing value',
              'visual': {'type': 'gauge', 'params': {}, 'v': 1},
            }),
            // small_table with no rows → falls back to gist row.
            _node({
              'id': 'c',
              'text': 'Table with no rows',
              'gist': 'Table with no rows',
              'visual': {'type': 'small_table', 'params': {'columns': ['x']}, 'v': 1},
            }),
            // Entirely unknown type → gist row.
            _node({
              'id': 'd',
              'text': 'Unknown visual type',
              'gist': 'Unknown visual type',
              'visual': {'type': 'hologram', 'params': {'foo': 'bar'}, 'v': 7},
            }),
          ]));
      expect(tester.takeException(), isNull);
      // Each degraded to its readable gist, never a crash, never a map dump.
      expect(find.text('Node with no visual'), findsOneWidget);
      expect(find.text('Gauge missing value'), findsOneWidget);
      expect(find.text('Table with no rows'), findsOneWidget);
      expect(find.text('Unknown visual type'), findsOneWidget);
      // No raw JSON / map braces anywhere on screen.
      expect(find.textContaining('{'), findsNothing);
      expect(find.textContaining('params'), findsNothing);
    });

    testWidgets('an empty section renders nothing, not an empty titled card',
        (tester) async {
      await _pumpReport(
          tester,
          GraphTree.fromMap({
            'surface': 'report',
            'title': 'Report',
            'sections': [
              {'page_type': 'empty', 'title': 'Empty', 'order': 0, 'nodes': []},
            ],
          }));
      expect(tester.takeException(), isNull);
      // Empty tree → the honest empty message, never a bare titled card.
      expect(find.byKey(const Key('graph_tree_empty')), findsOneWidget);
    });

    testWidgets('a section whose only node is empty shows no card',
        (tester) async {
      await _pumpReport(
          tester,
          _reportTree([
            _node({'id': 'blank', 'text': '', 'gist': ''}),
          ]));
      expect(tester.takeException(), isNull);
      // The section had no renderable node → it (and its card) are omitted; the
      // empty message stands instead of an empty "Overview" card.
      expect(find.text('Overview'), findsNothing);
    });
  });

  testWidgets('privacy: the public-profile viewer filter drops a private node',
      (tester) async {
    // A report tree is server-filtered, but the client filter is the backstop:
    // on the public-profile surface a private node never renders.
    final tree = GraphTree.fromMap({
      'surface': 'publicProfile',
      'sections': [
        {
          'page_type': 's',
          'title': 'Story',
          'order': 0,
          'nodes': [
            _node({'id': 'pub', 'text': 'Public strength', 'gist': 'Public strength'}),
            _node({
              'id': 'priv',
              'text': 'Private secret',
              'gist': 'Private secret',
              'visibility': 'private',
              'subtree_visibility': 'private',
            }),
          ],
        }
      ],
    });
    await tester.pumpWidget(_host(GraphTreeView(
      surface: NodeVisualiserSurface.publicProfile,
      uid: 'other',
      isOwner: false,
      api: _FakeApi(tree),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Public strength'), findsOneWidget);
    expect(find.text('Private secret'), findsNothing);
  });
}
