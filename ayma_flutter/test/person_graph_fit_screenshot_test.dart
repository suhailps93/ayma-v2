// Acceptance screenshot for the person-graph layout fix (founder build 2491).
// Pumps the REAL PersonGraphScreen on a founder-shaped graph (centre "You" +
// weighted sections of cross-surface facts + edgeless orphan facts) in
// reduced-motion mode, so the force layout settles and fits synchronously at
// OPEN, then captures the fitted frame to a PNG. The image must show the graph
// fitted, spread and readable — no far "pink streak", no crushed corner blob.
//
// Run: flutter test test/person_graph_fit_screenshot_test.dart
// Output PNG: <repo>/pg_layout_fitted.png (printed at the end).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

PersonGraph _founderGraph() {
  const surfaces = ['story', 'publicProfile', 'report', 'graphDetail'];
  final nodes = <Map<String, dynamic>>[
    {'id': 'me', 'kind': 'person', 'label': 'You'},
  ];
  final edges = <Map<String, dynamic>>[];
  // Varied section fan-out, like the founder's real graph.
  const fans = [14, 11, 9, 7, 6, 5, 4, 8, 3, 6, 4, 3];
  for (var s = 0; s < fans.length; s++) {
    final sec = 'sec$s';
    nodes.add({'id': sec, 'kind': 'section', 'label': 'Section $s'});
    edges.add({'from': 'me', 'to': sec});
    for (var i = 0; i < fans[s]; i++) {
      final surf = surfaces[i % surfaces.length];
      final leaf = '$sec.$surf.$i';
      nodes.add({'id': leaf, 'kind': surf == 'report' ? 'report' : 'bullet', 'text': 'fact $i'});
      edges.add({'from': sec, 'to': leaf});
      if (i % 8 == 3) {
        nodes.add({'id': '$leaf.sub', 'kind': 'bullet', 'text': 'sub'});
        edges.add({'from': leaf, 'to': '$leaf.sub'});
      }
    }
  }
  // Edgeless cross-surface facts (the bug trigger): present but unlinked.
  for (var k = 0; k < 5; k++) {
    nodes.add({'id': 'orphan$k', 'kind': 'bullet', 'text': 'unlinked $k'});
  }
  return PersonGraph.fromMap({
    'center': {'id': 'me', 'label': 'You'},
    'sections': const [],
    'nodes': nodes,
    'edges': edges,
  });
}

class _FakeApi extends ApiClient {
  _FakeApi() : super(auth: MockFirebaseAuth(signedIn: true));
  @override
  Future<PersonGraph> profileGraph({String? uid}) async => _founderGraph();
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      GraphTree.fromMap({'surface': 'graphDetail', 'sections': const []});
}

void main() {
  testWidgets('person graph opens fitted, spread and readable (screenshot)',
      (tester) async {
    tester.view.physicalSize = const Size(420, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: RepaintBoundary(
            key: const Key('shot'),
            child: PersonGraphScreen(api: _FakeApi()),
          ),
        ),
      ),
    ));
    // Load the graph, then run the reduced-motion settle + fit (postFrame).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('shot')));

    late final String path;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory.current.path; // ayma_flutter
      path = '$dir/pg_layout_fitted.png';
      File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(File(path).existsSync(), isTrue);
    // ignore: avoid_print
    print('SCREENSHOT: $path');
  });
}
