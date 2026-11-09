// DeepDiveReportScreen's body is now the ONE shared [LivingReportView]
// renderer (§ generic reports), fetching `GET /report/deep_dive/{id}`; the
// AppBar's "Re-run" / "Ask Ayma" actions still read a small amount of
// metadata (name/isSelf/otherUid) off the existing dedicated
// `GET /deep-dive-report/{id}` read, fetched alongside purely for that.
// Per-block tap/section/report tier behavior, quick actions (including the
// candidate "This is me"/"Not me" pair), multi-select, and the sentence
// long-press guard are all covered once, generically, in
// `living_report_view_test.dart` — this file proves the screen wires the
// right report id/type and that its own AppBar actions still work.
import 'dart:convert';

import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _metaDoc({
  String name = 'Jane',
  bool isSelf = true,
  String targetUid = '',
}) =>
    {
      'name': name,
      'is_self': isSelf,
      'target_uid': targetUid,
      'digest': {'summary': 'A summary.', 'facts': <dynamic>[]},
    };

Map<String, dynamic> _blockReport() => {
      'title': 'Web search: Jane',
      'sections': [
        {
          'heading': 'Summary',
          'blocks': [
            {
              'block_id': 'summary:sent:0',
              'type': 'text',
              'editable': true,
              'text': 'Jane works at Acme.',
            },
          ],
        },
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': true,
        'created_at': null,
        'updated_at': null,
      },
    };

ApiClient _api({
  Map<String, dynamic>? metaDoc,
  List<Map<String, dynamic>>? deepDiveCalls,
  int metaStatus = 200,
  int reportStatus = 200,
  bool capped = false,
}) {
  final mockHttp = MockClient((request) async {
    if (request.url.path.startsWith('/deep-dive-report/')) {
      return http.Response(
          metaStatus == 200
              ? jsonEncode(metaDoc ?? _metaDoc())
              : jsonEncode({'detail': 'No such report.'}),
          metaStatus,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path.startsWith('/report/deep_dive/')) {
      return http.Response(
          reportStatus == 200
              ? jsonEncode(_blockReport())
              : jsonEncode({'detail': 'No such report.'}),
          reportStatus,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path == '/deep-dive' && request.method == 'POST') {
      deepDiveCalls?.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'usage_capped': capped}), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(ApiClient api, {String reportId = 'rid1'}) {
  final router = GoRouter(
    initialLocation: '/deep-dive/$reportId',
    routes: [
      GoRoute(
        path: DeepDiveReportScreen.path,
        builder: (_, state) => DeepDiveReportScreen(
          reportId: state.pathParameters['id']!,
          apiClient: api,
        ),
      ),
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Text('HOME')),
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  testWidgets('renders the block report content via LivingReportView',
      (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    expect(find.text('Web research'), findsOneWidget); // AppBar title
    expect(find.text('Web search: Jane'), findsOneWidget); // report title
    expect(find.textContaining('Jane works at Acme.'), findsOneWidget);
  });

  testWidgets('"Re-run" on your own report targets no one but you',
      (tester) async {
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(deepDiveCalls: calls)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Re-run'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single['target_uid'], '');
    expect(calls.single['force'], true);
  });

  testWidgets('"Re-run" on someone else\'s report targets them',
      (tester) async {
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(_api(
      metaDoc: _metaDoc(name: 'Bob', isSelf: false, targetUid: 'bob-uid'),
      deepDiveCalls: calls,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Re-run'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single['target_uid'], 'bob-uid');
  });

  testWidgets(
      'the AppBar has NO "Ask Ayma" action — the nav-bar orb covers it '
      '(founder: redundant, removed; the report title tap still opens the '
      'scoped correction modal)', (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    expect(find.text('Web research'), findsOneWidget);
    expect(find.text('Ask Ayma'), findsNothing);
    // The re-run action stays.
    expect(find.byTooltip('Re-run'), findsOneWidget);
  });

  testWidgets(
      'never-run (404) shows the "No web research yet" empty state and starts '
      'no search on open', (tester) async {
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(
      _api(metaStatus: 404, reportStatus: 404, deepDiveCalls: calls),
      reportId: 'uid_bob',
    ));
    await tester.pumpAndSettle();

    expect(find.text('No web research yet'), findsOneWidget);
    expect(find.text('Run web search'), findsOneWidget);
    expect(find.text("Couldn't load that report."), findsNothing);
    // Opening to view must not auto-run the dive.
    expect(calls, isEmpty);
  });

  testWidgets(
      'the "Run web search" button has a >= 48 tall touch target (Jobs pass)',
      (tester) async {
    await tester.pumpWidget(_host(
      _api(metaStatus: 404, reportStatus: 404),
      reportId: 'uid_bob',
    ));
    await tester.pumpAndSettle();

    final h = tester
        .getSize(find.widgetWithText(FilledButton, 'Run web search'))
        .height;
    expect(h, greaterThanOrEqualTo(48.0));
  });

  testWidgets(
      '"Run web search" on the empty state starts a dive on the subject the '
      'uid_<x> report id names', (tester) async {
    final calls = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(
      _api(metaStatus: 404, reportStatus: 404, deepDiveCalls: calls),
      reportId: 'uid_bob',
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run web search'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single['target_uid'], 'bob');
    expect(calls.single['force'], true);
  });

  testWidgets(
      '"Run web search" shows the out-of-credits sheet when capped',
      (tester) async {
    await tester.pumpWidget(_host(
      _api(metaStatus: 404, reportStatus: 404, capped: true),
      reportId: 'uid_bob',
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Run web search'));
    await tester.pumpAndSettle();

    expect(find.text("You're out of credits"), findsOneWidget);
  });

  testWidgets(
      'a genuine load failure (500) still shows the "Couldn\'t load" retry, '
      'not the empty state', (tester) async {
    await tester.pumpWidget(_host(
      _api(metaStatus: 500, reportStatus: 500),
      reportId: 'uid_bob',
    ));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load that report."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No web research yet'), findsNothing);
  });
}
