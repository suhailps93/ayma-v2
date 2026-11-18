// Screenshot evidence for the build-2495 founder batch (fleet/story-section-
// indent-fix). Renders founder-shaped data through the ONE NodeVisualiser and
// writes PNGs proving all three fixes:
//   (a) section members render FLUSH at the section base — a parentless level-2
//       fact is NOT indented under the standard item above it;
//   (b) plain prose facts render as BULLET POINTS, never grey card/chip bubbles;
//   (c) gist/bullet text WRAPS in full with no mid-sentence ellipsis, and the
//       report Confidence row lays its band out INLINE (no floating chip).
// Run: `flutter test test/story_section_indent_screenshot_test.dart`; the PNGs
// are regenerated in place under test/goldens/.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/theme.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

StoryNode _standard(String id, String label, String value) => StoryNode(
      id: id,
      section: 'identity',
      label: label,
      text: value,
      answerType: 'narrative',
      level: 1,
      visibility: NodeVis.public,
      subtreeVisibility: NodeVis.public,
      standard: true,
      standardLabel: label,
      editable: true,
      // A standard field is a labelled gist_row — never a bubble.
      visual: const NodeVisual(type: NodeVisualType.gistRow),
    );

// A parentless free bullet stored at LEVEL 2 (the Your Story editor / content
// writers mint these) — the founder's circled facts. gist_row = a bullet.
StoryNode _freeBullet(String id, String text) => StoryNode(
      id: id,
      section: 'identity',
      label: '',
      text: text,
      gist: text,
      answerType: 'narrative',
      level: 2,
      visibility: NodeVis.public,
      subtreeVisibility: NodeVis.public,
      standard: false,
      editable: true,
      visual: const NodeVisual(type: NodeVisualType.gistRow),
    );

Future<File> _capture(
  WidgetTester tester,
  String path, {
  required double width,
  required double height,
  required Widget child,
}) async {
  final boundaryKey = GlobalKey();
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
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
          child: SizedBox(
            width: width,
            height: height,
            child: Material(
              color: const Color(0xFFFDFBF7),
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final boundary =
      boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final file = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('test/goldens');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File(path);
    await f.writeAsBytes(bytes!.buffer.asUint8List());
    return f;
  });
  expect(file!.existsSync(), isTrue);
  return file;
}

void main() {
  testWidgets('About Me: standard items first, free bullets flush, no bubbles',
      (tester) async {
    final section = GraphTreeSection(
      pageType: 'identity',
      title: 'About Me',
      order: 0,
      nodes: [
        _standard('legal_first_name', 'Name', 'Suhail'),
        _standard('date_of_birth', 'Age', '28'),
        _standard('gender_identity', 'Gender', 'Man'),
        _standard('primary_location', 'Location', 'San Jose'),
        _standard('target_match_genders', 'Interested in', 'Women'),
        _standard(
            'ethnic_cultural_origin', 'Ethnic & cultural origin', 'South Asian'),
        // The founder's circled parentless level-2 facts — must sit FLUSH with
        // the standard items above (fix a) and as bullets, not bubbles (fix b).
        _freeBullet('emergent.story.5c5470d1', 'Gender identity: man'),
        _freeBullet('emergent.editor.identity.5', 'Lives in San Jose'),
        _freeBullet('emergent.story.e1ff8e89', 'Went to college in Kerala'),
        _freeBullet('emergent.story.b7aba075', 'Born in Dubai'),
        _freeBullet('emergent.story.d755457b', 'Full name is Suhail P S'),
      ],
    );
    final file = await _capture(
      tester,
      'test/goldens/story_about_me_flush_bullets.png',
      width: 390,
      height: 620,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: NodeVisualiserSection(
          section: section,
          surface: NodeVisualiserSurface.publicProfile,
          isOwner: false,
        ),
      ),
    );
    // ignore: avoid_print
    print('about-me screenshot: ${file.absolute.path}');
  });

  testWidgets('Web research report: full-length bullets + inline Confidence',
      (tester) async {
    StoryNode prose(String id, String text) => StoryNode(
          id: id,
          section: 'summary',
          label: '',
          text: text,
          gist: text,
          answerType: 'narrative',
          level: 1,
          visibility: NodeVis.public,
          subtreeVisibility: NodeVis.public,
          standard: false,
          editable: false,
          visual: const NodeVisual(type: NodeVisualType.gistRow),
        );
    final confidence = StoryNode(
      id: 'confidence',
      section: 'summary',
      label: 'Confidence',
      text: 'Confidence',
      answerType: 'stat',
      level: 1,
      visibility: NodeVis.public,
      subtreeVisibility: NodeVis.public,
      standard: false,
      editable: false,
      statText: 'High',
      visual: const NodeVisual(type: NodeVisualType.gistRow),
    );
    final section = GraphTreeSection(
      pageType: 'summary',
      title: 'Summary',
      order: 0,
      nodes: [
        prose('s0',
            'He completed a Master of Science in Color Science under a joint '
            'program and now leads a small research team based in San Jose.'),
        prose('s1',
            'His published work focuses on perceptual colour appearance models '
            'and display calibration, cited across several venues in the field.'),
        confidence,
      ],
    );
    final file = await _capture(
      tester,
      'test/goldens/web_report_full_bullets_confidence.png',
      width: 390,
      height: 560,
      child: NodeVisualiserSection(
        section: section,
        surface: NodeVisualiserSurface.report,
        cardStyle: true,
      ),
    );
    // ignore: avoid_print
    print('web-report screenshot: ${file.absolute.path}');
  });
}
