// Part 2 (less-text-heavy program): the fixed VISUAL palette renderers.
//
// The UI is a THIN renderer — one renderer per palette entry, driven ENTIRELY
// by the node's `visual` field. These tests pin, per palette type:
//   * the correct widget renders from `node.visual` (+ params);
//   * an unknown / absent `visual.type` falls back to the gist row;
//   * a tap on a chip / timeline entry / bar / card / table row opens the
//     partial node chat with the SAME owner controls as a bullet;
//   * PRIVACY: a private / Ayma-only node never renders on the public-profile
//     surface, NOR is it aggregated into a shared visual (chip set / timeline);
//   * DELETE: removing a node drops it from every aggregate in the same pass.

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:ayma_flutter/widgets/score_bar.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout_matrix.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  @override
  Future<int> graphNodeSetVisibility(String nodeId, String visibility) async =>
      1;

  @override
  Future<int> graphDeleteCount(String nodeId) async => 0;

  @override
  Future<int> graphDeleteNode(String nodeId) async => 1;
}

/// A node carrying an explicit palette [visual].
StoryNode _vnode({
  required String id,
  required String type,
  Map<String, dynamic> params = const {},
  String text = 'full prose',
  String gist = '',
  String vis = NodeVis.public,
  String section = 'identity',
  String answerType = 'narrative',
  String imageUrl = '',
  int level = 1,
  List<StoryNode> children = const [],
}) =>
    StoryNode(
      id: id,
      section: section,
      label: '',
      text: text,
      gist: gist,
      answerType: answerType,
      level: level,
      visibility: vis,
      subtreeVisibility: vis,
      standard: false,
      editable: vis != NodeVis.aymaOnly,
      imageUrl: imageUrl,
      visual: NodeVisual(type: type, params: params),
      children: children,
    );

/// A section wrapper so sibling aggregation (chip sets / timelines) is exercised
/// through the real section renderer.
Widget _hostSection(List<StoryNode> nodes,
        {NodeVisualiserSurface surface = NodeVisualiserSurface.story,
        ApiClient? api}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NodeVisualiserSection(
            section: GraphTreeSection(
                pageType: 'identity', title: 'About', order: 0, nodes: nodes),
            surface: surface,
            api: api,
          ),
        ),
      ),
    );

Widget _host(StoryNode node,
        {NodeVisualiserSurface surface = NodeVisualiserSurface.story,
        ApiClient? api}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: NodeVisualiser(node: node, surface: surface, api: api),
        ),
      ),
    );

