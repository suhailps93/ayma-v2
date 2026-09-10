import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/screens/physical_attributes_report_screen.dart';
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
      'a physical_attributes kickoff calls the refresh API and resolves the '
      'pending turn to a tappable report card that opens the report screen',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};
    final hits = <String>[];
    final mockHttp = MockClient((request) async {
      hits.add('${request.method} ${request.url.path}');
      if (request.url.path == '/chat/history') {
        return http.Response(
            jsonEncode({'messages': <dynamic>[], 'next_before': null}), 200,
            headers: jsonUtf8);
      }
      if (request.url.path == '/physical-attributes/refresh') {
        return http.Response(
          jsonEncode({
            'ok': true,
            'id': 'auto7',
            'fields': {
              'hair_color': {
                'value': 'black',
                'source': 'photo',
                'confidence': 'high',
              },
              'build': {
                'value': 'athletic',
                'source': 'stated',
                'confidence': 'high',
              },
            },
            'photo_count': 3,
            'summary': 'Physical profile — hair: black (from photos).',
          }),
          200,
          headers: jsonUtf8,
        );
      }
      if (request.url.path == '/physical-attributes-report/auto7') {
        return http.Response(
          jsonEncode({
            'id': 'auto7',
            'summary': 'Physical profile — hair: black (from photos).',
            'photo_count': 3,
            'fields': {
              'hair_color': {
                'value': 'black',
                'source': 'photo',
                'confidence': 'high',
              },
              'build': {
                'value': 'athletic',
                'source': 'stated',
                'confidence': 'high',
              },
            },
            'created_at': '2026-02-03T10:00:00',
          }),
          200,
          headers: jsonUtf8,
        );
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
          path: PhysicalAttributesReportScreen.path,
          builder: (_, state) => PhysicalAttributesReportScreen(
            reportId: state.pathParameters['id']!,
            apiClient: api,
          ),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    ChatInbox.instance.push(ChatKickoff.physicalAttributes());
    await tester.pumpAndSettle();

    expect(hits, contains('POST /physical-attributes/refresh'));
    expect(find.textContaining('Physical profile updated'), findsOneWidget);
    expect(find.textContaining('feeds your matching'), findsOneWidget);

    // The card opens the report screen.
    await tester.tap(find.text('Physical profile report'));
    await tester.pumpAndSettle();

    expect(find.text('FROM YOUR ANSWERS'), findsOneWidget);
    expect(find.text('READ FROM YOUR PHOTOS'), findsOneWidget);
  });
}
