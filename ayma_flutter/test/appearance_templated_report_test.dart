// Regression (build 2488, founder): the APPEARANCE report renders as a
// designed TEMPLATED page — fixed Attributes / Face / Physique sections built
// from the appearance NODE TREE, a numeric score header, attribute fields, and
// its analysed photos CAROUSEL-style (a PageView of the shared NodeImage) — and
// is NOT the generic Node-Visualiser bullet tree (GraphTreeView /
// NodeVisualiserSection) every other report uses. Same nodes, same source of
// truth (GET /report/appearance/{uid}/tree), no second store.
import 'dart:convert';

import 'package:ayma_flutter/models/story_node.dart';
import 'package:ayma_flutter/widgets/appearance_templated_report.dart';
import 'package:ayma_flutter/widgets/graph_tree_view.dart';
import 'package:ayma_flutter/widgets/node_visualiser.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _attr(String id, String label, String value) => {
      'id': id,
      'section': 'attributes',
      'label': label,
      'text': value,
      'answer_type': 'text',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      'standard': true,
      'standard_label': label,
    };

Map<String, dynamic> _stat(String id, String verdict, num value) => {
      'id': id,
      'section': id,
      'label': verdict,
      'text': verdict,
      'answer_type': 'stat',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      'stat_value': value,
      'stat_text': '$value',
      'stat_basis': 'Weighted across the selected photos',
    };

Map<String, dynamic> _text(String id, String section, String text) => {
      'id': id,
      'section': section,
      'label': '',
      'text': text,
      'answer_type': 'text',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
    };

Map<String, dynamic> _image(String id, String section, String url) => {
      'id': id,
      'section': section,
      'label': '',
      'text': '',
      'answer_type': 'image',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
      'image_url': url,
      'image_read': 'Ayma read of this photo',
    };

Map<String, dynamic> _tree() => {
      'surface': 'report',
      'title': 'Appearance',
      'sections': [
        {
          'page_type': 'attributes',
          'title': 'Attributes',
          'order': 0,
          'nodes': [
            _attr('attr:eye_color', 'Eye color', 'Brown'),
            _image('attr:photos:0', 'attributes', 'https://cdn/a0.jpg'),
            _image('attr:photos:1', 'attributes', 'https://cdn/a1.jpg'),
          ],
        },
        {
          'page_type': 'face',
          'title': 'Face',
          'order': 1,
          'nodes': [
            _stat('face', 'Striking', 7.8),
            _text('face:note:sent:0', 'face', 'Strong jawline and symmetry.'),
            _image('face:photo', 'face', 'https://cdn/face.jpg'),
          ],
        },
        {
          'page_type': 'body',
          'title': 'Body',
          'order': 2,
          'nodes': [
            _stat('body', 'Athletic', 8.1),
            _image('body:photo', 'body', 'https://cdn/body.jpg'),
          ],
        },
      ],
    };

ApiClient _api({List<String>? seen, int status = 200, Object? body}) {
  final mock = MockClient((request) async {
    seen?.add(request.url.path);
    return http.Response(
      jsonEncode(body ?? _tree()),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return ApiClient(httpClient: mock, auth: MockFirebaseAuth(signedIn: true));
}

Future<void> _pump(WidgetTester tester, ApiClient api,
    {void Function(GraphTree)? onLoaded}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(children: [
        AppearanceTemplatedReport(
            reportId: 'u1', api: api, onLoaded: onLoaded),
      ]),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'renders the TEMPLATED sections + score header + photo carousel from the '
      'appearance nodes — not the generic bullet tree', (tester) async {
    final seen = <String>[];
    GraphTree? loaded;
    await _pump(tester, _api(seen: seen), onLoaded: (t) => loaded = t);

    // It fetched the SAME appearance node tree the bullet tree used.
    expect(seen, contains('/report/appearance/u1/tree'));

    // The templated root + the three fixed designed section cards.
    expect(find.byKey(const Key('appearance_templated_report')), findsOneWidget);
    expect(find.byKey(const Key('appearance_section_card_attributes')),
        findsOneWidget);
    expect(find.byKey(const Key('appearance_section_card_face')), findsOneWidget);
    expect(find.byKey(const Key('appearance_section_card_body')), findsOneWidget);

    // Fixed designed titles (not the raw node section headings).
    expect(find.text('Physical attributes'), findsOneWidget);
    expect(find.text('Face'), findsOneWidget);
    expect(find.text('Physique'), findsOneWidget);

    // The numeric score header (verdict label + value + bar), from the stat node.
    expect(find.byKey(const Key('appearance_score_face')), findsOneWidget);
    expect(find.byKey(const Key('appearance_score_bar_face')), findsOneWidget);
    expect(find.text('Striking'), findsOneWidget);
    expect(find.text('7.8'), findsOneWidget); // face score, one decimal
    expect(find.text('8.1'), findsOneWidget); // body score, one decimal

    // An attribute field renders as a labelled field (not a bullet row).
    expect(find.text('Brown'), findsOneWidget);

    // Photos render carousel-style: a PageView of the shared NodeImage renderer.
    expect(find.byKey(const Key('appearance_carousel_attributes')),
        findsOneWidget);
    expect(find.byKey(const Key('appearance_carousel_face')), findsOneWidget);
    expect(find.byType(PageView), findsWidgets);
    expect(find.byType(NodeImage), findsWidgets);

    // NOT the generic bullet tree: no GraphTreeView, no NodeVisualiserSection,
    // no bullet node rows.
    expect(find.byType(GraphTreeView), findsNothing);
    expect(find.byType(NodeVisualiserSection), findsNothing);
    expect(find.byType(NodeVisualiser), findsNothing);

    // The host's card-refresh hook still fires with the loaded tree.
    expect(loaded, isNotNull);
    expect(loaded!.sections.length, 3);
  });

  testWidgets('a 404 (never run) shows the empty message, not an error',
      (tester) async {
    await _pump(tester, _api(status: 404, body: const <String, dynamic>{}));
    expect(find.byKey(const Key('appearance_templated_empty')), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a real load failure (500) shows Retry', (tester) async {
    await _pump(tester, _api(status: 500, body: 'nope'));
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('scrolls cleanly with no overflow at 320px width',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final errors = <FlutterErrorDetails>[];
    final prev = FlutterError.onError;
    FlutterError.onError = errors.add;
    await _pump(tester, _api());
    FlutterError.onError = prev;

    expect(find.byKey(const Key('appearance_templated_report')), findsOneWidget);
    expect(errors, isEmpty);
  });
}
