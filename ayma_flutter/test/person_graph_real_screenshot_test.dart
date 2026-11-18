// Acceptance screenshots on the FOUNDER'S REAL graph (uid iWhWjiWh…, read-only
// dump of ayma-staging): 122 nodes / 121 edges, dominated by one sec:assessment
// hub with 96 degree-1 children. The pre-fix sim explodes this to ~1e6 coords
// (knot + comet tail); the fix must render it as an organic mesh that fits.
//
// Env var AYMA_SHOT_PATH chooses the output file so the same test renders the
// BEFORE (pre-fix, via git stash) and AFTER frames to different paths.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/screens/person_graph_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/founder_real_graph.dart';

PersonGraph _realGraph() {
  final nodes = [
    for (final n in founderRealNodes)
      {'id': n[0], 'kind': n[1], 'label': n[0], 'text': ''}
  ];
  final edges = [
    for (final e in founderRealEdges) {'from': e[0], 'to': e[1]}
  ];
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
  Future<PersonGraph> profileGraph({String? uid}) async => _realGraph();
  @override
  Future<GraphTree> graphTree({String? uid, String surface = 'story'}) async =>
      GraphTree.fromMap({'surface': 'graphDetail', 'sections': const []});
}

void main() {
  testWidgets('founder real graph renders as a fitted mesh (screenshot)',
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
    final path = Platform.environment['AYMA_SHOT_PATH'] ??
        '${Directory.current.path}/pg_real_after.png';
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    expect(File(path).existsSync(), isTrue);
    // ignore: avoid_print
    print('SCREENSHOT: $path');
  });
}
