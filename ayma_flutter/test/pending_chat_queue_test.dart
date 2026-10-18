import 'dart:convert';

import 'package:ayma_flutter/screens/chat_screen.dart';
import 'package:ayma_flutter/services/api_client.dart';
import 'package:ayma_flutter/services/credits_balance.dart';
import 'package:ayma_flutter/services/pending_chat_queue.dart';
import 'package:ayma_flutter/services/transcript_store.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

/// A scripted server: `/chat` answers `usage_capped` while [credits] is 0 and a
/// real reply otherwise, recording every client id it was sent.
class _Server {
  int credits = 0;
  final sentIds = <String>[];
  final landed = <String, String>{}; // client_msg_id -> reply text
  bool offline = false;

  /// Runs after every `/chat` response is built (lets a test change the
  /// balance mid-flush).
  void Function()? afterChat;

  http.Client get client => MockClient((request) async {
        if (offline) throw http.ClientException('offline');
        switch (request.url.path) {
          case '/usage':
            return http.Response(
              jsonEncode({
                'credits': {'remaining': credits},
              }),
              200,
              headers: _json,
            );
          case '/chat/history':
            return http.Response(
              jsonEncode({
                'messages': [
                  for (final e in landed.entries)
                    {
                      'role': 'ayma',
                      'text': e.value,
                      'client_msg_id': e.key,
                      'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
                    },
                ],
                'next_before': null,
              }),
              200,
              headers: _json,
            );
          case '/chat/stream':
            return http.Response('', 404); // forces the plain /chat fallback
          case '/chat':
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final id = body['client_msg_id'] as String;
            sentIds.add(id);
            final capped = credits <= 0;
            if (!capped) landed[id] = 'reply to ${body['message']}';
            afterChat?.call();
            return http.Response(
              jsonEncode(capped
                  ? {'reply': 'out of credits', 'usage_capped': true}
                  : {'reply': landed[id]}),
              200,
              headers: _json,
            );
        }
        return http.Response('{}', 200, headers: _json);
      });

  ApiClient get api =>
      ApiClient(httpClient: client, auth: MockFirebaseAuth(signedIn: true));
}

PendingChatQueue _queue(_Server server, TranscriptStore store,
    {String uid = 'u1'}) {
  return PendingChatQueue(
    api: server.api,
    store: store,
    sessionId: 's-test',
    currentUid: () => uid,
  );
}

