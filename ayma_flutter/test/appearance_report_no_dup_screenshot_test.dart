// Screenshot + structural proof for the founder's build-2495 report defect:
// the Appearance report must not show the same point twice. It now renders
// FINDINGS first (what Ayma sees) and the recommendations ("What to do next")
// as the FINAL section — each point exactly once, the recommendation never
// re-printing the finding it addresses.
//
// The tree below is the exact shape `report_tree.report_node_tree` now emits
// for an Appearance report (findings section first, a single trailing
// `what_to_do_next` section carrying every `role: "recommendation"` node),
// verified cross-language by `functions/bootstrap/tests/test_report_tree.py`.
// This test pumps it through the real `GraphTreeView(surface: report)` and
// writes a PNG so the ordering/no-duplication can be eyeballed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/graph_tree_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _textNode(String id, String text,
        {String role = '', String label = ''}) =>
    {
      'id': id,
      'section': 'face',
      'label': label,
      'text': text,
      'gist': text,
      'answer_type': 'text',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      'editable': true,
      if (role.isNotEmpty) 'role': role,
    };

GraphTree _appearanceTree() => GraphTree.fromMap({
      'surface': 'report',
      'title': 'Appearance',
      'sections': [
        {
          'page_type': 'face',
          'title': 'Face',
          'order': 0,
          'nodes': [
            {
              'id': 'face',
              'section': 'face',
              'label': 'Above average',
              'text': 'Above average',
              'gist': 'Above average',
              'answer_type': 'stat',
              'stat_value': 6.5,
              'stat_text': '6.5',
              'stat_basis': 'Above average',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
              'editable': false,
            },
            _textNode('face:note:sent:0',
                'Strong bone structure let down by grooming.'),
            _textNode('face:improvement:0',
                'Overgrown mustache hanging over the upper lip line'),
            _textNode(
                'face:improvement:1', 'Under-eye fatigue and slight puffiness'),
            _textNode('face:improvement:2', 'Unshaped messy brow contours'),
            _textNode('face:improvement:3',
                'Cheekline and neckline lack clean borders'),
          ],
        },
        {
          'page_type': 'what_to_do_next',
          'title': 'What to do next',
          'order': 1,
          'nodes': [
            _textNode('face:reco:0', 'Trim the mustache clear of the upper lip',
                role: 'recommendation'),
            _textNode('face:reco:1',
                'Introduce a caffeinated eye serum morning and night',
                role: 'recommendation'),
            _textNode(
                'face:reco:2', 'Clean up stray hairs around the brow arches',
                role: 'recommendation'),
            _textNode('face:reco:3',
                'Edge the cheekline and neckline with a trimmer',
                role: 'recommendation'),
          ],
        },
      ],
      'meta': {'owner_uid': 'u1', 'viewer_can_edit': true},
    });

class _FakeApi extends ApiClient {
  _FakeApi(this.tree) : super(auth: MockFirebaseAuth(signedIn: true));
  final GraphTree tree;
  @override
  Future<GraphTree> reportTree(String reportType, String reportId) async =>
      tree;
}

void main() {
  testWidgets('Appearance report: findings first, "What to do next" last, '
      'each point once', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: AymaTheme.light,
      home: Scaffold(
        body: RepaintBoundary(
          key: const Key('report_shot'),
          child: Container(
            width: 440,
            color: const Color(0xFFFFFFFF),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: GraphTreeView(
                surface: NodeVisualiserSurface.report,
                reportType: 'appearance',
                reportId: 'current',
                api: _FakeApi(_appearanceTree()),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The findings render above the actions; no recommendation leaks into the
    // Face section and no finding is re-printed below.
    expect(find.text('Overgrown mustache hanging over the upper lip line'),
        findsOneWidget);
    expect(
        find.text('Trim the mustache clear of the upper lip'), findsOneWidget);
    expect(find.text('What to do next'), findsOneWidget);

    // "What to do next" sits below every finding (greater dy).
    final findingY = tester
        .getTopLeft(
            find.text('Cheekline and neckline lack clean borders'))
        .dy;
    final actionsY = tester.getTopLeft(find.text('What to do next')).dy;
    expect(actionsY, greaterThan(findingY));

    // Save the PNG. toImage/toByteData are real async — they must run outside
    // the test's fake-async zone via runAsync, or the suite hangs to timeout.
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('report_shot')));
    final out =
        File('${Directory.systemTemp.path}/appearance_report_no_dup.png');
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      out.writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(out.existsSync(), isTrue);
    // ignore: avoid_print
    print('SCREENSHOT:${out.path}');
  });
}
