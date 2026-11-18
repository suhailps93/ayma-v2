import 'dart:io';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/ayma_session.dart';
import 'package:ayma_flutter/widgets/ask_ayma_context.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
import 'package:ayma_flutter/widgets/node_chat_window.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCacheManager implements BaseCacheManager {
  _FakeCacheManager(File ioFile)
      : file = const LocalFileSystem().file(ioFile.path);

  final fs.File file;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    yield FileInfo(
      file,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 1)),
      url,
    );
  }

  @override
  Future<fs.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async =>
      file;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));

  final List<(String, String)> visibilitySet = [];
  final List<(String, String)> addChildCalls = [];
  final List<String> deleted = [];
  int deleteCountToReturn = 0;

  @override
  Future<int> graphNodeSetVisibility(String nodeId, String visibility) async {
    visibilitySet.add((nodeId, visibility));
    return 1;
  }

  @override
  Future<String> graphAddChild(
    String parentId,
    String label, {
    String answer = '',
    String visibility = 'private',
  }) async {
    addChildCalls.add((parentId, label));
    return 'new_id';
  }

  @override
  Future<int> graphDeleteCount(String nodeId) async => deleteCountToReturn;

  @override
  Future<int> graphDeleteNode(String nodeId) async {
    deleted.add(nodeId);
    return 1;
  }
}

