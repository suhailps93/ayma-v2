import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets(
      'a physical_attributes kickoff calls the refresh API and resolves the '
      'pending turn with the summary', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // charset=utf-8 so the em-dash in the summary survives http.Response's
    // latin-1 default.
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
            'fields': {
              'hair_color': {
                'value': 'black',
                'source': 'photo',
                'confidence': 'high',
              },
            },
            'photo_count': 2,
            'summary': 'Physical profile — hair: black (from photos).',
          }),
          200,
          headers: jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle(); // let history settle first (as in the app)

    ChatInbox.instance.push(ChatKickoff.physicalAttributes());
    await tester.pumpAndSettle();

    expect(hits, contains('POST /physical-attributes/refresh'));
    expect(
      find.textContaining('Physical profile — hair: black (from photos).'),
      findsOneWidget,
    );
    expect(
      find.textContaining('This feeds your matching and Explore search.'),
      findsOneWidget,
    );
  });
}
