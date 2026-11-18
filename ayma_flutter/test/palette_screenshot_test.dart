// Screenshot evidence for Part 2 (less-text-heavy program): renders a
// founder-shaped section through the VISUAL palette — a chip set, a timeline, a
// bar + gauge, a finding card, a small table and a gist row — and writes the
// rendered frame to `test/goldens/palette_mix.png`. This is the "visuals, not
// text rows" proof the program is about. Run with `flutter test
// test/palette_screenshot_test.dart`; the PNG is regenerated in place.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

StoryNode _vnode({
  required String id,
  required String type,
  Map<String, dynamic> params = const {},
  String text = '',
  String gist = '',
}) =>
    StoryNode(
      id: id,
      section: 'identity',
      label: '',
      text: text,
      gist: gist,
      answerType: 'narrative',
      level: 1,
      visibility: NodeVis.public,
      subtreeVisibility: NodeVis.public,
      standard: false,
      editable: true,
      visual: NodeVisual(type: type, params: params),
    );

void main() {
  testWidgets('render the palette mix and save a screenshot', (tester) async {
    final nodes = [
      _vnode(
          id: 'interests',
          type: NodeVisualType.chipSet,
          params: const {
            'items': ['Rock climbing', 'Jazz', 'Ramen', 'Film photography']
          }),
      _vnode(
          id: 'career1',
          type: NodeVisualType.timelineEntry,
          params: const {
            'date': '2021-06',
            'title': 'Senior engineer at Acme'
          }),
      _vnode(
          id: 'career2',
          type: NodeVisualType.timelineEntry,
          params: const {'date': '2018-09', 'title': 'Engineer at Globex'}),
      _vnode(
          id: 'match',
          type: NodeVisualType.barMeter,
          params: const {
            'value': 84.0,
            'min': 0.0,
            'max': 100.0,
            'label': 'Match score'
          }),
      _vnode(
          id: 'energy',
          type: NodeVisualType.gauge,
          params: const {
            'value': 7.0,
            'min': 0.0,
            'max': 10.0,
            'label': 'Energy'
          }),
      _vnode(
          id: 'finding',
          type: NodeVisualType.card,
          params: const {
            'title': 'Warm and direct',
            'body': 'Communicates clearly and makes others feel at ease.'
          }),
      _vnode(
          id: 'traits',
          type: NodeVisualType.smallTable,
          params: const {
            'columns': ['Trait', 'You', 'Them'],
            'rows': [
              ['Openness', 'High', 'High'],
              ['Warmth', 'High', 'Medium'],
            ],
          }),
      _vnode(
          id: 'note',
          type: NodeVisualType.gistRow,
          gist: 'Looking for something real, not a swipe game.'),
    ];

    const w = 390.0, h = 1180.0;
    final boundaryKey = GlobalKey();
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(w, h);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          extensions: const [AymaTokens.light],
          scaffoldBackgroundColor: const Color(0xFFFDFBF7),
        ),
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            // A fixed-size surface so the capture is the whole page, not the
            // intrinsic content box.
            child: SizedBox(
              width: w,
              height: h,
              child: Material(
                color: const Color(0xFFFDFBF7),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: NodeVisualiserSection(
                      section: GraphTreeSection(
                          pageType: 'identity',
                          title: 'About',
                          order: 0,
                          nodes: nodes),
                      surface: NodeVisualiserSurface.story,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = boundaryKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
    // toImage + toByteData + write are REAL async and must run inside one
    // runAsync block (the mirror of test/image_viewer_test.dart), else they
    // never complete under the fake clock and the test hangs in teardown.
    final file = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = Directory('test/goldens');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('test/goldens/palette_mix.png');
      await f.writeAsBytes(bytes!.buffer.asUint8List());
      return f;
    });
    expect(file!.existsSync(), isTrue);
    // ignore: avoid_print
    print('palette screenshot: ${file.absolute.path}');
  });
}
