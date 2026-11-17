// AppearanceReportScreen (2o P2): an AppBar + the shareable card (fed by the
// block report via GET /report/appearance/{uid}) + the full report BODY, which
// now renders through the shared GraphTreeView Node-Visualiser via
// GET /report/appearance/{uid}/tree. This file proves the screen fetches both
// and shows the body's node content; node rendering itself is covered in
// node_visualiser_test.dart.
import 'dart:convert';

import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/report_events.dart';
import 'package:ayma_flutter/widgets/ayma_wing_loader.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';

Map<String, dynamic> _textNode(String id, String text) => {
      'id': id,
      'section': 'appearance',
      'label': '',
      'text': text,
      'answer_type': 'text',
      'level': 1,
      'visibility': 'public',
      'subtree_visibility': 'public',
    };

/// The node tree the body renders (a text node for the attribute value + the
/// face status line).
Map<String, dynamic> _tree() => {
      'surface': 'report',
      'title': 'Appearance',
      'sections': [
        {
          'page_type': 'attributes',
          'title': 'Attributes',
          'order': 0,
          'nodes': [_textNode('attr', 'Brown')],
        },
        {
          'page_type': 'face',
          'title': 'Face',
          'order': 1,
          'nodes': [
            _textNode('face_status', 'Add a face photo to get a Face report.')
          ],
        },
      ],
    };

/// The block report the shareable card reads (no scores → no card shown).
Map<String, dynamic> _blockReport() => {
      'title': 'Appearance',
      'sections': [
        {
          'heading': 'Attributes',
          'blocks': [
            {'block_id': 'attr:eye_color', 'type': 'attribute',
             'editable': true, 'label': 'Eyes', 'value': 'Brown'},
          ],
        },
      ],
      'meta': {'owner_uid': 'u1', 'viewer_can_edit': true,
               'created_at': null, 'updated_at': null},
    };

ApiClient _api({List<String>? seen}) {
  final mockHttp = MockClient((request) async {
    final path = request.url.path;
    seen?.add(path);
    if (path == '/appearance/eligibility') {
      return http.Response(
        jsonEncode({'face': const [], 'body': const [],
            'has_face_photo': false, 'has_body_photo': false}),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.endsWith('/tree') && path.contains('/report/appearance/')) {
      return http.Response(jsonEncode(_tree()), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (path.startsWith('/report/appearance/')) {
      return http.Response(jsonEncode(_blockReport()), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('fetches the appearance tree + card report and renders the body',
      (tester) async {
    final seen = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'stale-marker-id',
        myUid: 'u1',
        apiClient: _api(seen: seen),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsWidgets); // AppBar
    // The body renders the node tree.
    expect(find.text('Brown'), findsOneWidget);
    expect(find.textContaining('Add a face photo to get a Face report.'),
        findsOneWidget);
    // Both the body tree and the card's block report were fetched, by uid.
    expect(seen, contains('/report/appearance/u1/tree'));
    expect(seen, contains('/report/appearance/u1'));
  });

  testWidgets('Re-run opens the Appearance pre-run sheet (Face/Body groups)',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/appearance/current',
      routes: [
        GoRoute(
          path: '/appearance/current',
          builder: (_, __) => AppearanceReportScreen(
              reportId: 'current', myUid: 'u1', apiClient: _api()),
        ),
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('SHELL'))),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Re-run'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Face analysis'), findsOneWidget);
    expect(find.text('Body analysis'), findsOneWidget);
    expect(find.text('Run analysis'), findsOneWidget);
    expect(find.text('Add a photo that clearly shows your face.'),
        findsOneWidget);
    expect(find.text('Add a full-body photo for a body report.'),
        findsOneWidget);
  });

  testWidgets('falls back to reportId when no signed-in uid is available',
      (tester) async {
    final seen = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'fallback-id',
        myUid: '',
        apiClient: _api(seen: seen),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Brown'), findsOneWidget);
    expect(seen, contains('/report/appearance/fallback-id/tree'));
  });

  testWidgets(
      'shows a LOADING STATE (spinning Re-run + "Updating…" banner) while an '
      'appearance run is in progress, then clears it when the run lands',
      (tester) async {
    addTearDown(() => ReportEvents.instance.stopped('appearance'));
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
          reportId: 'current', myUid: 'u1', apiClient: _api()),
    ));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Re-run'), findsOneWidget);
    expect(find.text('Updating your report…'), findsNothing);

    ReportEvents.instance.started('appearance');
    await tester.pump();
    expect(find.byTooltip('Running your analysis…'), findsOneWidget);
    expect(find.byTooltip('Re-run'), findsNothing);
    expect(find.text('Updating your report…'), findsOneWidget);
    expect(find.byType(AymaWingLoader), findsWidgets);

    ReportEvents.instance.stopped('appearance');
    await tester.pump();
    expect(find.byTooltip('Re-run'), findsOneWidget);
    expect(find.text('Updating your report…'), findsNothing);
  });

  testWidgets('a real load failure (500) shows Retry', (tester) async {
    final fail = ApiClient(
        httpClient: MockClient((r) async => http.Response('nope', 500)),
        auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a0', myUid: 'u1', apiClient: fail),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a 404 (no report yet) shows the empty message, not an error',
      (tester) async {
    final none = ApiClient(
        httpClient: MockClient((r) async => http.Response('{}', 404)),
        auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a0', myUid: 'u1', apiClient: none),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No appearance report yet.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
