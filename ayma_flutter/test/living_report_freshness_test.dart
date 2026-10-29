// The Appearance report's freshness stamp (founder 2026-10-28: a background
// rerun gave no signal it finished, and the content looked unchanged). The
// LivingReportView shows "Updated <relative time>" from the report's own
// generation timestamp on the Appearance report, so the user can SEE it ran —
// and never on other report types.
import 'dart:convert';

import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/widgets/living_report_view.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _appearanceReport(String? createdAt) => {
      'title': 'Appearance',
      'sections': [
        {
          'heading': 'Face',
          'blocks': [
            {
              'block_id': 'face:verdict',
              'type': 'text',
              'editable': false,
              'text': 'Above average.',
            },
          ],
        },
      ],
      'meta': {
        'owner_uid': 'u1',
        'viewer_can_edit': false,
        'created_at': createdAt,
        'updated_at': createdAt,
      },
    };

ApiClient _api(String reportType, String reportId, String? createdAt) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'GET' &&
        request.url.path == '/report/$reportType/$reportId') {
      return http.Response(
        jsonEncode(_appearanceReport(createdAt)),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

Widget _host(ApiClient api, String reportType, String reportId) => MaterialApp(
      home: Scaffold(
        body: LivingReportView(
          reportType: reportType,
          reportId: reportId,
          apiClient: api,
        ),
      ),
    );

void main() {
  testWidgets('appearance report shows a freshness stamp', (tester) async {
    final when = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 5))
        .toIso8601String();
    await tester.pumpWidget(_host(_api('appearance', 'u1', when), 'appearance', 'u1'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reportFreshness')), findsOneWidget);
    expect(find.text('Updated 5m ago'), findsOneWidget);
  });

  testWidgets('no stamp when the report carries no timestamp', (tester) async {
    await tester.pumpWidget(_host(_api('appearance', 'u1', null), 'appearance', 'u1'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reportFreshness')), findsNothing);
  });

  testWidgets('other report types never show the stamp', (tester) async {
    final when = DateTime.now().toUtc().toIso8601String();
    await tester.pumpWidget(_host(_api('deep_dive', 'rid1', when), 'deep_dive', 'rid1'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reportFreshness')), findsNothing);
  });
}
