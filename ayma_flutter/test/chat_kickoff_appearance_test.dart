import 'dart:convert';

import 'package:ayma_flutter/screens/appearance_report_screen.dart';
import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets(
      'an appearance kickoff calls the report API and resolves the pending '
      'turn to a card that opens the Appearance screen', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
    final hits = <String>[];
    final report = {
      'id': 'app9',
      'created_at': '2026-02-03T10:00:00',
      'photo_count': 3,
      'attributes': {
        'summary': 'Physical profile — hair: black (from photos).',
        'record': {
          'hair_color': {
            'value': 'black',
            'source': 'photo',
            'confidence': 'high',
          },
        },
      },
      'face': {
        'usable': true,
        'overall_score': 7.0,
        'verdict': 'Above average',
        'verdict_note': '',
        'features': <dynamic>[],
        'quick_facts': <String, dynamic>{},
        'strengths': <dynamic>[],
        'improvements': <dynamic>[],
        'recommendations': <dynamic>[],
      },
      'body': {'status': 'needs_body_photo'},
    };

    final mockHttp = MockClient((request) async {
      hits.add('${request.method} ${request.url.path}');
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: jsonUtf8);
      }
      if (request.url.path == '/appearance/report') {
        return http.Response(
            jsonEncode({'ok': true, 'report_id': 'app9', 'report': report}),
            200,
            headers: jsonUtf8);
      }
      if (request.url.path == '/appearance/report/app9') {
        return http.Response(jsonEncode(report), 200, headers: jsonUtf8);
      }
      return http.Response('{}', 200, headers: jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => ChatScreen(apiClient: api)),
        GoRoute(
          path: AppearanceReportScreen.path,
          builder: (_, state) => AppearanceReportScreen(
            reportId: state.pathParameters['id']!,
            apiClient: api,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    ChatInbox.instance.push(
        ChatKickoff.appearance(wantFace: true, wantBody: false));
    await tester.pumpAndSettle();

    expect(hits, contains('POST /appearance/report'));
    expect(find.textContaining('Appearance report ready'), findsOneWidget);

    await tester.tap(find.text('Appearance report'));
    await tester.pumpAndSettle();

    expect(find.text('ATTRIBUTES'), findsOneWidget);
    expect(find.text('FACE'), findsOneWidget);
    expect(find.text('PHYSIQUE'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Add a full-length photo'),
        findsOneWidget);
  });

  testWidgets('a legacy [physical:id] marker still opens something',
      (tester) async {
    // The marker regex must still recognise the retired markers.
    final re = RegExp(
        r'\s*\[(appearance|face_report|body_report|deep_dive|physical):'
        r'([A-Za-z0-9_-]+)\]\s*$');
    expect(re.hasMatch('done [physical:auto3]'), isTrue);
    expect(re.hasMatch('done [appearance:app9]'), isTrue);
    expect(re.hasMatch('done [face_report:r1]'), isTrue);
  });
}