void main() {
  setUp(() => AymaSession.instance.store.seed(const []));

  // --- per-palette-type render --------------------------------------------

  testWidgets('chip_set renders tappable chips from params.items',
      (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'c1',
      type: NodeVisualType.chipSet,
      params: const {'items': ['Climbing', 'Jazz', 'Ramen']},
    )));
    expect(find.text('Climbing'), findsOneWidget);
    expect(find.text('Jazz'), findsOneWidget);
    expect(find.byKey(const Key('node_chip_c1_0')), findsOneWidget);
    expect(find.byKey(const Key('node_chip_c1_2')), findsOneWidget);
  });

  testWidgets('timeline_entry renders date + title', (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 't1',
      type: NodeVisualType.timelineEntry,
      params: const {'date': '2021-06', 'title': 'Senior engineer at Acme'},
    )));
    expect(find.byKey(const Key('node_timeline_t1')), findsOneWidget);
    expect(find.text('2021-06'), findsOneWidget);
    expect(find.text('Senior engineer at Acme'), findsOneWidget);
  });

  testWidgets('bar_meter renders a ScoreBar + value from params', (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'b1',
      type: NodeVisualType.barMeter,
      params: const {'value': 72.0, 'min': 0.0, 'max': 100.0, 'label': 'Match'},
    )));
    expect(find.byKey(const Key('node_bar_b1')), findsOneWidget);
    expect(find.byType(ScoreBar), findsOneWidget);
    expect(find.text('Match'), findsOneWidget);
    expect(find.text('72'), findsOneWidget);
  });

  testWidgets('gauge renders its own keyed bar', (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'g1',
      type: NodeVisualType.gauge,
      params: const {'value': 6.0, 'min': 0.0, 'max': 10.0, 'label': 'Energy'},
    )));
    expect(find.byKey(const Key('node_gauge_g1')), findsOneWidget);
  });

  testWidgets('card renders title + body', (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'cd1',
      type: NodeVisualType.card,
      params: const {'title': 'Strong communicator', 'body': 'Clear and warm.'},
    )));
    expect(find.byKey(const Key('node_card_cd1')), findsOneWidget);
    expect(find.text('Strong communicator'), findsOneWidget);
    expect(find.text('Clear and warm.'), findsOneWidget);
  });

  testWidgets('small_table renders a header + data rows', (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'tb1',
      type: NodeVisualType.smallTable,
      params: const {
        'columns': ['Trait', 'You'],
        'rows': [
          ['Openness', 'High'],
          ['Warmth', 'High'],
        ],
      },
    )));
    expect(find.byKey(const Key('node_table_tb1')), findsOneWidget);
    expect(find.text('Trait'), findsOneWidget);
    expect(find.text('Openness'), findsOneWidget);
    expect(find.byKey(const Key('node_table_row_tb1_1')), findsOneWidget);
  });

  testWidgets('photo_carousel reuses the shared NodeImage renderer',
      (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'p1',
      type: NodeVisualType.photoCarousel,
      answerType: 'image',
      imageUrl: 'https://img/p.jpg',
      text: 'a read',
    )));
    expect(find.byType(NodeImage), findsOneWidget);
  });

  // --- unknown / absent type + insufficient params → gist_row fallback ------

  testWidgets('unknown visual.type falls back to the gist row', (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'u1',
      type: 'some_future_type',
      text: 'The full prose line',
      gist: 'A gist headline',
    )));
    // No palette widget, never raw JSON — the gist row renders.
    expect(find.text('A gist headline'), findsOneWidget);
    expect(find.byKey(const Key('node_card_u1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bar_meter with no value falls back to the gist row',
      (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'u2',
      type: NodeVisualType.barMeter,
      params: const {'label': 'No value'},
      gist: 'Fallback gist',
    )));
    expect(find.byKey(const Key('node_bar_u2')), findsNothing);
    expect(find.text('Fallback gist'), findsOneWidget);
  });

  testWidgets('chip_set with empty items falls back to the gist row',
      (tester) async {
    await tester.pumpWidget(_host(_vnode(
      id: 'u3',
      type: NodeVisualType.chipSet,
      params: const {'items': <String>[]},
      gist: 'Just a line',
    )));
    // Empty params → no chip; the gist is shown as a single chip of the gist is
    // suppressed because items is empty and gist drives one chip. Guard: the
    // node still renders something readable, never crashes.
    expect(tester.takeException(), isNull);
    expect(find.text('Just a line'), findsWidgets);
  });

  // --- tap-to-controls (every visual opens the node chat) ------------------

  Future<void> expectOpensControls(
      WidgetTester tester, Key tapKey, String nodeId) async {
    await tester.tap(find.byKey(tapKey));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.askAymaContext?.nodeId, nodeId);
    // The SAME owner controls as a bullet ride inside the chat.
    expect(find.byKey(const Key('bubble_visibility')), findsOneWidget);
    expect(find.byKey(const Key('bubble_delete')), findsOneWidget);
  }

  testWidgets('chip tap opens the node controls', (tester) async {
    await tester.pumpWidget(_host(
      _vnode(
          id: 'c1',
          type: NodeVisualType.chipSet,
          params: const {'items': ['Climbing']}),
      api: _FakeApi(),
    ));
    await expectOpensControls(tester, const Key('node_chip_c1_0'), 'c1');
  });

  testWidgets('timeline entry tap opens the node controls', (tester) async {
    await tester.pumpWidget(_host(
      _vnode(
          id: 't1',
          type: NodeVisualType.timelineEntry,
          params: const {'date': '2021', 'title': 'Acme'}),
      api: _FakeApi(),
    ));
    await expectOpensControls(tester, const Key('node_timeline_t1'), 't1');
  });

  testWidgets('bar tap (the row) opens the node controls', (tester) async {
    await tester.pumpWidget(_host(
      _vnode(
          id: 'b1',
          type: NodeVisualType.barMeter,
          params: const {'value': 5.0, 'min': 0.0, 'max': 10.0}),
      api: _FakeApi(),
    ));
    await expectOpensControls(tester, const Key('node_row_b1'), 'b1');
  });

  testWidgets('card tap (the row) opens the node controls', (tester) async {
    await tester.pumpWidget(_host(
      _vnode(
          id: 'cd1',
          type: NodeVisualType.card,
          params: const {'title': 'Finding', 'body': 'Detail'}),
      api: _FakeApi(),
    ));
    await expectOpensControls(tester, const Key('node_row_cd1'), 'cd1');
  });

  testWidgets('table row tap opens the node controls', (tester) async {
    await tester.pumpWidget(_host(
      _vnode(
          id: 'tb1',
          type: NodeVisualType.smallTable,
          params: const {
            'columns': ['A'],
            'rows': [
              ['1'],
            ],
          }),
      api: _FakeApi(),
    ));
    await expectOpensControls(tester, const Key('node_table_row_tb1_0'), 'tb1');
  });

  // --- P0 PRIVACY ----------------------------------------------------------

  testWidgets(
      'a private node never renders on the public-profile surface nor in its '
      'aggregate', (tester) async {
    final nodes = [
      _vnode(
          id: 'pub',
          type: NodeVisualType.chipSet,
          params: const {'items': ['PublicInterest']},
          vis: NodeVis.public),
      _vnode(
          id: 'priv',
          type: NodeVisualType.chipSet,
          params: const {'items': ['SecretInterest']},
          vis: NodeVis.private),
      _vnode(
          id: 'ai',
          type: NodeVisualType.chipSet,
          params: const {'items': ['AymaOnlyInterest']},
          vis: NodeVis.aymaOnly),
    ];
    await tester.pumpWidget(
        _hostSection(nodes, surface: NodeVisualiserSurface.publicProfile));
    // Only the public chip is aggregated; private + Ayma-only never appear.
    expect(find.text('PublicInterest'), findsOneWidget);
    expect(find.text('SecretInterest'), findsNothing);
    expect(find.text('AymaOnlyInterest'), findsNothing);
    expect(find.byKey(const Key('node_chip_priv_0')), findsNothing);
    expect(find.byKey(const Key('node_chip_ai_0')), findsNothing);
  });

  testWidgets('sibling chip aggregate merges only viewer-visible nodes',
      (tester) async {
    final nodes = [
      _vnode(
          id: 'a',
          type: NodeVisualType.chipSet,
          params: const {'items': ['A']},
          vis: NodeVis.public),
      _vnode(
          id: 'b',
          type: NodeVisualType.chipSet,
          params: const {'items': ['B']},
          vis: NodeVis.private),
      _vnode(
          id: 'c',
          type: NodeVisualType.chipSet,
          params: const {'items': ['C']},
          vis: NodeVis.public),
    ];
    // Public surface: the aggregate holds A + C only, never B.
    await tester.pumpWidget(
        _hostSection(nodes, surface: NodeVisualiserSurface.publicProfile));
    expect(find.text('A'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('B'), findsNothing);
  });

  // --- DELETE drops a node from the aggregate in the same pass --------------

  testWidgets('removing a node drops it from the chip aggregate', (tester) async {
    List<StoryNode> nodes(bool withJazz) => [
          _vnode(
              id: 'a',
              type: NodeVisualType.chipSet,
              params: const {'items': ['Climbing']}),
          if (withJazz)
            _vnode(
                id: 'b',
                type: NodeVisualType.chipSet,
                params: const {'items': ['Jazz']}),
          _vnode(
              id: 'c',
              type: NodeVisualType.chipSet,
              params: const {'items': ['Ramen']}),
        ];
    await tester.pumpWidget(_hostSection(nodes(true)));
    expect(find.text('Jazz'), findsOneWidget);
    // Re-render the same section with the node removed (a delete pass).
    await tester.pumpWidget(_hostSection(nodes(false)));
    expect(find.text('Jazz'), findsNothing);
    expect(find.text('Climbing'), findsOneWidget);
    expect(find.text('Ramen'), findsOneWidget);
  });

  testWidgets('removing a node drops it from the timeline aggregate',
      (tester) async {
    List<StoryNode> nodes(bool withMid) => [
          _vnode(
              id: 'a',
              type: NodeVisualType.timelineEntry,
              params: const {'date': '2019', 'title': 'Early'}),
          if (withMid)
            _vnode(
                id: 'b',
                type: NodeVisualType.timelineEntry,
                params: const {'date': '2021', 'title': 'Middle'}),
          _vnode(
              id: 'c',
              type: NodeVisualType.timelineEntry,
              params: const {'date': '2023', 'title': 'Recent'}),
        ];
    await tester.pumpWidget(_hostSection(nodes(true)));
    expect(find.byKey(const Key('node_timeline_b')), findsOneWidget);
    await tester.pumpWidget(_hostSection(nodes(false)));
    expect(find.byKey(const Key('node_timeline_b')), findsNothing);
    expect(find.byKey(const Key('node_timeline_a')), findsOneWidget);
    expect(find.byKey(const Key('node_timeline_c')), findsOneWidget);
  });

  // --- layout matrix: every visual renders overflow-free at every size -------

  testWidgets('the palette mix renders with ZERO overflow at every size',
      (tester) async {
    // A founder-shaped section mixing every text-based palette visual, with
    // deliberately LONG strings so a narrow phone / 2.0 text scale / RTL is the
    // real stress. (photo_carousel is covered by the carousel matrix test.)
    const long =
        'A deliberately long label that must wrap rather than run off the edge '
        'of a narrow phone at a large text scale in either text direction';
    final nodes = [
      _vnode(
          id: 'chips',
          type: NodeVisualType.chipSet,
          params: const {
            'items': ['Climbing', 'Jazz', 'Ramen', 'Long-distance cycling', long]
          }),
      _vnode(
          id: 'tl1',
          type: NodeVisualType.timelineEntry,
          params: {'date': '2019-01', 'title': long}),
      _vnode(
          id: 'tl2',
          type: NodeVisualType.timelineEntry,
          params: const {'date': '2023-11', 'title': 'Recent role'}),
      _vnode(
          id: 'bar',
          type: NodeVisualType.barMeter,
          params: {'value': 84.0, 'min': 0.0, 'max': 100.0, 'label': long}),
      _vnode(
          id: 'gauge',
          type: NodeVisualType.gauge,
          params: const {'value': 6.0, 'min': 0.0, 'max': 10.0, 'label': 'Energy'}),
      _vnode(
          id: 'card',
          type: NodeVisualType.card,
          params: {'title': long, 'body': '$long $long'}),
      _vnode(
          id: 'table',
          type: NodeVisualType.smallTable,
          params: {
            'columns': ['Trait', 'You', 'Them'],
            'rows': [
              [long, 'High', 'Medium'],
              ['Warmth', 'High', 'High'],
            ],
          }),
      _vnode(id: 'gist', type: 'unknown_future', text: long, gist: long),
    ];
    await expectLayoutRobust(
      tester,
      () => Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: NodeVisualiserSection(
              section: GraphTreeSection(
                  pageType: 'identity', title: 'About', order: 0, nodes: nodes),
              surface: NodeVisualiserSurface.story,
            ),
          ),
        ),
      ),
    );
  });
}
