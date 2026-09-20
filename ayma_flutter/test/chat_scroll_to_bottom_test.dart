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

final _base = DateTime.utc(2026, 1, 1);
final _history = List<Map<String, String>>.generate(30, (i) {
  return {
    'role': i.isEven ? 'user' : 'ayma',
    'text': 'hist message $i',
    'created_at': _base.add(Duration(minutes: i)).toIso8601String(),
  };
});

http.Response _historyResponse(Uri uri) {
  final limit = int.parse(uri.queryParameters['limit'] ?? '40');
  final before = uri.queryParameters['before'];
  var pool = _history;
  if (before != null) {
    final b = DateTime.parse(before);
    pool = pool
        .where((m) => DateTime.parse(m['created_at']!).isBefore(b))
        .toList();
  }
  final page = pool.length > limit ? pool.sublist(pool.length - limit) : pool;
  final nextBefore = pool.length > limit ? page.first['created_at'] : null;
  return http.Response(
    jsonEncode({'messages': page, 'next_before': nextBefore}),
    200,
    headers: _jsonUtf8,
  );
}

/// A single `data: {...}\n\n` SSE frame carrying a final chat reply.
http.StreamedResponse _replyStream(String reply) {
  final frame =
      'data: ${jsonEncode({
        'type': 'reply',
        'reply': reply,
        'tools_used': <String>[],
        'usage_capped': false,
      })}\n\n';
  return http.StreamedResponse(
    Stream.value(utf8.encode(frame)),
    200,
    headers: _jsonUtf8,
  );
}

void main() {
  tearDown(() => ChatInbox.instance.take());

  Future<ApiClient> apiWithHistory({String reply = 'hi there'}) async {
    final mockHttp = MockClient.streaming((request, bodyStream) async {
      if (request.url.path == '/chat/history') {
        return http.StreamedResponse(
          Stream.value(utf8.encode(_historyResponse(request.url).body)),
          200,
          headers: _jsonUtf8,
        );
      }
      if (request.url.path == '/chat/stream') {
        return _replyStream(reply);
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        200,
        headers: _jsonUtf8,
      );
    });
    return ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
  }

  testWidgets('opening the chat screen lands scrolled to the newest message',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: await apiWithHistory()),
    ));
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;

    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1.0),
      reason: 'a normal open should land scrolled to the newest message',
    );
  });

  testWidgets('sending a message scrolls to reveal the reply',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final longReply = List.generate(40, (i) => 'reply line $i').join('. ');
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: await apiWithHistory(reply: longReply)),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a new message');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;

    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1.0),
      reason: 'sending a message should scroll to reveal the reply',
    );
  });
}