StoryNode _node({
  required String id,
  String label = '',
  String text = '',
  String vis = NodeVis.private,
  String subtree = '',
  bool standard = false,
  String? standardLabel,
  String answerType = 'narrative',
  String imageUrl = '',
  String imageRead = '',
  String isYou = 'unknown',
  bool editable = true,
  int level = 1,
  List<StoryNode> children = const [],
}) =>
    StoryNode(
      id: id,
      section: 'identity',
      label: label,
      text: text,
      answerType: answerType,
      level: level,
      visibility: vis,
      subtreeVisibility: subtree.isEmpty ? vis : subtree,
      standard: standard,
      standardLabel: standardLabel,
      editable: editable,
      imageUrl: imageUrl,
      imageRead: imageRead,
      isYou: isYou,
      children: children,
    );

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
      theme: theme ?? ThemeData(useMaterial3: true),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  // The partial node chat is the one shared ChatScreen against the session
  // store; seed it so opening the overlay never reaches for server history.
  setUp(() => AymaSession.instance.store.seed(const []));

  // A node that renders UNDER A TRUE PARENT still indents one step per real
  // parent level (depth under its parent), regardless of stored `level`.
  testWidgets('nested tree indents children by TRUE parentage', (tester) async {
    final tree = _node(
      id: 'root',
      text: 'Root',
      children: [
        _node(
          id: 'child',
          text: 'Child',
          // Stale/absent level must not matter: a real child still indents by
          // its depth under the parent, not by its own `level`.
          level: 1,
          children: [_node(id: 'grand', text: 'Grand', level: 1)],
        ),
      ],
    );
    await tester.pumpWidget(_host(
      NodeVisualiser(node: tree, surface: NodeVisualiserSurface.story),
    ));

    final rootX = tester.getTopLeft(find.text('Root')).dx;
    final childX = tester.getTopLeft(find.text('Child')).dx;
    final grandX = tester.getTopLeft(find.text('Grand')).dx;
    expect(childX, greaterThan(rootX));
    expect(grandX, greaterThan(childX));
  });

  // REGRESSION (founder build 2495, "this indentation does not make sense"):
  // his About Me free bullets are parentless level-2 facts (the Your Story
  // editor / content writers mint them at level 2 with NO parent), so they
  // render as flat SECTION ROOTS. The old renderer floored the indent at
  // `level-1`, so each one sat one step in and read as a child of the level-1
  // standard item above it ("Interested in"). A section member must now render
  // FLUSH at the section base no matter its stored level.
  testWidgets(
      'REGRESSION: parentless level-2 section members render FLUSH at base '
      'level, not indented under the standard item above', (tester) async {
    final section = GraphTreeSection(
      pageType: 'identity',
      title: 'About Me',
      order: 0,
      nodes: [
        _node(
          id: 'interested',
          text: 'Women',
          standard: true,
          standardLabel: 'Interested in',
          level: 1,
        ),
        // The founder's circled parentless facts, stored at level 2.
        _node(id: 'emergent.story.5c5470d1', text: 'Gender identity', level: 2),
        _node(id: 'emergent.editor.identity.5', text: 'Born in Dubai', level: 2),
        _node(id: 'emergent.story.b7aba075', text: 'Lives in San Jose', level: 2),
      ],
    );
    await tester.pumpWidget(_host(
      NodeVisualiserSection(
        section: section,
        surface: NodeVisualiserSurface.story,
      ),
    ));

    final baseX = tester.getTopLeft(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == 'Interested in: Women',
      ),
    ).dx;
    for (final t in ['Gender identity', 'Born in Dubai', 'Lives in San Jose']) {
      expect(tester.getTopLeft(find.text(t)).dx, equals(baseX),
          reason: '"$t" must sit flush at the section base, not indented');
    }
  });

  // All six fixed About Me standard items render at the section base in the
  // fixed canonical order (Name, Age, Gender, Location, Interested in, Ethnic &
  // cultural origin) — none indented, none out of order. The backend orders
  // them; the renderer must keep them flush.
  testWidgets('six fixed About Me standard items render flush, in fixed order',
      (tester) async {
    StoryNode std(String id, String label, String value) => _node(
          id: id,
          text: value,
          standard: true,
          standardLabel: label,
          level: 1,
          vis: NodeVis.public,
        );
    final section = GraphTreeSection(
      pageType: 'identity',
      title: 'About Me',
      order: 0,
      nodes: [
        std('legal_first_name', 'Name', 'Sam'),
        std('date_of_birth', 'Age', '33'),
        std('gender_identity', 'Gender', 'Man'),
        std('primary_location', 'Location', 'San Jose'),
        std('target_match_genders', 'Interested in', 'Women'),
        std('ethnic_cultural_origin', 'Ethnic & cultural origin', 'South Asian'),
      ],
    );
    await tester.pumpWidget(_host(
      NodeVisualiserSection(
        section: section,
        surface: NodeVisualiserSurface.story,
      ),
    ));

    double fieldX(String label, String value) => tester.getTopLeft(
          find.byWidgetPredicate((w) =>
              w is RichText && w.text.toPlainText() == '$label: $value'),
        ).dx;
    double fieldY(String label, String value) => tester.getTopLeft(
          find.byWidgetPredicate((w) =>
              w is RichText && w.text.toPlainText() == '$label: $value'),
        ).dy;

    final rows = [
      ('Name', 'Sam'),
      ('Age', '33'),
      ('Gender', 'Man'),
      ('Location', 'San Jose'),
      ('Interested in', 'Women'),
      ('Ethnic & cultural origin', 'South Asian'),
    ];
    final baseX = fieldX(rows.first.$1, rows.first.$2);
    double? prevY;
    for (final (label, value) in rows) {
      expect(fieldX(label, value), equals(baseX),
          reason: '"$label" must render flush at the section base');
      final y = fieldY(label, value);
      final prev = prevY;
      if (prev != null) {
        expect(y, greaterThan(prev),
            reason: '"$label" must follow the one before it in fixed order');
      }
      prevY = y;
    }
  });

  // Deep nesting (past the indent cap) must never push a row off a narrow phone
  // at the largest text scale — the indent caps and the content text wraps,
  // in both text directions (RTL indents from the right).
  testWidgets('deep nesting never overflows at 320px / text-scale 2.0',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const longText =
        'A deeply nested conversational fact with enough words that it must '
        'wrap rather than run off the side of a narrow phone at a large scale';
    // 8 levels — well past the indent cap, to prove the cap keeps content on.
    StoryNode chain(int level) => _node(
          id: 'n$level',
          text: '$longText (level $level)',
          level: level,
          children: level >= 8 ? const [] : [chain(level + 1)],
        );

    for (final rtl in [false, true]) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Scaffold(
            body: SingleChildScrollView(
              child: NodeVisualiser(
                node: chain(1),
                surface: NodeVisualiserSurface.story,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'rtl=$rtl');
    }
  });

  // REGRESSION (founder build 2495, "no text should cut off partially"): a gist
  // / bullet line WRAPS to its full length — it is NEVER hard-truncated with an
  // ellipsis mid-sentence. The row has no maxLines / ellipsis cap on body text.
  testWidgets('REGRESSION: a long gist renders in FULL, no ellipsis '
      '(visualiser)', (tester) async {
    const longGist =
        'He completed a Master of Science in Color Science under a joint '
        'program and now leads a research team based in San Jose California';
    final node = _node(id: 'g1', text: longGist, vis: NodeVis.public);
    await tester.pumpWidget(_host(
      NodeVisualiser(node: node, surface: NodeVisualiserSurface.story),
    ));
    final text = tester.widget<Text>(find.text(longGist));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    // The full sentence is laid out (no "…"): its painted size spans >1 line.
    expect(find.text(longGist), findsOneWidget);
  });

  testWidgets('REGRESSION: a long gist renders in FULL, no ellipsis '
      '(report section)', (tester) async {
    const longGist =
        'The pair completed a shared research fellowship in Color Science and '
        'both now mentor undergraduates, a strong signal of aligned values';
    final section = GraphTreeSection(
      pageType: 'summary',
      title: 'Summary',
      order: 0,
      nodes: [_node(id: 'r1', text: longGist, vis: NodeVis.public)],
    );
    await tester.pumpWidget(_host(
      NodeVisualiserSection(
        section: section,
        surface: NodeVisualiserSurface.report,
        cardStyle: true,
      ),
    ));
    final text = tester.widget<Text>(find.text(longGist));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
  });

  testWidgets('a long gist never overflows at 320px / text-scale 2.0 even '
      'without an ellipsis cap', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const longGist =
        'A genuinely long conversational fact that must wrap down the screen '
        'rather than run off the side or be chopped by an ellipsis at a scale';
    await tester.pumpWidget(_host(
      NodeVisualiser(
        node: _node(id: 'g2', text: longGist, vis: NodeVis.public),
        surface: NodeVisualiserSurface.story,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // REGRESSION (founder build 2495): the Confidence row's "High" value lays out
  // INLINE with its label — not as a right-anchored chip floating over the card
  // border. It renders cleanly (no overflow) even at a narrow width.
  testWidgets('REGRESSION: confidence band lays out inline, no overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final node = StoryNode(
      id: 'conf', section: 'summary', label: 'Confidence', text: 'Confidence',
      answerType: 'stat', level: 1,
      visibility: NodeVis.public, subtreeVisibility: NodeVis.public,
      standard: false, editable: false, statText: 'High',
    );
    await tester.pumpWidget(_host(
      NodeVisualiserSection(
        section: GraphTreeSection(
          pageType: 'summary', title: 'Summary', order: 0, nodes: [node]),
        surface: NodeVisualiserSurface.report,
        cardStyle: true,
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('node_band_conf')), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    // The band sits to the RIGHT of (after) the label, inline — not overlapping.
    final labelRight = tester.getBottomRight(find.text('Confidence')).dx;
    final bandLeft = tester.getTopLeft(find.byKey(const Key('node_band_conf'))).dx;
    expect(bandLeft, greaterThanOrEqualTo(labelRight));
  });

  testWidgets('standard node renders as a labelled field, first', (tester) async {
    final section = GraphTreeSection(
      pageType: 'identity',
      title: 'About Me',
      order: 0,
      nodes: [
        _node(
          id: 'legal_first_name',
          text: 'Sam',
          standard: true,
          standardLabel: 'Name',
          vis: NodeVis.public,
        ),
        _node(id: 'conv', text: 'Loves hiking', vis: NodeVis.public),
      ],
    );
    await tester.pumpWidget(_host(
      NodeVisualiserSection(
        section: section,
        surface: NodeVisualiserSurface.story,
      ),
    ));
    // the standard label renders as a labelled field "Name: Sam" (a RichText)
    final nameField = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == 'Name: Sam',
    );
    expect(nameField, findsOneWidget);
    expect(find.text('Sam'), findsNothing); // 'Sam' is inside the RichText span
    // standard node (Name) sits above the conversational node
    final nameY = tester.getTopLeft(nameField).dy;
    final convY = tester.getTopLeft(find.text('Loves hiking')).dy;
    expect(nameY, lessThan(convY));
  });

  testWidgets('public profile filters out private nodes (story shows them)',
      (tester) async {
    StoryNode build() => _node(
          id: 'root',
          text: 'Public root',
          vis: NodeVis.public,
          subtree: NodeVis.mixed,
          children: [
            _node(id: 'priv', text: 'Private child', vis: NodeVis.private),
          ],
        );

    await tester.pumpWidget(_host(
      NodeVisualiser(node: build(), surface: NodeVisualiserSurface.story),
    ));
    expect(find.text('Private child'), findsOneWidget);

    await tester.pumpWidget(_host(
      NodeVisualiser(
          node: build(), surface: NodeVisualiserSurface.publicProfile),
    ));
    expect(find.text('Private child'), findsNothing);
    expect(find.text('Public root'), findsOneWidget);
  });

  testWidgets(
      'REGRESSION (founder path): one tap on a Story node opens the partial '
      'chat directly with the node attached, no intermediate "Chat about it" '
      'card, owner bubbles inside the chat', (tester) async {
    final api = _FakeApi();
    final node = _node(id: 'n1', text: 'A fact', vis: NodeVis.private);
    await tester.pumpWidget(_host(
      NodeVisualiser(
        node: node,
        surface: NodeVisualiserSurface.story,
        api: api,
      ),
    ));
    await tester.tap(find.byKey(const Key('node_row_n1')));
    await tester.pumpAndSettle();

    // Straight into the REAL partial Ayma chat (the one shared ChatScreen),
    // scoped to this node — not an intermediate card.
    expect(find.byType(ChatScreen), findsOneWidget);
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.askAymaContext?.origin, AskAymaOrigin.graphNode);
    expect(chat.askAymaContext?.nodeId, 'n1');
    // The node is pinned as the persistent context card above the composer.
    expect(find.text('A fact'), findsWidgets);
    // The deleted intermediate card's "Chat about it" bubble/step is gone.
    expect(find.byKey(const Key('bubble_chat_about')), findsNothing);
    expect(find.text('Chat about it'), findsNothing);
    // Owner actions ride inside the chat as the pinned bubble row.
    expect(find.byKey(const Key('bubble_visibility')), findsOneWidget);
    expect(find.byKey(const Key('bubble_delete')), findsOneWidget);
  });

  testWidgets('read-only surfaces expose NO edit bubbles on a node tap',
      (tester) async {
    // Non-editable report node (owner): chat opens, but no edit bubbles.
    final api = _FakeApi();
    final report = _node(
        id: 'r1', text: 'Reported insight', vis: NodeVis.public,
        editable: false);
    await tester.pumpWidget(_host(
      NodeVisualiser(
          node: report, surface: NodeVisualiserSurface.report, api: api),
    ));
    await tester.tap(find.byKey(const Key('node_row_r1')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byKey(const Key('bubble_visibility')), findsNothing);
    expect(find.byKey(const Key('bubble_delete')), findsNothing);
    expect(find.byKey(const Key('bubble_chat_about')), findsNothing);
  });

  testWidgets('public-profile non-owner node tap exposes no edit bubbles',
      (tester) async {
    final api = _FakeApi();
    final node = _node(id: 'n', text: 'Public fact', vis: NodeVis.public);
    await tester.pumpWidget(_host(
      NodeVisualiser(
        node: node,
        surface: NodeVisualiserSurface.publicProfile,
        api: api,
        isOwner: false,
      ),
    ));
    await tester.tap(find.byKey(const Key('node_row_n')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byKey(const Key('bubble_delete')), findsNothing);
    expect(find.byKey(const Key('bubble_visibility')), findsNothing);
  });

  testWidgets('nodeHasOwnerActions gates the edit bubbles', (tester) async {
    final editable = _node(id: 'a', text: 'x');
    final readonly = _node(id: 'b', text: 'x', editable: false);
    // Owner + editable + an editing surface → bubbles.
    expect(
        nodeHasOwnerActions(editable, NodeVisualiserSurface.story, true), isTrue);
    expect(nodeHasOwnerActions(editable, NodeVisualiserSurface.report, true),
        isTrue);
    expect(nodeHasOwnerActions(editable, NodeVisualiserSurface.graphDetail, true),
        isTrue);
    // Public profile, non-owner, or non-editable → none.
    expect(
        nodeHasOwnerActions(editable, NodeVisualiserSurface.publicProfile, true),
        isFalse);
    expect(
        nodeHasOwnerActions(editable, NodeVisualiserSurface.story, false), isFalse);
    expect(nodeHasOwnerActions(readonly, NodeVisualiserSurface.story, true),
        isFalse);
  });

  testWidgets('bubble: Make public wires the real action + fires onChanged',
      (tester) async {
    final api = _FakeApi();
    var changed = 0;
    await tester.pumpWidget(_host(
      NodeActionBubbles(
        node: _node(id: 'n1', text: 'A fact', vis: NodeVis.private),
        api: api,
        onChanged: () => changed++,
      ),
    ));
    // private node → bubble offers "Make public"
    expect(find.text('Make public'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bubble_visibility')));
    await tester.pumpAndSettle();
    expect(api.visibilitySet, [('n1', NodeVis.public)]);
    expect(changed, 1);
    // label flips after the toggle
    expect(find.text('Make private'), findsOneWidget);
  });

  testWidgets('bubble: delete names the children count and wires the real '
      'delete + fires onChanged', (tester) async {
    final api = _FakeApi()..deleteCountToReturn = 2;
    var changed = 0;
    await tester.pumpWidget(_host(
      NodeActionBubbles(
        node: _node(id: 'p', text: 'Parent', vis: NodeVis.private),
        api: api,
        onChanged: () => changed++,
      ),
    ));
    await tester.tap(find.byKey(const Key('bubble_delete')));
    await tester.pumpAndSettle();
    // confirmation names the 2 children
    expect(find.textContaining('2 lines'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.deleted, ['p']);
    expect(changed, 1);
  });

  testWidgets('bubble: add a line wires add-child to this node', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(_host(
      NodeActionBubbles(
        node: _node(id: 'p', text: 'Parent', vis: NodeVis.private),
        api: api,
      ),
    ));
    await tester.tap(find.byKey(const Key('bubble_add_child')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A new detail');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(api.addChildCalls, [('p', 'A new detail')]);
  });

  testWidgets('image node embeds inline; tap opens its context', (tester) async {
    AymaPhoto.debugCacheManager =
        _FakeCacheManager(File('test/fixtures/tiny.png'));
    addTearDown(() => AymaPhoto.debugCacheManager = null);

    final api = _FakeApi();
    final img = _node(
      id: 'img1',
      answerType: 'image',
      imageUrl: 'https://x/p.jpg',
      imageRead: 'A person smiling',
      isYou: 'yes',
      vis: NodeVis.public,
    );
    await tester.pumpWidget(_host(
      NodeVisualiser(
        node: img,
        surface: NodeVisualiserSurface.story,
        api: api,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node_image_img1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('node_row_img1')));
    await tester.pumpAndSettle();
    // Straight into the partial chat, scoped to the image node.
    final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
    expect(chat.askAymaContext?.origin, AskAymaOrigin.graphNode);
    expect(chat.askAymaContext?.nodeImageUrl, 'https://x/p.jpg');
    // the chat's pinned image context card shows the read + is-you verdict.
    // (the read also appears inline under the image, so it is present twice.)
    expect(find.text('A person smiling'), findsNWidgets(2));
    expect(find.textContaining('looks like you'), findsOneWidget);
  });

  // --- report node kinds (2o P0) ---

  StoryNode statNode({
    required String id,
    required String label,
    double? value,
    String text = '',
    String basis = '',
  }) =>
      StoryNode(
        id: id,
        section: 'score',
        label: label,
        text: label,
        answerType: 'stat',
        level: 1,
        visibility: NodeVis.public,
        subtreeVisibility: NodeVis.public,
        standard: false,
        editable: false,
        statValue: value,
        statText: text,
        statBasis: basis,
      );

  testWidgets('numeric stat renders its value digit + a ScoreBar + basis',
      (tester) async {
    await tester.pumpWidget(_host(NodeVisualiser(
      node: statNode(
          id: 's1', label: 'Overall', value: 8, basis: '22% weight · measured'),
      surface: NodeVisualiserSurface.report,
      api: _FakeApi(),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Overall'), findsOneWidget);
    expect(find.byKey(const Key('node_stat_value_s1')), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.byKey(const Key('node_stat_bar_s1')), findsOneWidget);
    expect(find.text('22% weight · measured'), findsOneWidget);
    // Non-numeric band pill is NOT shown for a numeric stat.
    expect(find.byKey(const Key('node_band_s1')), findsNothing);
  });

  testWidgets('non-numeric stat renders a confidence band pill, no bar',
      (tester) async {
    await tester.pumpWidget(_host(NodeVisualiser(
      node: statNode(id: 'c1', label: 'Confidence', value: null, text: 'Low'),
      surface: NodeVisualiserSurface.report,
      api: _FakeApi(),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('node_band_c1')), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.byKey(const Key('node_stat_bar_c1')), findsNothing);
  });

  testWidgets('link node renders its label; candidate verdict buttons appear '
      'only when a handler is wired', (tester) async {
    final link = StoryNode(
      id: 'l1', section: 'links', label: 'Jane on X', text: 'Jane on X',
      answerType: 'link', level: 1,
      visibility: NodeVis.public, subtreeVisibility: NodeVis.public,
      standard: false, editable: false,
      linkUrl: 'https://x.com/jane', linkPlatform: 'x',
    );
    await tester.pumpWidget(_host(NodeVisualiser(
      node: link, surface: NodeVisualiserSurface.report, api: _FakeApi(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Jane on X'), findsOneWidget);

    // Candidate without a handler: photo + caption, no buttons.
    final cand = StoryNode(
      id: 'cand1', section: 'photos', label: '', text: 'Found online',
      answerType: 'candidate', level: 1,
      visibility: NodeVis.public, subtreeVisibility: NodeVis.public,
      standard: false, editable: false,
      imageUrl: 'https://site/p.jpg', candidateId: 'abc',
    );
    await tester.pumpWidget(_host(NodeVisualiser(
      node: cand, surface: NodeVisualiserSurface.report, api: _FakeApi(),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node_candidate_me_cand1')), findsNothing);

    // With a handler: "This is me" / "Not me" fire the verdict.
    final verdicts = <bool>[];
    await tester.pumpWidget(_host(NodeVisualiser(
      node: cand, surface: NodeVisualiserSurface.report, api: _FakeApi(),
      onCandidateVerdict: (n, isMe) => verdicts.add(isMe),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('node_candidate_me_cand1')));
    await tester.tap(find.byKey(const Key('node_candidate_notme_cand1')));
    expect(verdicts, [true, false]);
  });
}
