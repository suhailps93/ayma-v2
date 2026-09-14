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

/// A synthetic 90-message history, oldest-first, one minute apart — more
/// than one `/chat/history` page (40) so a normal (no `targetTimestamp`)
/// open only ever shows the newest 40 until something pages in the rest.
final _base = DateTime.utc(2026, 1, 1);
final _history = List<Map<String, String>>.generate(90, (i) {
  return {
    'role': i.isEven ? 'user' : 'ayma',
    'text': 'hist message $i',
    'created_at': _base.add(Duration(minutes: i)).toIso8601String(),
  };
});

/// Same pagination contract as the real `GET /chat/history`: up to `limit`
/// messages older than `before` (or the latest), oldest-first, plus the ISO
/// cursor for the next older page.
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

void main() {
  tearDown(() => ChatInbox.instance.take());

  Future<ApiClient> apiWithHistory() async {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return _historyResponse(request.url);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    return ApiClient(
        httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
  }

  testWidgets(
      'a normal reopen shows only the newest page; scrolling up pages in older turns without snapping back down',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(apiClient: await apiWithHistory()),
    ));
    await tester.pumpAndSettle();

    // Regression case: a normal reopen (no targetTimestamp) used to do
    // exactly one `chatHistory(limit: 40)` call with no further pagination —
    // only the newest 40 of 90 total messages ever loaded, no matter how far
    // back real history went.
    expect(find.text('hist message 89'), findsOneWidget); // newest, at the bottom
    expect(find.text('hist message 0'), findsNothing); // never fetched yet

    final controller =
        tester.widget<ListView>(find.byType(ListView)).controller!;

    // Drive the scroll position directly rather than via a drag gesture —
    // deterministic, and it's exactly what the production listener
    // (`_maybeLoadOlderHistory`) reacts to regardless of how the offset got
    // there.
    controller.jumpTo(50);
    await tester.pump(); // scroll listener fires -> kicks off the fetch
    await tester.pumpAndSettle();

    // The fix's central point: after the older page splices in ahead of what
    // was on screen, the view holds roughly where the user was (near the
    // top) — it must NOT get yanked back down to the bottom by the store's
    // own "new content -> scroll to bottom" listener firing on the prepend.
    // (The newly-loaded turns sit further up, off the *lazily built* list's
    // current range — same as any chat app's "load older" — so reaching
    // them still takes more scrolling, checked next.)
    expect(controller.position.pixels, lessThan(500));

    // Scrolling further now actually reaches the page that was just paged
    // in — proof the fetch's data landed in the store (and the one before
    // it, exhausting history down to message 0), not just that the scroll
    // offset didn't jump. The lazily-built list only realizes rows near the
    // current viewport, so drive all the way to the top rather than
    // expecting every loaded row to already be in the tree.
    for (var i = 0;
        i < 5 && find.text('hist message 0').evaluate().isEmpty;
        i++) {
      controller.jumpTo(0);
      await tester.pump();
      await tester.pumpAndSettle();
    }
    expect(find.text('hist message 0'), findsOneWidget);
    expect(find.text('hist message 10'), findsOneWidget);
  });
}
