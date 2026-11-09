import 'dart:convert';

import 'package:ayma_flutter/screens/physical_attributes_report_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient _api(Map<String, dynamic> body, {int status = 200}) {
  final mockHttp = MockClient((request) async {
    if (request.url.path.startsWith('/physical-attributes-report/')) {
      return http.Response(jsonEncode(body), status,
          headers: const {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 200);
  });
  return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
}

void main() {
  testWidgets('renders attributes grouped by stated vs from-photos', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _api({
      'id': 'r1',
      'summary': 'Physical profile — hair: black (from photos).',
      'photo_count': 4,
      'created_at': '2026-02-03T10:00:00',
      'fields': {
        'build': {'value': 'athletic', 'source': 'stated', 'confidence': 'high'},
        'eye_color': {
          'value': 'brown',
          'source': 'photo',
          'confidence': 'medium',
        },
        'hair_color': {
          'value': 'black',
          'source': 'photo',
          'confidence': 'high',
        },
        'distinguishing_features': {
          'value': 'small scar above left brow',
          'source': 'photo',
          'confidence': 'low',
        },
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: PhysicalAttributesReportScreen(reportId: 'r1', apiClient: api),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Physical profile'), findsWidgets); // app bar + header
    expect(find.text('FROM YOUR ANSWERS'), findsOneWidget);
    expect(find.text('READ FROM YOUR PHOTOS'), findsOneWidget);
    expect(find.text('NOTABLE FEATURES'), findsOneWidget);
    expect(find.text('Athletic'), findsOneWidget); // stated, capitalised
    expect(find.text('Black'), findsOneWidget); // from photos
    expect(find.text('small scar above left brow'), findsOneWidget);
    expect(find.textContaining('feeds your matching'), findsOneWidget);
  });

  testWidgets('shows a retry message when the report fails to load',
      (tester) async {
    final api = _api(const {}, status: 404);
    await tester.pumpWidget(MaterialApp(
      home: PhysicalAttributesReportScreen(reportId: 'nope', apiClient: api),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't load that report"), findsOneWidget);
    final retryFinder = find.widgetWithText(TextButton, 'Retry');
    expect(retryFinder, findsOneWidget);
    expect(tester.getSize(retryFinder).height, greaterThanOrEqualTo(48.0));
  });
}
