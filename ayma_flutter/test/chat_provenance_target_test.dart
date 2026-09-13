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

/// A synthetic 130-message history, oldest-first, one minute apart — enough
/// to exceed `TranscriptStore`'s default 100-turn rolling window so a target
/// timestamp near the very start of history genuinely tests whether it
/// survives trimming (Your Story provenance -> "jump to this conversation").
final _base = DateTime.utc(2026, 1, 1);
final _history = List<Map<String, String>>.generate(130, (i) {
  return {
    'role': i.isEven ? 'user' : 'ayma',
    'text': 'hist message $i',
    'created_at': _base.add(Duration(minutes: i)).toIso8601String(),
  };
});

/// Emulates `GET /chat/history`'s real pagination contract: up to `limit`
/// messages older than `before` (or the latest), oldest-first, plus the ISO
/// cursor for the next older page.
http.Response _historyResponse(Uri uri) {
  final limit = int.parse(uri.queryParameters['limit'] ?? '40');
  final before = uri.queryParameters['before'];
  var pool = _history;
  if (before != null) {
    final b = DateTime.parse(before);
    pool = pool.where((m) => DateTime.parse(m['created_at']!).isBefore(b)).toList();
  }
  final page = pool.length > limit ? pool.sublist(pool.length - limit) : pool;
  final nextBefore = pool.length > limit ? page.first['created_at'] : null;
  return http.Response(
    jsonEncode({'messages': page, 'next_before': nextBefore}),
    200,
    headers: _jsonUtf8,
  );
}

// Each tap on a provenance source opens a brand-new bottom-sheet route (a
// fresh `ChatScreen` instance/State) in the real app — `_openConversation` in
// `story_editor_screen.dart` calls `showModalBottomSheet` again every time.
// Keying by the target timestamp reproduces that "fresh instance" identity
// here, instead of `pumpWidget` reusing the same State via element diffing.
Widget _app(ApiClient api, String targetTimestamp) => MaterialApp(
      home: ChatScreen(
        key: ValueKey(targetTimestamp),
        apiClient: api,
        targetTimestamp: targetTimestamp,
      ),
    );

/// The message text inside the one-time "landing spot" highlight — the
/// `AnimatedContainer` `chat_screen.dart` wraps around `_highlightedTurn`.
/// `null` if nothing is highlighted (no target resolved).
String? _highlightedMessageText(WidgetTester tester) {
  final containers = find.byType(AnimatedContainer);
  for (final el in containers.evaluate()) {
    final texts = find
        .descendant(
          of: find.byWidget(el.widget),
          matching: find.byWidgetPredicate((w) => w is Text),
        )
        .evaluate();
    for (final t in texts) {
      final widget = t.widget as Text;
      final text = widget.data ?? widget.textSpan?.toPlainText();
      if (text != null && text.startsWith('hist message')) return text;
    }
  }
  return null;
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
    return ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));
  }

  testWidgets(
      'two different old targetTimestamps land on two different messages',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Both targets sit well before the most-recent 100 turns (indices 30-129)
    // — exactly the case that used to collapse onto the same surviving turn.
    final target1 = _base.add(const Duration(minutes: 5)).toIso8601String();
    final target2 = _base.add(const Duration(minutes: 20)).toIso8601String();

    await tester.pumpWidget(_app(await apiWithHistory(), target1));
    await tester.pumpAndSettle();
    final highlighted1 = _highlightedMessageText(tester);
    expect(highlighted1, isNotNull);

    await tester.pumpWidget(_app(await apiWithHistory(), target2));
    await tester.pumpAndSettle();
    final highlighted2 = _highlightedMessageText(tester);
    expect(highlighted2, isNotNull);

    // The actual regression: both old targets used to collapse onto the same
    // surviving (post-trim) turn no matter which source was tapped.
    expect(highlighted1, isNot(equals(highlighted2)));

    // Flush the 3s one-shot highlight-clear timer so it doesn't outlive the
    // test (the framework asserts no pending timers at teardown).
    await tester.pump(const Duration(seconds: 4));
  });
}
