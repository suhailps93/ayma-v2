// AppearanceReportScreen is now a thin wrapper: an AppBar plus the ONE
// shared [LivingReportView] renderer (§ generic reports), fetching
// `GET /report/appearance/{uid}` — `report_hub.resolve_owner` treats
// "appearance"'s `{report_id}` as the subject's own uid (there is only ever
// one current report), so this screen resolves to the signed-in uid
// ([myUid] here, injected for the test) rather than the (possibly stale)
// [reportId] constructor arg. Per-block tap/section/report tier behavior,
// quick actions, multi-select, and the sentence long-press guard are all
// covered once, generically, in `living_report_view_test.dart` — this file
// only proves the screen wires the right report type/id and shows the
// fetched content.
import 'dart:convert';

import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';

Map<String, dynamic> _block(String id, String type, {String text = '', bool editable = true}) => {
      'block_id': id,
      'type': type,
      'editable': editable,
      'text': text,
    };

ApiClient _api({String? requirePath}) {
  final mockHttp = MockClient((request) async {
    if (requirePath != null) {
      expect(request.url.path, requirePath);
    }
    if (request.url.path.startsWith('/report/appearance/')) {
      return http.Response(
        jsonEncode({
          'title': 'Appearance',
          'sections': [
            {
              'heading': 'Attributes',
              'blocks': [
                {
                  'block_id': 'attr:eye_color',
                  'type': 'attribute',
                  'editable': true,
                  'label': 'Eyes',
                  'value': 'Brown',
                },
              ],
            },
            {
              'heading': 'Face',
              'blocks': [_block('face:status', 'section_head', text: 'Add a face photo to get a Face report.', editable: false)],
            },
          ],
          'meta': {
            'owner_uid': 'u1',
            'viewer_can_edit': true,
            'created_at': null,
            'updated_at': null,
          },
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('fetches GET /report/appearance/{uid} and renders it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'stale-marker-id',
        myUid: 'u1',
        apiClient: _api(requirePath: '/report/appearance/u1'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsWidgets); // AppBar + report title
    expect(find.text('Brown'), findsOneWidget);
    expect(find.textContaining('Add a face photo to get a Face report.'),
        findsOneWidget);
  });

  testWidgets('Re-run opens the run screen', (tester) async {
    final router = GoRouter(
      initialLocation: '/appearance/current',
      routes: [
        GoRoute(
          path: '/appearance/current',
          builder: (_, __) => AppearanceReportScreen(
              reportId: 'current', myUid: 'u1', apiClient: _api()),
        ),
        GoRoute(
          path: '/skills',
          builder: (_, __) => const Scaffold(body: Text('RUN SCREEN')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Re-run'));
    await tester.pumpAndSettle();
    expect(find.text('RUN SCREEN'), findsOneWidget);
  });

  testWidgets('falls back to reportId when no signed-in uid is available',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(
        reportId: 'fallback-id',
        myUid: '',
        apiClient: _api(requirePath: '/report/appearance/fallback-id'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Brown'), findsOneWidget);
  });

  testWidgets('shows a retry message when the report fails to load',
      (tester) async {
    final mockHttp = MockClient((request) async => http.Response('nope', 404));
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
    await tester.pumpWidget(MaterialApp(
      home: AppearanceReportScreen(reportId: 'a0', myUid: 'u1', apiClient: api),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't load that report"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
