// Stale-while-revalidate report caching (founder: the heavy report pages "take
// time to load, should we cache them? — yes") and background auto-refresh
// (founder bug: the open report "didn't create a new report" when a background
// run actually had). Covers:
//  - a cached report paints INSTANTLY on open, before the network fetch lands,
//    then the fresh result swaps in;
//  - with no cache, the branded animated-logo loader shows until data arrives;
//  - a ReportEvents completion makes the open report re-fetch and show the new
//    report with no manual reload;
//  - the fresh fetch refreshes the on-device cache.
import 'dart:async';
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/report_cache.dart';
import 'package:ayma_flutter/services/report_events.dart';
import 'package:ayma_flutter/widgets/ayma_logo_loader.dart';
import 'package:ayma_flutter/widgets/living_report_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'u1';

Map<String, dynamic> _report(String title) => {
      'title': title,
      'sections': [
        {
          'heading': 'Summary',
          'blocks': [
            {
              'block_id': 'b1',
              'type': 'text',
              'editable': false,
              'text': 'Body text.',
            },
          ],
        },
      ],
      'meta': {'owner_uid': _uid, 'viewer_can_edit': false},
    };

Widget _host(ApiClient api) => MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: 'appearance',
          reportId: _uid,
          apiClient: api,
          myUid: _uid,
        ),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'a cached report shows instantly on open, then the fresh fetch swaps in',
      (tester) async {
    // Seed the on-device cache for this user + report.
    SharedPreferences.setMockInitialValues({
      'report_cache:$_uid:appearance:$_uid': jsonEncode(_report('Cached')),
    });

    // The network fetch is gated so we can observe the cached copy first.
    final gate = Completer<void>();
    final mockHttp = MockClient((req) async {
      if (req.url.path == '/report/appearance/$_uid') {
        await gate.future;
        return http.Response(jsonEncode(_report('Fresh')), 200,
            headers: const {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{}', 404);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_host(api));
    // Let the (fast) cache read resolve — the fetch is still gated.
    await tester.pump();
    await tester.pump();

    // Instant: the cached report is on screen with NO loader, before the
    // network has returned anything.
    expect(find.text('Cached'), findsOneWidget);
    expect(find.text('Fresh'), findsNothing);
    expect(find.byType(AymaLogoLoader), findsNothing);

    // The fresh fetch lands and swaps in.
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Fresh'), findsOneWidget);
    expect(find.text('Cached'), findsNothing);

    // …and the cache is refreshed to the fresh payload.
    final cached =
        await ReportCache.instance.readReport(_uid, 'appearance', _uid);
    expect(cached, isNotNull);
    expect(jsonDecode(cached!)['title'], 'Fresh');
  });

  testWidgets('with no cache, the animated-logo loader shows until data lands',
      (tester) async {
    final gate = Completer<void>();
    final mockHttp = MockClient((req) async {
      if (req.url.path == '/report/appearance/$_uid') {
        await gate.future;
        return http.Response(jsonEncode(_report('Fresh')), 200,
            headers: const {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{}', 404);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_host(api));
    await tester.pump();

    // Nothing cached: the branded loader stands in while we wait.
    expect(find.byType(AymaLogoLoader), findsOneWidget);
    expect(find.text('Fresh'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AymaLogoLoader), findsNothing);
    expect(find.text('Fresh'), findsOneWidget);
  });

  testWidgets(
      'a background completion event makes the open report re-fetch and show '
      'the new report', (tester) async {
    var getCount = 0;
    final mockHttp = MockClient((req) async {
      if (req.url.path == '/report/appearance/$_uid') {
        getCount++;
        // First load → "Old"; any reload after the completion → "New".
        return http.Response(
            jsonEncode(_report(getCount == 1 ? 'Old' : 'New')), 200,
            headers: const {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response('{}', 404);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(_host(api));
    await tester.pumpAndSettle();
    expect(find.text('Old'), findsOneWidget);

    // A background appearance run finished elsewhere in the app.
    ReportEvents.instance.completed('appearance');
    await tester.pumpAndSettle();

    // The open report re-fetched and shows the fresh report — no manual reload.
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Old'), findsNothing);
    expect(getCount, greaterThanOrEqualTo(2));
  });
}
