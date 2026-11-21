import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _jsonUtf8 = {'content-type': 'application/json; charset=utf-8'};

/// A section's "Talk to Ayma about this" kickoff sends `discuss_section` so
/// Ayma opens on that section's pending questions. If that turn fails and
/// the user taps Retry, the retried turn must carry the same section —
/// otherwise Ayma falls back to a generic opener.
void main() {
  tearDown(() => ChatInbox.instance.take());

  testWidgets('Retry of a failed section kickoff re-sends discuss_section',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    var failing = true;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return http.Response(
          jsonEncode({'messages': <Object>[], 'next_before': null}),
          200,
          headers: _jsonUtf8,
        );
      }
      if (request.url.path == '/chat/stream' || request.url.path == '/chat') {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (failing) return http.Response('', 500);
        if (request.url.path == '/chat/stream') {
          return http.Response.bytes(
            utf8.encode('data: {"type":"reply","text":'
                '"Have you been married before?","tools_used":[]}\n\n'),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'reply': 'Have you been married before?',
            'tools_used': <String>[],
            'image_url': '',
          }),
          200,
          headers: _jsonUtf8,
        );
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    ChatInbox.instance.push(ChatKickoff.discussTopic(
      nodeId: 'marital_status',
      label: 'About Me',
      section: 'identity',
    ));
    await tester.pumpAndSettle();

    expect(sent, isNotEmpty);
    expect(sent.every((b) => b['discuss_section'] == 'identity'), isTrue);
    expect(find.text('Retry'), findsOneWidget);

    final before = sent.length;
    failing = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    final retried = sent.sublist(before);
    expect(retried, isNotEmpty);
    expect(retried.first['message'], "Let's talk about About Me.");
    expect(retried.first['discuss_section'], 'identity');
    expect(find.text('Have you been married before?'), findsOneWidget);
  });
}
