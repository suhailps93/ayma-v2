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

/// Founder bug (2026-09-28, reproduced on device): send a slow chat request
/// (image generation, 10–30s), background/exit the app, and on return the
/// message shows "Something went wrong sending that message. [Retry]" even
/// though the request completed — and billed — server-side.
///
/// Client half of the fix: a CONNECTION-class failure (socket died, stream
/// cut mid-read — an `ApiException` with no HTTP status; distinct from a
/// genuine 4xx/5xx response) no longer marks the turn failed. The pending
/// turn goes into a waiting state and is reconciled against the server: the
/// finished turn is found in `/chat/history` by the send's `client_msg_id`
/// (exact match, threaded end-to-end), or re-asked over `/chat` with that
/// same id — which the server dedups, so nothing is ever sent twice.
void main() {
  tearDown(() => ChatInbox.instance.take());

  http.Response historyPage(List<Map<String, String>> messages) =>
      http.Response(
        jsonEncode({'messages': messages, 'next_before': null}),
        200,
        headers: _jsonUtf8,
      );

  String? sentClientMsgId(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return body['client_msg_id'] as String?;
  }

  testWidgets(
      'a connection drop keeps the turn pending (no failed flash) and '
      'reconciliation adopts the server turn by client_msg_id', (tester) async {
    final msgIds = <String>[];
    var historyCalls = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        historyCalls++;
        // Call 1 is the screen-open load; call 2 is the reconcile's first
        // immediate poll (turn not landed yet); by call 3 the server has
        // finished the turn — with the send's exact client id on the row.
        if (historyCalls < 3 || msgIds.isEmpty) return historyPage(const []);
        return historyPage([
          {
            'role': 'ayma',
            'text': 'Here is your image.',
            'client_msg_id': msgIds.first,
            'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ]);
      }
      if (request.url.path == '/chat/stream' || request.url.path == '/chat') {
        msgIds.add(sentClientMsgId(request) ?? '');
        // The OS killed the socket: a transport death, not a server reply.
        throw http.ClientException('Connection closed while receiving data');
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'draw me a cat');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The connection died — but the turn must NOT flash failed: it stays
    // pending in its waiting state, with no error toast.
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsNothing);

    // The reconcile polls land the finished turn (2s apart).
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.text('Here is your image.'), findsOneWidget);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
    // Every attempt carried the same non-empty client id (stream + fallback).
    expect(msgIds, isNotEmpty);
    expect(msgIds.first, isNotEmpty);
    expect(msgIds.toSet().length, 1);
  });

  testWidgets(
      'app resume triggers reconciliation and adopts the server turn',
      (tester) async {
    final msgIds = <String>[];
    var serverReachable = true; // the initial history load must succeed
    var turnLanded = false;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        if (!serverReachable) {
          throw http.ClientException('Software caused connection abort');
        }
        if (!turnLanded || msgIds.isEmpty) return historyPage(const []);
        return historyPage([
          {
            'role': 'ayma',
            'text': 'Finished while you were away.',
            'client_msg_id': msgIds.first,
            'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
          },
        ]);
      }
      if (request.url.path == '/chat/stream' || request.url.path == '/chat') {
        msgIds.add(sentClientMsgId(request) ?? '');
        throw http.ClientException('Connection reset by peer');
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    serverReachable = false; // everything after this send is cut off
    await tester.enterText(find.byType(TextField), 'slow request');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pump();

    // The app leaves the foreground while everything is cut off, then comes
    // back with the network STILL down: the first reconcile pass (3 polls +
    // the idempotent re-ask) fails to reach the server and the turn stays
    // waiting — never an error flash.
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(s);
    }
    await tester.pump(const Duration(milliseconds: 100));
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(s);
    }
    // Walk the fake clock through the reconcile pass: the immediate poll,
    // the +2s and +4s polls, then the re-ask — all still cut off.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Waiting for a connection…'), findsOneWidget);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);

    // The user backgrounds and returns again — this time with the network
    // back and the turn finished server-side: the resume-triggered
    // reconcile adopts it.
    serverReachable = true;
    turnLanded = true;
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Finished while you were away.'), findsOneWidget);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
  });

  testWidgets(
      'the idempotent re-ask resolves the turn once — same client id on '
      'every attempt, a single reply bubble', (tester) async {
    final msgIds = <String>[];
    var chatCalls = 0;
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return historyPage(const []); // the turn never shows here
      }
      if (request.url.path == '/chat/stream') {
        msgIds.add(sentClientMsgId(request) ?? '');
        throw http.ClientException('Connection closed while receiving data');
      }
      if (request.url.path == '/chat') {
        msgIds.add(sentClientMsgId(request) ?? '');
        chatCalls++;
        if (chatCalls == 1) {
          // The in-band fallback dies too (app still backgrounded).
          throw http.ClientException('Connection closed while receiving data');
        }
        // The reconcile's re-ask: the server answers idempotently for this
        // client id (here: the deduped, already-persisted reply).
        return http.Response(
          jsonEncode({
            'reply': 'Done — one copy.',
            'tools_used': <String>[],
            'image_url': '',
            'duplicate': true,
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

    await tester.enterText(find.byType(TextField), 'draw me a cat');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('Done — one copy.'), findsOneWidget);
    expect(find.text('Something went wrong sending that message.'),
        findsNothing);
    // Stream, fallback, and re-ask all carried the one id — the server-side
    // dedup key that makes a retry of a landed turn a no-op.
    expect(msgIds.length, greaterThanOrEqualTo(3));
    expect(msgIds.first, isNotEmpty);
    expect(msgIds.toSet().length, 1);
  });

  testWidgets(
      'a genuine server failure still drops the pending turn and offers '
      'Retry', (tester) async {
    final mockHttp = MockClient((request) async {
      if (request.url.path == '/chat/history') {
        return historyPage(const []);
      }
      if (request.url.path == '/chat/stream' || request.url.path == '/chat') {
        // The server RESPONDED — this is a real failure, not a dead socket.
        return http.Response('', 500);
      }
      return http.Response('{}', 200, headers: _jsonUtf8);
    });
    final api =
        ApiClient(httpClient: mockHttp, auth: MockFirebaseAuth(signedIn: true));

    await tester.pumpWidget(MaterialApp(home: ChatScreen(apiClient: api)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'are you there?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).hitTestable());
    await tester.pumpAndSettle();

    expect(find.text("Couldn't reach Ayma. Check your connection."),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Reconnecting…'), findsNothing);
  });
}