QueuedChatMessage _msg(String id, String text) =>
    QueuedChatMessage(clientMsgId: id, message: text);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CreditsBalance.instance.remaining.value = null;
  });

  test('a queued message survives a restart (persisted per account)',
      () async {
    final server = _Server();
    final first = _queue(server, TranscriptStore());
    await first.activate();
    await first.enqueue(_msg('m-1', 'hello'));

    final restarted = _queue(server, TranscriptStore());
    await restarted.activate();
    expect(restarted.items.map((m) => m.message), ['hello']);
    expect(restarted.items.single.clientMsgId, 'm-1');

    final otherAccount = _queue(server, TranscriptStore(), uid: 'u2');
    await otherAccount.activate();
    expect(otherAccount.isEmpty, isTrue);
  });

  test('a balance increase sends queued messages in order, once, and replies',
      () async {
    final server = _Server();
    final store = TranscriptStore();
    final queue = _queue(server, store);
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'first'));
    await queue.enqueue(_msg('m-2', 'second'));
    expect(server.sentIds, isEmpty);

    server.credits = 50;
    CreditsBalance.instance.remaining.value = 50;
    await pumpEventQueue();

    expect(server.sentIds, ['m-1', 'm-2']);
    expect(queue.isEmpty, isTrue);
    expect(store.turns.map((t) => '${t.role.name}:${t.text}'), [
      'user:first',
      'ayma:reply to first',
      'user:second',
      'ayma:reply to second',
    ]);

    // A later balance change must not resend anything.
    CreditsBalance.instance.remaining.value = 40;
    await pumpEventQueue();
    expect(server.sentIds, ['m-1', 'm-2']);
    final persisted = _queue(server, TranscriptStore());
    await persisted.activate();
    expect(persisted.isEmpty, isTrue);
  });

  test('flushing stops when credits run out again and keeps the rest queued',
      () async {
    final server = _Server()..credits = 1;
    var chats = 0;
    server.afterChat = () {
      if (++chats == 1) server.credits = 0;
    };
    final store = TranscriptStore();
    final queue = _queue(server, store);
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'first'));
    await queue.enqueue(_msg('m-2', 'second'));
    await queue.enqueue(_msg('m-3', 'third'));

    CreditsBalance.instance.remaining.value = 1;
    await pumpEventQueue();

    expect(queue.items.map((m) => m.clientMsgId), ['m-2', 'm-3']);
    expect(server.sentIds, ['m-1', 'm-2']); // m-2 hit the wall, m-3 untouched
    expect(store.turns.where((t) => t.role == TurnRole.user).length, 1);
    expect(store.turns.any((t) => t.capped), isTrue);
  });

  test('a message whose reply already landed is adopted, never re-sent',
      () async {
    final server = _Server()
      ..credits = 5
      ..landed['m-1'] = 'reply to hello';
    final store = TranscriptStore();
    final queue = _queue(server, store);
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'hello'));
    CreditsBalance.instance.remaining.value = 5;
    await pumpEventQueue();

    expect(server.sentIds, isEmpty);
    expect(queue.isEmpty, isTrue);
    expect(store.turns.map((t) => t.text), ['hello', 'reply to hello']);
  });

  test('a landed reply already in the transcript is not shown twice',
      () async {
    final server = _Server()
      ..credits = 5
      ..landed['m-1'] = 'reply to hello';
    final store = TranscriptStore()
      ..addTurn(TurnRole.user, 'hello', TurnSource.text)
      ..addTurn(TurnRole.ayma, 'reply to hello', TurnSource.text);
    final queue = _queue(server, store);
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'hello'));
    CreditsBalance.instance.remaining.value = 5;
    await pumpEventQueue();

    expect(server.sentIds, isEmpty);
    expect(store.turns.length, 2);
  });

  test('a connection failure keeps the message queued and retries with the '
      'same id', () async {
    final server = _Server()..credits = 5;
    final store = TranscriptStore();
    final queue = _queue(server, store);
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'hello'));

    server.offline = true;
    CreditsBalance.instance.remaining.value = 5;
    await pumpEventQueue();
    expect(queue.items.single.clientMsgId, 'm-1');
    expect(store.turns, isEmpty); // no stray bubble or "Thinking…" left behind

    server.offline = false;
    await queue.flushIfFunded();
    expect(server.sentIds, ['m-1']);
    expect(queue.isEmpty, isTrue);
    expect(store.turns.map((t) => t.text), ['hello', 'reply to hello']);
  });

  test('a cancelled message is never sent', () async {
    final server = _Server();
    final queue = _queue(server, TranscriptStore());
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'nope'));
    await queue.enqueue(_msg('m-2', 'yes'));
    await queue.cancel('m-1');

    server.credits = 5;
    CreditsBalance.instance.remaining.value = 5;
    await pumpEventQueue();

    expect(server.sentIds, ['m-2']);
    final persisted = _queue(server, TranscriptStore());
    await persisted.activate();
    expect(persisted.isEmpty, isTrue);
  });

  test('syncBalanceAndFlush learns a grant from /usage and sends', () async {
    final server = _Server();
    final queue = _queue(server, TranscriptStore());
    await queue.activate();
    await queue.enqueue(_msg('m-1', 'hello'));
    server.credits = 30; // granted while the app was away
    await queue.syncBalanceAndFlush();
    await pumpEventQueue(); // the balance listener's flush runs alongside

    expect(CreditsBalance.instance.remaining.value, 30);
    expect(server.sentIds, ['m-1']);
  });

  testWidgets(
      'chat: a send at zero credits shows a waiting bubble with Cancel, then '
      'goes out automatically once credits arrive', (tester) async {
    final server = _Server();
    final store = TranscriptStore();
    final queue = _queue(server, store);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: server.api,
        transcriptStore: store,
        pendingQueue: queue,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'are you there');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pumpAndSettle();

    expect(queue.items.map((m) => m.message), ['are you there']);
    expect(find.text('Waiting for credits'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    // Shown exactly once: as the waiting bubble, not also as a sent turn.
    expect(find.text('are you there'), findsOneWidget);

    server.credits = 20;
    CreditsBalance.instance.remaining.value = 20;
    await tester.pumpAndSettle();

    expect(find.text('Waiting for credits'), findsNothing);
    expect(find.text('are you there'), findsOneWidget);
    expect(find.text('reply to are you there'), findsOneWidget);
    expect(queue.isEmpty, isTrue);
    // The refused attempt and the flush carried the same id: one send.
    expect(server.sentIds.toSet().length, 1);
  });

  testWidgets('chat: Cancel removes a waiting message', (tester) async {
    final server = _Server();
    final store = TranscriptStore();
    final queue = _queue(server, store);
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        apiClient: server.api,
        transcriptStore: store,
        pendingQueue: queue,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'never mind');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(queue.isEmpty, isTrue);
    expect(find.text('never mind'), findsNothing);
    expect(find.text('Waiting for credits'), findsNothing);
  });
}
