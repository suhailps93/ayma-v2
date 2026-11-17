import 'dart:io';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/ayma_photo.dart';
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
  testWidgets('nested tree indents children by level', (tester) async {
    final tree = _node(
      id: 'root',
      text: 'Root',
      children: [
        _node(
          id: 'child',
          text: 'Child',
          level: 2,
          children: [_node(id: 'grand', text: 'Grand', level: 3)],
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

  testWidgets('tap opens chat window; Make public wires the real action',
      (tester) async {
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

    expect(find.byKey(const Key('bubble_visibility')), findsOneWidget);
    expect(find.byKey(const Key('bubble_delete')), findsOneWidget);
    // private node → bubble offers "Make public"
    await tester.tap(find.byKey(const Key('bubble_visibility')));
    await tester.pumpAndSettle();
    expect(api.visibilitySet, [('n1', NodeVis.public)]);
  });

  testWidgets('every owner surface shows "Chat about it"; a non-editable '
      'report node shows it but no edit bubbles', (tester) async {
    // Editable story node: chat-about rides alongside the edit bubbles.
    final api = _FakeApi();
    final story = _node(id: 's1', text: 'A fact', vis: NodeVis.private);
    await tester.pumpWidget(_host(
      NodeVisualiser(
          node: story, surface: NodeVisualiserSurface.story, api: api),
    ));
    await tester.tap(find.byKey(const Key('node_row_s1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bubble_chat_about')), findsOneWidget);
    expect(find.byKey(const Key('bubble_visibility')), findsOneWidget);
    // dismiss the sheet
    Navigator.of(tester.element(find.byKey(const Key('bubble_chat_about'))))
        .pop();
    await tester.pumpAndSettle();

    // Non-editable report node: "Chat about it" still works; no edit bubbles.
    final report = _node(
        id: 'r1', text: 'Reported insight', vis: NodeVis.public,
        editable: false);
    await tester.pumpWidget(_host(
      NodeVisualiser(
          node: report, surface: NodeVisualiserSurface.report, api: api),
    ));
    await tester.tap(find.byKey(const Key('node_row_r1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bubble_chat_about')), findsOneWidget);
    expect(find.byKey(const Key('bubble_visibility')), findsNothing);
    expect(find.byKey(const Key('bubble_delete')), findsNothing);
    // never a dead "Ask Ayma about this" with no action
    expect(find.text('Ask Ayma about this'), findsNothing);
  });

  testWidgets('delete names the children count and wires the real delete',
      (tester) async {
    final api = _FakeApi()..deleteCountToReturn = 2;
    final node = _node(id: 'p', text: 'Parent', vis: NodeVis.private);
    await tester.pumpWidget(_host(
      NodeVisualiser(
        node: node,
        surface: NodeVisualiserSurface.story,
        api: api,
      ),
    ));
    await tester.tap(find.byKey(const Key('node_row_p')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bubble_delete')));
    await tester.pumpAndSettle();
    // confirmation names the 2 children
    expect(find.textContaining('2 lines'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.deleted, ['p']);
  });

  testWidgets('add a line wires add-child to this node', (tester) async {
    final api = _FakeApi();
    final node = _node(id: 'p', text: 'Parent', vis: NodeVis.private);
    await tester.pumpWidget(_host(
      NodeVisualiser(
        node: node,
        surface: NodeVisualiserSurface.story,
        api: api,
      ),
    ));
    await tester.tap(find.byKey(const Key('node_row_p')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bubble_add_child')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'A new detail');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(api.addChildCalls, [('p', 'A new detail')]);
  });

  testWidgets('public profile node has no owner action bubbles', (tester) async {
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
    expect(find.byKey(const Key('bubble_delete')), findsNothing);
    expect(find.byKey(const Key('bubble_visibility')), findsNothing);
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
    // the node chat window's context card shows the read + is-you verdict.
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
