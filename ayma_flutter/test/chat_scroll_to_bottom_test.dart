import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/chat_inbox.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
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

  // Root cause of "scroll to latest not happening all the time" — worse when
  // this screen is embedded in `showAymaChatModal`'s popup, since dragging
  // the transcript itself is how that sheet resizes (`_bridgeChatDrag`), a
  // gesture users commonly start right after sending a message: a reply
  // arriving while a drag is in flight has `_scrollToBottom` bail out (by
  // design — never yank the view mid-gesture), and previously nothing
  // guaranteed a retry once the drag ended, unless some *unrelated* later
  // layout change happened to fire a `ScrollMetricsNotification` first.
  testWidgets(
      'a message that arrives mid-drag still lands scrolled to the bottom '
      'once the drag ends, not just when something else happens to '
      're-trigger it afterward', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = TranscriptStore();
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: await apiWithHistory(),
        transcriptStore: store,
      ),
    ));
    await tester.pumpAndSettle();

    // The 30 short one-line history messages alone fit within the test
    // viewport with nothing to scroll — pad in a couple of long turns (same
    // reason `apiWithHistory`'s sibling test above needs a long reply) so
    // there's an actual `maxScrollExtent` for a subsequent arrival to fall
    // short of landing at.
    final longText = List.generate(20, (i) => 'padding line $i').join('. ');
    store.addTurn(TurnRole.ayma, longText, TurnSource.text);
    store.addTurn(TurnRole.user, longText, TurnSource.text);
    await tester.pumpAndSettle();

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1.0),
    );

    // Drive the exact notifications a real in-flight touch drag produces —
    // `_handleListScrollNotification` only inspects `dragDetails`, not the
    // metrics, so this exercises precisely the logic under test without
    // depending on a real gesture actually landing on/moving a lazily-built
    // `ListView.builder` by a specific pixel amount (whose `maxScrollExtent`
    // is itself only an *estimate* until every item's been laid out once —
    // not something a raw pointer drag can be relied on to leave untouched).
    final element = tester.element(find.byType(ListView));
    ScrollStartNotification(
      metrics: controller.position,
      context: element,
      dragDetails: DragStartDetails(),
    ).dispatch(element);

    // A reply lands while the finger is still down — `_scrollToBottom`'s own
    // `_userScrolling` guard makes this a no-op for now, by design (never
    // yank the view out from under an in-flight drag).
    store.addTurn(
      TurnRole.ayma,
      'a new reply arrived mid-drag',
      TurnSource.text,
    );
    await tester.pump();

    // End the drag. Without the fix, nothing further ever re-triggers
    // `_scrollToBottom` for the message that arrived above — this is the
    // actual, "not all the time" race, not something a delay papers over.
    ScrollEndNotification(
      metrics: controller.position,
      context: element,
      dragDetails: DragEndDetails(),
    ).dispatch(element);
    await tester.pumpAndSettle();

    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1.0),
      reason: 'ending the drag should chase the bottom for the message that '
          'arrived while it was in flight',
    );
  });
}
