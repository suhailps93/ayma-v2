// The web-research report's "Searching the web again…" banner and AppBar
// spinner follow the server's `run_status` for the report, never a local
// latch: they clear as soon as the server says the run is done, resume when
// the report is opened mid-run, and a run that failed or never finished
// shows "Search didn't finish." with a "Try again" button instead.
// Each test uses its own report id: [DeepDiveActivity] is an app singleton.
import 'dart:convert';

import 'package:ayma_flutter/screens/deep_dive_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/deep_dive_activity.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};
const _searching = 'Searching the web again…';
const _didntFinish = "Search didn't finish.";

/// [status] is called with the 1-based count of report reads so far.
ApiClient _api(String id, String Function(int read) status,
    {List<String>? posts}) {
  var reads = 0;
  return ApiClient(
    auth: MockFirebaseAuth(signedIn: true),
    httpClient: MockClient((req) async {
      if (req.url.path == '/deep-dive-report/$id') {
        reads++;
        return http.Response(
            jsonEncode({
              'name': 'Jane',
              'is_self': true,
              'run_status': status(reads),
              'digest': {'summary': 's', 'facts': <dynamic>[]},
            }),
            200,
            headers: _json);
      }
      if (req.url.path == '/report/deep_dive/$id') {
        return http.Response(
            jsonEncode({
              'title': 'Web search: Jane',
              'sections': <dynamic>[],
              'meta': {
                'owner_uid': 'me',
                'viewer_can_edit': true,
                'created_at': null,
                'updated_at': null,
              },
            }),
            200,
            headers: _json);
      }
      if (req.url.path == '/deep-dive') {
        posts?.add(req.url.path);
        return http.Response(jsonEncode({'queued': true}), 200,
            headers: _json);
      }
      return http.Response('{}', 200);
    }),
  );
}

Widget _screen(String id, ApiClient api) =>
    MaterialApp(home: DeepDiveReportScreen(reportId: id, apiClient: api));

IconButton _refresh(WidgetTester tester) =>
    tester.widget<IconButton>(find.byType(IconButton).last);

void main() {
  testWidgets('a finished report shows no banner and an idle Re-run button',
      (tester) async {
    await tester.pumpWidget(_screen('done1', _api('done1', (_) => 'done')));
    await tester.pumpAndSettle();
    expect(find.text(_searching), findsNothing);
    expect(find.text(_didntFinish), findsNothing);
    expect(_refresh(tester).onPressed, isNotNull);
  });

  testWidgets(
      'opened mid-run (e.g. from the notification after a restart): banner '
      'and spinner show, then clear the moment the server says done',
      (tester) async {
    await tester.pumpWidget(_screen(
        'run1', _api('run1', (read) => read <= 2 ? 'running' : 'done')));
    await tester.pump();
    await tester.pump();
    expect(find.text(_searching), findsOneWidget);
    expect(_refresh(tester).onPressed, isNull);

    await tester.pump(const Duration(seconds: 4)); // read 2: still running
    await tester.pump();
    expect(find.text(_searching), findsOneWidget);

    await tester.pump(const Duration(seconds: 4)); // read 3: done
    await tester.pumpAndSettle();
    expect(find.text(_searching), findsNothing);
    expect(find.text(_didntFinish), findsNothing);
    expect(_refresh(tester).onPressed, isNotNull);
  });

  testWidgets(
      'a failed run shows "Search didn\'t finish." with Try again, no '
      'spinner; Try again starts a new search', (tester) async {
    final posts = <String>[];
    await tester.pumpWidget(_screen(
        'fail1',
        _api('fail1',
            (read) => read == 1 ? 'failed' : (read == 2 ? 'running' : 'done'),
            posts: posts)));
    await tester.pumpAndSettle();
    expect(find.text(_didntFinish), findsOneWidget);
    expect(find.text(_searching), findsNothing);
    expect(_refresh(tester).onPressed, isNotNull);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(posts, ['/deep-dive']);
    expect(find.text(_searching), findsOneWidget);
    expect(find.text(_didntFinish), findsNothing);

    await tester.pump(const Duration(seconds: 4)); // read 2: running
    await tester.pump(const Duration(seconds: 4)); // read 3: done
    await tester.pumpAndSettle();
    expect(find.text(_searching), findsNothing);
    expect(find.text(_didntFinish), findsNothing);
  });

  testWidgets(
      'a poll the server never finishes gives up after the timeout and marks '
      'the report failed (no endless spinner)', (tester) async {
    final done = DeepDiveActivity.instance
        .start('stuck1', api: _api('stuck1', (_) => 'running'));
    await tester.pump(const Duration(minutes: 1));
    expect(DeepDiveActivity.instance.isSearching('stuck1'), isTrue);

    await tester.pump(DeepDiveActivity.timeout);
    await tester.runAsync(() => done);
    expect(DeepDiveActivity.instance.isSearching('stuck1'), isFalse);
    expect(DeepDiveActivity.instance.hasFailed('stuck1'), isTrue);
  });
}
