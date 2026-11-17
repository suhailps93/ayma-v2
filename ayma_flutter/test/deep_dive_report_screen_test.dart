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

/// The node tree the body renders (one text node for the summary).
Map<String, dynamic> _tree() => {
      'surface': 'report',
      'title': 'Web search: Jane',
      'sections': [
        {
          'page_type': 'summary',
          'title': 'Summary',
          'order': 0,
          'nodes': [
            {
              'id': 'summary',
              'section': 'summary',
              'label': '',
              'text': 'Jane works at Acme.',
              'answer_type': 'text',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
            }
          ],
        },
      ],
      'meta': {'owner_uid': 'u1', 'viewer_can_edit': true},
    };

/// A tree with one pending reverse-image-search candidate node.
Map<String, dynamic> _treeWithCandidate() => {
      'surface': 'report',
      'sections': [
        {
          'page_type': 'photos_to_confirm',
          'title': 'Photos to confirm',
          'order': 0,
          'nodes': [
            {
              'id': 'candidate:abc',
              'section': 'photos_to_confirm',
              'label': '',
              'text': 'Found online',
              'answer_type': 'candidate',
              'image_url': 'https://site/p.jpg',
              'candidate_id': 'abc',
              'level': 1,
              'visibility': 'public',
              'subtree_visibility': 'public',
            }
          ],
        },
      ],
      'meta': {'owner_uid': 'u1', 'viewer_can_edit': true},
    };

ApiClient _api({
  Map<String, dynamic>? metaDoc,
  List<Map<String, dynamic>>? deepDiveCalls,
  List<Map<String, dynamic>>? correctCalls,
  Map<String, dynamic>? tree,
  int metaStatus = 200,
  int reportStatus = 200,
  bool capped = false,
}) {
  final mockHttp = MockClient((request) async {
    final path = request.url.path;
    if (path.startsWith('/report/deep_dive/') && path.endsWith('/correct')) {
      correctCalls?.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode({'ok': true, 'results': const []}), 200,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (path.startsWith('/deep-dive-report/')) {
      return http.Response(
          metaStatus == 200
              ? jsonEncode(metaDoc ?? _metaDoc())
              : jsonEncode({'detail': 'No such report.'}),
          metaStatus,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    if (path.startsWith('/report/deep_dive/')) {
      // Body fetches .../tree; the old block path is no longer used.
      return http.Response(
          reportStatus == 200
              ? jsonEncode(tree ?? _tree())
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
  testWidgets('renders the report content via the Node-Visualiser tree',
      (tester) async {
    await tester.pumpWidget(_host(_api()));
    await tester.pumpAndSettle();

    expect(find.text('Web research'), findsOneWidget); // AppBar title
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

    expect(find.text("Couldn't load this."), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No web research yet'), findsNothing);
  });

  testWidgets('"This is me" on a candidate posts the confirm quick-action',
      (tester) async {
    final corrects = <Map<String, dynamic>>[];
    await tester.pumpWidget(_host(
      _api(tree: _treeWithCandidate(), correctCalls: corrects),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('node_candidate_me_candidate:abc')));
    await tester.tap(find.byKey(const Key('node_candidate_me_candidate:abc')));
    await tester.pumpAndSettle();

    expect(corrects, hasLength(1));
    expect(corrects.single['block_ids'], ['candidate:abc']);
    expect(corrects.single['message'], 'this is me');
  });
}
